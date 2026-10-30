// GPU frustum culling (renderer_frame_data.odin). The CPU lists every draw
// each view may draw, already grouped into indirect draw calls with room for
// all of them; one thread per entry tests the draw's box against its view's
// frustum, and a visible draw takes the next instance of its call. The mesh
// passes then draw the calls with ExecuteIndirect.

// Must match renderer_frame_data.odin: the camera, then every shadow view.
#define CULL_VIEW_COUNT 33

// g_commands: four counters for the panel, padding to CULL_HEADER_SIZE, then
// the calls (IndirectDraw: vertex and index buffer views, the first
// instance-list entry, then the indexed draw's arguments).
#define CULL_HEADER_SIZE 64
#define CULL_COMMAND_STRIDE 56
#define CULL_FIRST_INSTANCE_OFFSET 32
#define CULL_INSTANCE_COUNT_OFFSET 40

struct CullEntry
{
    uint draw;    // Index into g_bounds, and what the instance list records.
    uint command; // The draw call it would join.
    uint view;    // 0: the camera; 1 + n: shadow view n.
};

// World-space box: center and half-size axes. Draws without bounds come with
// huge axes, so they pass every test.
struct CullBounds
{
    float3 center;
    float3 axis_x;
    float3 axis_y;
    float3 axis_z;
};

cbuffer CullConstants : register(b0)
{
    // Six normalized planes per view, facing inwards.
    float4 g_view_planes[CULL_VIEW_COUNT * 6];
    uint g_entry_count;
    uint g_culling_enabled;
};

StructuredBuffer<CullEntry> g_entries : register(t0);
StructuredBuffer<CullBounds> g_bounds : register(t1);
RWByteAddressBuffer g_commands : register(u0);
RWStructuredBuffer<uint> g_instances : register(u1);

// The CPU's frustum_intersects_bounds: rejected only when the whole box is
// outside one plane, with the same small tolerance.
bool BoundsVisible(uint view, CullBounds bounds)
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
    return visible;
}

[numthreads(64, 1, 1)]
void CSCull(uint id : SV_DispatchThreadID)
{
    if (id >= g_entry_count) return;
    CullEntry entry = g_entries[id];
    if (g_culling_enabled != 0 && !BoundsVisible(entry.view, g_bounds[entry.draw])) return;

    // Instances of a call land in whatever order threads get here.
    uint command = CULL_HEADER_SIZE + entry.command * CULL_COMMAND_STRIDE;
    uint previous;
    g_commands.InterlockedAdd(command + CULL_INSTANCE_COUNT_OFFSET, 1, previous);
    g_instances[g_commands.Load(command + CULL_FIRST_INSTANCE_OFFSET) + previous] = entry.draw;

    // Counters: camera draws and calls, then shadow draws and calls. A call
    // counts once, when its first instance arrives.
    uint counter = entry.view == 0 ? 0 : 8;
    uint ignored;
    g_commands.InterlockedAdd(counter, 1, ignored);
    if (previous == 0) g_commands.InterlockedAdd(counter + 4, 1, ignored);
}
