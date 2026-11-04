// Dynamic irradiance volumes (renderer_probes.odin, volumes.hlsl): after
// PSVolumeRays has traced this frame's batch of probes, these passes blend
// the rays into each probe's octahedral maps, move probes out of geometry,
// and clear volumes that start over.

#include "volumes.hlsl"

// This frame's rays: x the ray, y the probe's place in the batch; light, and
// distance (negative: the back of a one-sided surface, shortened by 5).
Texture2D<float4> g_rays : register(t0);
RWTexture2D<float4> g_irradiance : register(u0);
RWTexture2D<float2> g_distance : register(u1);
RWTexture2D<float4> g_probe_data : register(u2);

cbuffer ResetConstants : register(b1)
{
    uint g_reset_first; // Probes to clear: a volume's range.
    uint g_reset_count;
};

// DDGI's sharpness for distances: each texel averages the rays close to its
// direction, so the distance map keeps the shape of nearby walls.
#define DISTANCE_SHARPNESS 50.0f
// A probe whose rays meet back faces this often is inside something.
#define BACKFACE_LIMIT 0.25f

groupshared float4 gs_rays[DYNAMIC_MAX_RAYS];
groupshared float3 gs_directions[DYNAMIC_MAX_RAYS];
groupshared float4 gs_tile[DYNAMIC_DISTANCE_TILE * DYNAMIC_DISTANCE_TILE];

// The probe in place `batch` of this frame's batch.
void BatchProbe(uint batch, out GpuIrradianceVolume volume, out uint probe)
{
    uint volume_index, cell_index;
    DynamicBatchProbe(batch, volume_index, cell_index);
    volume = g_volumes[volume_index];
    probe = volume.first_probe + cell_index;
}

// The probe's rays into group memory, read by every texel.
void LoadRays(uint batch, uint thread, uint thread_count)
{
    for (uint ray = thread; ray < ddgi_rays; ray += thread_count)
    {
        gs_rays[ray] = g_rays.Load(int3(ray, batch, 0));
        gs_directions[ray] = DynamicRayDirection(ray);
    }
    GroupMemoryBarrierWithGroupSync();
}

// The interior texel a tile texel shows: itself inside, and for the
// one-texel border, the interior texel across the octahedron's fold (DDGI's
// border copy), so bilinear lookups near a tile's edge stay continuous.
uint2 TileSource(uint2 texel, uint inner)
{
    uint last = inner + 1u;
    bool edge_x = texel.x == 0u || texel.x == last;
    bool edge_y = texel.y == 0u || texel.y == last;
    if (edge_x && edge_y) return uint2(texel.x == 0u ? inner : 1u, texel.y == 0u ? inner : 1u);
    if (edge_y) return uint2(last - texel.x, texel.y == 0u ? 1u : inner);
    if (edge_x) return uint2(texel.x == 0u ? 1u : inner, last - texel.y);
    return texel;
}

// How much of the old value a probe keeps: none on its first update, then
// up to the setting. Data w counts updates (negative: inside geometry).
float ProbeHysteresis(uint probe)
{
    float count = DynamicUpdateCount(g_probe_data[DynamicProbeTexel(probe)].w);
    return min(ddgi_hysteresis, count / (count + 1.0f));
}

// One group per probe of the batch, one thread per texel of its 8 x 8 tile.
// Each interior texel is the cosine-weighted average of the rays' light
// around its direction (rays from inside geometry left out), blended with
// what it held.
[numthreads(DYNAMIC_IRRADIANCE_TILE, DYNAMIC_IRRADIANCE_TILE, 1)]
void CSBlendIrradiance(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID, uint index : SV_GroupIndex)
{
    GpuIrradianceVolume volume;
    uint probe;
    BatchProbe(group.x, volume, probe);
    LoadRays(group.x, index, DYNAMIC_IRRADIANCE_TILE * DYNAMIC_IRRADIANCE_TILE);

    const uint inner = DYNAMIC_IRRADIANCE_TILE - 2u;
    uint2 origin = DynamicProbeTexel(probe) * DYNAMIC_IRRADIANCE_TILE;
    if (all(thread.xy >= 1u) && all(thread.xy <= inner))
    {
        float3 direction = OctDecode((float2(thread.xy - 1u) + 0.5f) / float(inner) * 2.0f - 1.0f);
        float3 sum = 0.0f;
        float total = 0.0f;
        for (uint ray = 0; ray < ddgi_rays; ++ray)
        {
            if (gs_rays[ray].w < 0.0f) continue;
            float weight = max(dot(direction, gs_directions[ray]), 0.0f);
            sum += weight * gs_rays[ray].rgb;
            total += weight;
        }
        float3 old = g_irradiance[origin + thread.xy].rgb;
        float3 value = total > 1e-4f ? sum / total : old;
        gs_tile[thread.y * DYNAMIC_IRRADIANCE_TILE + thread.x] = float4(lerp(value, old, ProbeHysteresis(probe)), 1.0f);
    }
    GroupMemoryBarrierWithGroupSync();
    uint2 source = TileSource(thread.xy, inner);
    g_irradiance[origin + thread.xy] = gs_tile[source.y * DYNAMIC_IRRADIANCE_TILE + source.x];
}

// Likewise for the 16 x 16 distance tile: each interior texel averages the
// distance (capped at the volume's max_distance) and its square over the
// rays near its direction, sharply weighted.
[numthreads(DYNAMIC_DISTANCE_TILE, DYNAMIC_DISTANCE_TILE, 1)]
void CSBlendDistance(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID, uint index : SV_GroupIndex)
{
    GpuIrradianceVolume volume;
    uint probe;
    BatchProbe(group.x, volume, probe);
    LoadRays(group.x, index, DYNAMIC_DISTANCE_TILE * DYNAMIC_DISTANCE_TILE);

    const uint inner = DYNAMIC_DISTANCE_TILE - 2u;
    uint2 origin = DynamicProbeTexel(probe) * DYNAMIC_DISTANCE_TILE;
    if (all(thread.xy >= 1u) && all(thread.xy <= inner))
    {
        float3 direction = OctDecode((float2(thread.xy - 1u) + 0.5f) / float(inner) * 2.0f - 1.0f);
        float2 sum = 0.0f;
        float total = 0.0f;
        for (uint ray = 0; ray < ddgi_rays; ++ray)
        {
            float weight = pow(max(dot(direction, gs_directions[ray]), 0.0f), DISTANCE_SHARPNESS);
            float distance = min(abs(gs_rays[ray].w), volume.max_distance);
            sum += weight * float2(distance, distance * distance);
            total += weight;
        }
        float2 old = g_distance[origin + thread.xy];
        float2 value = total > 1e-4f ? sum / total : old;
        gs_tile[thread.y * DYNAMIC_DISTANCE_TILE + thread.x] = float4(lerp(value, old, ProbeHysteresis(probe)), 0.0f, 0.0f);
    }
    GroupMemoryBarrierWithGroupSync();
    uint2 source = TileSource(thread.xy, inner);
    g_distance[origin + thread.xy] = gs_tile[source.y * DYNAMIC_DISTANCE_TILE + source.x].xy;
}

// One thread per probe of the batch, after the blends: moves the probe for
// its next rays (DDGI's relocation) and counts the update.
//   - Inside geometry (many back faces): through the nearest back face, to
//     just beyond it.
//   - Too close to a surface: away from it, toward the farthest open
//     direction.
// A move that would leave the probe more than 0.45 cells from its cell's
// center is not made. A probe still inside geometry is marked unused.
[numthreads(64, 1, 1)]
void CSRelocate(uint id : SV_DispatchThreadID)
{
    if (id >= ddgi_batch) return;
    GpuIrradianceVolume volume;
    uint probe;
    BatchProbe(id, volume, probe);
    uint2 texel = DynamicProbeTexel(probe);
    float4 data = g_probe_data[texel];

    uint backfaces = 0u;
    float closest_back = 1e30f, closest_front = 1e30f, farthest_front = 0.0f;
    float3 closest_back_dir = 0.0f, closest_front_dir = 0.0f, farthest_front_dir = 0.0f;
    for (uint ray = 0; ray < ddgi_rays; ++ray)
    {
        float distance = g_rays.Load(int3(ray, id, 0)).w;
        float3 direction = DynamicRayDirection(ray);
        if (distance < 0.0f)
        {
            backfaces += 1u;
            distance *= -5.0f;
            if (distance < closest_back) { closest_back = distance; closest_back_dir = direction; }
        }
        else
        {
            if (distance < closest_front) { closest_front = distance; closest_front_dir = direction; }
            if (distance > farthest_front) { farthest_front = distance; farthest_front_dir = direction; }
        }
    }

    float3 spacing = volume.size / float3(volume.cells);
    float min_front = 0.25f * min(spacing.x, min(spacing.y, spacing.z));
    bool inside = float(backfaces) > BACKFACE_LIMIT * float(ddgi_rays);
    float3 offset = data.xyz;
    if (inside)
    {
        offset += closest_back_dir * (closest_back + min_front * 0.5f);
    }
    else if (closest_front < min_front && dot(closest_front_dir, farthest_front_dir) <= 0.0f)
    {
        offset += farthest_front_dir * min(farthest_front, min_front);
    }
    if (all(abs(offset) <= 0.45f * spacing)) data.xyz = offset;

    float count = min(DynamicUpdateCount(data.w) + 1.0f, 1000.0f);
    data.w = inside ? -count - 1.0f : count;
    g_probe_data[texel] = data;
}

// Clears a volume's probes: centered, never updated (so unused until their
// first update, which then keeps nothing old).
[numthreads(64, 1, 1)]
void CSResetProbes(uint id : SV_DispatchThreadID)
{
    if (id >= g_reset_count) return;
    g_probe_data[DynamicProbeTexel(g_reset_first + id)] = 0.0f;
}
