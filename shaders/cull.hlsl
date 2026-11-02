// GPU culling (renderer_frame_data.odin). The CPU lists every draw each view
// may draw, already grouped into indirect draw calls with room for all of
// them; one thread per entry tests the draw and, if it passes, gives it the
// next instance of its call. The mesh passes then draw the calls with
// ExecuteIndirect.
//
// Shadow views test the frustum only. The camera also culls draws hidden
// behind others, in two phases around the depth prepass:
// - Early (before the shadow pass): draws in the frustum that were visible
//   last frame, into the early calls. The prepass draws them first.
// - Late (after a depth pyramid is built from that depth): every draw in the
//   frustum is tested against the pyramid, which records whether it is
//   visible for next frame. Visible ones not drawn early go into the late
//   calls (the early calls' copies), and blended draws into their own.
// Anything visible is drawn in one phase or the other: the early depth only
// holds real surfaces, so it never hides something that should show.
//
// Large draws in the camera's opaque views and the sun's cascades come as one
// entry per meshlet instead (mesh.odin). A meshlet is tested like a draw (its
// bounding sphere, with the same two phases and its own visibility flag),
// and also by its normal cone: when the view sees only its back faces it is
// skipped. A visible meshlet's triangles are copied from the mesh's index
// buffer into its draw's region of the compacted index buffer, which the
// draw's call reads, so the call draws only what survived.

// Must match renderer_frame_data.odin: the camera, every shadow view, then
// the six faces of a reflection probe capture (from PROBE_FIRST_CULL_VIEW).
#define CULL_VIEW_COUNT 39
#define PROBE_FIRST_CULL_VIEW 33

// g_commands: counters for the panel, padding to CULL_HEADER_SIZE, then
// the calls (IndirectDraw: vertex and index buffer views, the first
// instance-list entry, then the indexed draw's arguments).
#define CULL_HEADER_SIZE 64
#define CULL_COMMAND_STRIDE 56
#define CULL_FIRST_INSTANCE_OFFSET 32
#define CULL_INDEX_COUNT_OFFSET 36
#define CULL_INSTANCE_COUNT_OFFSET 40
#define CULL_START_INDEX_OFFSET 44

// Meshlet entries follow the draw entries, from this one on
// (MAX_INSTANCES in renderer_frame_data.odin); groups are laid out in rows.
#define MESHLET_ENTRY_BASE 163840u
#define MESHLET_GROUPS_PER_ROW 65535u
#define MESHLET_GROUP_SIZE 32u

struct CullEntry
{
    uint draw;    // Index into g_bounds, and what the instance list records.
    uint command; // The draw call it would join (the early one for the camera).
    uint view;    // 0: the camera; 1 + n: shadow view n; then capture faces.
    uint meshlet; // Meshlet entries: the meshlet in g_meshlets.
    uint flag;    // Meshlet entries: its slot in g_meshlet_visible.
};

// World-space box: center and half-size axes. Draws without bounds come with
// huge axes, so they pass every test. Then, for meshlets: the draw's world
// matrix (rows), its largest axis scale, and whether normal cones apply.
struct CullBounds
{
    float3 center;
    float3 axis_x;
    float3 axis_y;
    float3 axis_z;
    float4 model_rows[3];
    float max_scale;
    uint cone_ok;
    float2 _pad;
};

// A meshlet (renderer_frame_data.odin's GpuMeshlet): its mesh-space sphere
// and normal cone, and its triangles in the index buffer at heap slot
// `index_buffer`.
struct Meshlet
{
    float3 center;
    float radius;
    float3 cone_axis;
    float cone_cutoff;
    uint first_index;
    uint index_count;
    uint index_buffer;
    uint _pad;
};

cbuffer CullConstants : register(b0)
{
    // Six normalized planes per view, facing inwards.
    float4 g_view_planes[CULL_VIEW_COUNT * 6];
    // The camera's unjittered view-projection.
    float4x4 g_view_projection;
    // The depth pyramid's top level size (a power of two in each direction)
    // and level count.
    float2 g_hiz_size;
    uint g_hiz_mip_count;
    uint g_occlusion_enabled;
    uint g_entry_count;
    uint g_culling_enabled;
    // Entries: the camera's opaque draws, then its blended ones, then the
    // shadow views'.
    uint g_opaque_entry_count;
    uint g_camera_entry_count;
    // A late call is the early call this many commands later.
    uint g_late_command_offset;
    // Meshlet entries, the camera's first.
    uint g_meshlet_entry_count;
    uint g_camera_meshlet_entry_count;
    // Where the camera looks from, for normal cones (w unused).
    float4 g_camera_position;
};

// CSCull: x is the phase (0 early, 1 late). CSBuildHiZ: the source and
// target level sizes.
cbuffer PassConstants : register(b1)
{
    uint4 g_pass;
};

StructuredBuffer<CullEntry> g_entries : register(t0);
StructuredBuffer<CullBounds> g_bounds : register(t1);
Texture2D<float> g_hiz : register(t2);
Texture2D<float> g_hiz_source : register(t3);
RWByteAddressBuffer g_commands : register(u0);
RWStructuredBuffer<uint> g_instances : register(u1);
RWTexture2D<float> g_hiz_target : register(u2);
// Per draw: nonzero if the camera saw it last frame.
RWStructuredBuffer<uint> g_visible : register(u3);
StructuredBuffer<Meshlet> g_meshlets : register(t4);
// The whole SRV heap as raw buffers: the meshes' index buffers.
ByteAddressBuffer g_mesh_indices[] : register(t0, space1);
RWByteAddressBuffer g_meshlet_indices : register(u4);
// Per camera meshlet (CullEntry.flag): nonzero if it was visible last frame.
RWStructuredBuffer<uint> g_meshlet_visible : register(u5);

// The CPU's frustum_intersects_bounds: rejected only when the whole box is
// outside one plane, with the same small tolerance.
bool BoundsInFrustum(uint view, CullBounds bounds)
{
    bool visible = true;
    [unroll]
    for (uint i = 0; i < 6; i++)
    {
        float4 plane = g_view_planes[view * 6 + i];
        float distance = dot(plane.xyz, bounds.center) + plane.w;
        float radius = abs(dot(plane.xyz, bounds.axis_x)) +
                       abs(dot(plane.xyz, bounds.axis_y)) +
                       abs(dot(plane.xyz, bounds.axis_z));
        visible = visible && distance + radius >= -0.001f;
    }
    return visible || g_culling_enabled == 0;
}

// Whether the box is entirely behind the depth pyramid's surfaces: its
// nearest depth is farther than the farthest depth over the screen rectangle
// it covers. Boxes reaching behind the camera are never occluded.
bool BoundsOccluded(CullBounds bounds)
{
    float2 uv_min = 1, uv_max = 0;
    float nearest = 1;
    bool in_front = true;
    [unroll]
    for (uint corner = 0; corner < 8; corner++)
    {
        float3 position = bounds.center +
            bounds.axis_x * ((corner & 1) ? 1.0f : -1.0f) +
            bounds.axis_y * ((corner & 2) ? 1.0f : -1.0f) +
            bounds.axis_z * ((corner & 4) ? 1.0f : -1.0f);
        float4 clip = mul(float4(position, 1.0f), g_view_projection);
        in_front = in_front && clip.w > 1e-4f;
        float3 ndc = clip.xyz / max(clip.w, 1e-4f);
        float2 uv = ndc.xy * float2(0.5f, -0.5f) + 0.5f;
        uv_min = min(uv_min, uv);
        uv_max = max(uv_max, uv);
        nearest = min(nearest, ndc.z);
    }
    // One top-level texel of margin: the prepass drew with TAA's jitter.
    uv_min = saturate(uv_min - 1.0f / g_hiz_size);
    uv_max = saturate(uv_max + 1.0f / g_hiz_size);

    // The level where the rectangle spans at most two texels each way.
    float2 extent = (uv_max - uv_min) * g_hiz_size;
    uint level = min((uint)ceil(log2(max(max(extent.x, extent.y), 1.0f))), g_hiz_mip_count - 1);
    uint2 level_size = max(uint2(g_hiz_size) >> level, 1);
    uint2 low = min(uint2(uv_min * level_size), level_size - 1);
    uint2 high = min(uint2(uv_max * level_size), level_size - 1);

    float farthest = 0;
    for (uint y = low.y; y <= high.y; y++)
        for (uint x = low.x; x <= high.x; x++)
            farthest = max(farthest, g_hiz.Load(int3(x, y, level)));
    return in_front && nearest > farthest;
}

// Adds the entry's draw to call `command` and counts it: counter 0 the
// camera's draws (1: its calls), 8 the shadow views' (12: their calls).
// Probe captures are not counted. A call counts once, when its first
// instance arrives.
void AddInstance(CullEntry entry, uint command)
{
    // Instances of a call land in whatever order threads get here.
    uint address = CULL_HEADER_SIZE + command * CULL_COMMAND_STRIDE;
    uint previous;
    g_commands.InterlockedAdd(address + CULL_INSTANCE_COUNT_OFFSET, 1, previous);
    g_instances[g_commands.Load(address + CULL_FIRST_INSTANCE_OFFSET) + previous] = entry.draw;

    if (entry.view >= PROBE_FIRST_CULL_VIEW) return;
    uint counter = entry.view == 0 ? 0 : 8;
    uint ignored;
    g_commands.InterlockedAdd(counter, 1, ignored);
    if (previous == 0) g_commands.InterlockedAdd(counter + 4, 1, ignored);
}

// Whether the camera sees only back faces of the meshlet (which the rasterizer
// would cull anyway). Its triangles' normals lie within the cone around the
// axis, so they all face away when the direction to the sphere's center is
// within (90 degrees - cone angle) of the axis, with the sphere's radius as
// margin.
bool ConeFacesAway(Meshlet meshlet, CullBounds bounds, float3 center, float radius)
{
    if (meshlet.cone_cutoff >= 1.0f || bounds.cone_ok == 0) return false;
    float3 axis = normalize(float3(
        dot(bounds.model_rows[0].xyz, meshlet.cone_axis),
        dot(bounds.model_rows[1].xyz, meshlet.cone_axis),
        dot(bounds.model_rows[2].xyz, meshlet.cone_axis)
    ));
    float3 to_center = center - g_camera_position.xyz;
    return dot(to_center, axis) >= meshlet.cone_cutoff * length(to_center) + radius;
}

groupshared uint gs_start;

// One meshlet entry per group (renderer_dispatch_meshlet_cull), in either
// phase, as CSCull treats draws. Every thread runs the same tests; the first
// claims room in the call when the meshlet is visible: the call's index
// count grows by the meshlet's, and the meshlet's indices go into the call's
// region of the compacted index buffer at the old count, copied by all the
// threads. The first meshlet in also records the draw in the call's
// instance and counts the draw and call, like AddInstance; the camera also
// counts meshlets and triangles.
[numthreads(MESHLET_GROUP_SIZE, 1, 1)]
void CSCullMeshlets(uint3 group : SV_GroupID, uint thread : SV_GroupIndex)
{
    bool late = g_pass.x != 0;
    uint id = group.y * MESHLET_GROUPS_PER_ROW + group.x;
    if (id >= (late ? g_camera_meshlet_entry_count : g_meshlet_entry_count)) return;
    bool opaque = id < g_camera_meshlet_entry_count;
    CullEntry entry = g_entries[MESHLET_ENTRY_BASE + id];
    Meshlet meshlet = g_meshlets[entry.meshlet];
    CullBounds draw = g_bounds[entry.draw];

    float4 local = float4(meshlet.center, 1.0f);
    float3 center = float3(dot(draw.model_rows[0], local), dot(draw.model_rows[1], local), dot(draw.model_rows[2], local));
    float radius = meshlet.radius * draw.max_scale;
    CullBounds sphere;
    sphere.center = center;
    sphere.axis_x = float3(radius, 0.0f, 0.0f);
    sphere.axis_y = float3(0.0f, radius, 0.0f);
    sphere.axis_z = float3(0.0f, 0.0f, radius);
    bool in_view = BoundsInFrustum(entry.view, sphere) &&
                   (g_culling_enabled == 0 || !ConeFacesAway(meshlet, draw, center, radius));
    bool drawn_early = opaque && in_view && (g_occlusion_enabled == 0 || g_meshlet_visible[entry.flag] != 0);

    // Early: the meshlets the camera saw last frame. Late: its newly visible
    // ones, recording what it sees.
    uint command = entry.command;
    bool add;
    if (!late)
    {
        add = in_view && (!opaque || drawn_early);
    }
    else
    {
        bool visible = in_view && !(g_occlusion_enabled != 0 && BoundsOccluded(sphere));
        if (thread == 0) g_meshlet_visible[entry.flag] = visible ? 1 : 0;
        add = visible && !drawn_early;
        command += g_late_command_offset;
    }
    if (!add) return;

    uint address = CULL_HEADER_SIZE + command * CULL_COMMAND_STRIDE;
    if (thread == 0)
    {
        uint previous;
        g_commands.InterlockedAdd(address + CULL_INDEX_COUNT_OFFSET, meshlet.index_count, previous);
        uint start = g_commands.Load(address + CULL_START_INDEX_OFFSET);
        if (late)
        {
            // A late call shares its early call's region, after the early
            // meshlets (whose count is final by now).
            uint early = CULL_HEADER_SIZE + entry.command * CULL_COMMAND_STRIDE;
            start = g_commands.Load(early + CULL_START_INDEX_OFFSET) + g_commands.Load(early + CULL_INDEX_COUNT_OFFSET);
            if (previous == 0) g_commands.Store(address + CULL_START_INDEX_OFFSET, start);
        }
        gs_start = start + previous;
        uint ignored;
        if (previous == 0)
        {
            g_instances[g_commands.Load(address + CULL_FIRST_INSTANCE_OFFSET)] = entry.draw;
            if (entry.view < PROBE_FIRST_CULL_VIEW)
            {
                uint counter = entry.view == 0 ? 0 : 8;
                g_commands.InterlockedAdd(counter, 1, ignored);
                g_commands.InterlockedAdd(counter + 4, 1, ignored);
            }
        }
        if (entry.view == 0)
        {
            g_commands.InterlockedAdd(20, 1, ignored);
            g_commands.InterlockedAdd(24, meshlet.index_count / 3, ignored);
        }
    }
    GroupMemoryBarrierWithGroupSync();

    ByteAddressBuffer source = g_mesh_indices[NonUniformResourceIndex(meshlet.index_buffer)];
    for (uint i = thread; i < meshlet.index_count; i += MESHLET_GROUP_SIZE)
    {
        g_meshlet_indices.Store((gs_start + i) * 4u, source.Load((meshlet.first_index + i) * 4u));
    }
}
[numthreads(64, 1, 1)]
void CSCull(uint id : SV_DispatchThreadID)
{
    bool late = g_pass.x != 0;
    if (id >= (late ? g_camera_entry_count : g_entry_count)) return;
    bool opaque = id < g_opaque_entry_count;
    bool blended = !opaque && id < g_camera_entry_count;
    // Blended draws write no depth, so the early phase leaves them alone.
    if (!late && blended) return;

    CullEntry entry = g_entries[id];
    CullBounds bounds = g_bounds[entry.draw];
    bool in_frustum = BoundsInFrustum(entry.view, bounds);

    if (!late)
    {
        // Shadow views, and the camera's draws it saw last frame.
        bool drawn_early = opaque && (g_occlusion_enabled == 0 || g_visible[entry.draw] != 0);
        if (in_frustum && (!opaque || drawn_early)) AddInstance(entry, entry.command);
        return;
    }

    bool drawn_early = opaque && in_frustum && (g_occlusion_enabled == 0 || g_visible[entry.draw] != 0);
    bool visible = in_frustum;
    if (in_frustum && g_occlusion_enabled != 0 && BoundsOccluded(bounds))
    {
        visible = false;
        uint ignored;
        g_commands.InterlockedAdd(16, 1, ignored);
    }
    if (opaque)
    {
        g_visible[entry.draw] = visible ? 1 : 0;
        if (visible && !drawn_early) AddInstance(entry, entry.command + g_late_command_offset);
    }
    else if (visible)
    {
        AddInstance(entry, entry.command);
    }
}

// One level of the depth pyramid: each texel is the farthest depth of the
// source texels it covers. Level 0 shrinks the depth buffer to the power of
// two at or below its size in each direction, so a texel covers up to three
// depth texels each way; later levels cover two by two.
[numthreads(8, 8, 1)]
void CSBuildHiZ(uint2 id : SV_DispatchThreadID)
{
    uint2 source_size = g_pass.xy;
    uint2 target_size = g_pass.zw;
    if (any(id >= target_size)) return;
    uint2 low = id * source_size / target_size;
    uint2 high = ((id + 1) * source_size + target_size - 1) / target_size;
    float farthest = 0;
    for (uint y = low.y; y < high.y; y++)
        for (uint x = low.x; x < high.x; x++)
            farthest = max(farthest, g_hiz_source.Load(int3(x, y, 0)));
    g_hiz_target[id] = farthest;
}
