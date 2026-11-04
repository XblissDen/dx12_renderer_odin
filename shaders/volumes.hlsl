// Irradiance volumes (renderer_probes.odin), shared by scene.hlsl and
// dynamic_volume.hlsl through #include; never compiled on its own.
//
// A volume is a grid of cells filling the unit cube in box space. Baked
// volumes hold L1 spherical harmonics per cell in a 3D atlas (scene.hlsl).
// Dynamic volumes (DDGI, GPUs with DXR 1.1) treat each cell as a probe that
// rays update every frame; per probe, two octahedral maps in 2D atlases:
//   - irradiance: 8 x 8 texels (6 x 6 inside a one-texel border), the
//     cosine-weighted average radiance around each direction;
//   - distance: 16 x 16 texels (14 x 14 inside), the mean distance to what
//     the rays hit around each direction, and its square (for Chebyshev's
//     visibility test);
// and a probe texel holding its offset from the cell center (relocation) and
// its update count (negative: inside geometry, not used).

#ifndef VOLUMES_HLSL
#define VOLUMES_HLSL

#include "common.hlsl"

struct GpuIrradianceVolume
{
    float4x4 world_to_box;
    float4x4 box_to_world;
    float3 size; // World length of the box's edges.
    float blend_distance;
    uint3 cells;
    uint first_z; // Baked: its block's first slice in g_volume_atlas.
    float normal_bias;
    // Dynamic: its first probe in the atlases, its first place in the order
    // probes are updated in, its probe count, and how far distances count.
    uint first_probe;
    uint sequence_start;
    uint probe_count;
    float max_distance;
    float3 _pad;
};
StructuredBuffer<GpuIrradianceVolume> g_volumes : register(t12);

// Atlas layout; must match renderer_probes.odin.
#define DYNAMIC_ATLAS_COLUMNS 256u
#define DYNAMIC_ATLAS_ROWS 128u
#define DYNAMIC_IRRADIANCE_TILE 8u
#define DYNAMIC_DISTANCE_TILE 16u
#define DYNAMIC_MAX_RAYS 256u

// This frame's probe update (renderer_update_volumes): the rays' random
// rotation, rays per probe, how many probes (the batch) starting where in
// the update order (of `total`), and the blend's hysteresis.
cbuffer DynamicVolumeConstants : register(b3)
{
    float4 ddgi_rotation[3]; // Rows of a rotation matrix.
    uint   ddgi_rays;
    uint   ddgi_batch;
    uint   ddgi_cursor;
    uint   ddgi_total;
    float  ddgi_hysteresis;
    uint   ddgi_volume_count;
    float2 _ddgi_pad;
};

float2 SignNotZero(float2 v)
{
    return select(v >= 0.0f, 1.0f, -1.0f);
}

// Octahedral mapping: a direction to a point of the square [-1, 1]^2 and
// back. The upper half (+z) folds out to the inner diamond, the lower half
// to the corners.
float2 OctEncode(float3 direction)
{
    float2 e = direction.xy / (abs(direction.x) + abs(direction.y) + abs(direction.z));
    return direction.z >= 0.0f ? e : (1.0f - abs(e.yx)) * SignNotZero(e);
}

float3 OctDecode(float2 e)
{
    float3 direction = float3(e, 1.0f - abs(e.x) - abs(e.y));
    if (direction.z < 0.0f) direction.xy = (1.0f - abs(direction.yx)) * SignNotZero(direction.xy);
    return normalize(direction);
}

// A probe's tile, in tiles, in either atlas.
uint2 DynamicProbeTexel(uint probe)
{
    return uint2(probe % DYNAMIC_ATLAS_COLUMNS, probe / DYNAMIC_ATLAS_COLUMNS);
}

// Where a direction lands in a probe's tile of an atlas, for bilinear
// filtering (the border makes it seamless across the folds).
float2 DynamicTileUV(uint probe, float3 direction, uint tile)
{
    float2 origin = float2(DynamicProbeTexel(probe) * tile);
    float2 inner = (OctEncode(direction) * 0.5f + 0.5f) * float(tile - 2u) + 1.0f;
    return (origin + inner) / float2(DYNAMIC_ATLAS_COLUMNS * tile, DYNAMIC_ATLAS_ROWS * tile);
}

uint3 VolumeCell(uint index, uint3 cells)
{
    return uint3(index % cells.x, index / cells.x % cells.y, index / (cells.x * cells.y));
}

// A cell's center in world space (before its probe's offset).
float3 VolumeCellCenter(GpuIrradianceVolume volume, uint3 cell)
{
    float3 local = (float3(cell) + 0.5f) / float3(volume.cells) - 0.5f;
    return mul(float4(local, 1.0f), volume.box_to_world).xyz;
}

// Ray `ray` of every probe this frame: evenly spread over the sphere
// (spherical Fibonacci), then turned by the frame's random rotation, so
// successive frames sample different directions.
float3 DynamicRayDirection(uint ray)
{
    const float golden = 0.618033988749895f;
    float phi = 2.0f * PI * frac(float(ray) * golden);
    float cos_theta = 1.0f - (2.0f * float(ray) + 1.0f) / float(ddgi_rays);
    float sin_theta = sqrt(saturate(1.0f - cos_theta * cos_theta));
    float3 d = float3(cos(phi) * sin_theta, cos_theta, sin(phi) * sin_theta);
    return float3(dot(ddgi_rotation[0].xyz, d), dot(ddgi_rotation[1].xyz, d), dot(ddgi_rotation[2].xyz, d));
}

// The probe at place `batch_index` of this frame's batch: the volume (in
// g_volumes) and its cell index. Probes are updated round-robin over every
// volume's probes in order.
void DynamicBatchProbe(uint batch_index, out uint volume_index, out uint cell_index)
{
    uint place = (ddgi_cursor + batch_index) % max(ddgi_total, 1u);
    volume_index = 0u;
    for (uint i = 1u; i < ddgi_volume_count; ++i)
    {
        if (place >= g_volumes[i].sequence_start) volume_index = i;
    }
    cell_index = place - g_volumes[volume_index].sequence_start;
}

// A probe's update count from its texel's w (negative: inside geometry).
float DynamicUpdateCount(float w)
{
    return w >= 0.0f ? w : -w - 1.0f;
}

#endif
