package main

// Reflection probes. A probe entity captures the scene around it into a cube
// map: the lit scene (sky, sun with its cascades, every point and spot light,
// and the other probes' light) is drawn into six faces, the faces get a mip
// chain, and the chain is prefiltered for roughness 0 to 1 like the
// environment's specular map. Surfaces inside a probe's box take their
// reflections (and, optionally, their diffuse light) from it instead of from
// the sky; SSR still replaces both where it finds the reflected surface.
//
// One probe is captured per frame, when it is new or has moved, and all of
// them again on request or when the environment changes. Captures reuse the
// frame's GPU culling with six more views and its shadow maps.
//
// Irradiance volumes use the same capture for diffuse light: a volume entity
// holds a grid of cells filling its box, and on frames with no probe to
// capture, one cell is captured from its center. A compute pass reduces the
// capture to L1 spherical harmonics (the light's average plus one linear
// term per axis, for each color), which the lit pass interpolates between
// cells and evaluates along the surface normal. Captures shade with the
// volumes captured so far, so each further pass over the cells adds a bounce.
//
// On GPUs with DXR 1.1, volumes are dynamic instead (DDGI, Majercik et al.):
// every cell is a probe that rays update each frame, so its light follows
// moving lights, the sun and edits without baking. A pixel pass traces a
// batch of probes' rays (PSVolumeRays), compute passes blend them into each
// probe's octahedral irradiance and distance maps and move probes out of
// geometry (dynamic_volume.hlsl), and the lit pass weights probes by whether
// they can see the surface (volumes.hlsl, SampleDynamicVolume).

import "core:math"
import "core:math/rand"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

MAX_REFLECTION_PROBES :: 16
PROBE_SIZE :: 256
// Levels of each probe: roughness 0, 0.25, ... 1, read like the prefiltered
// environment (level = roughness * 4).
PROBE_MIP_COUNT :: PREFILTER_MIP_COUNT
// The capture's full chain (256 down to 1), which prefiltering reads from.
PROBE_CAPTURE_MIP_COUNT :: 9
PROBE_FACES :: 6
PROBE_NEAR :: f32(0.05)
PROBE_FORMAT :: dxgi.FORMAT.R16G16B16A16_FLOAT
// GGX samples per prefiltered texel: the capture is small and every sample
// reads a mip matching its footprint, so far fewer than the panorama's 1024.
PROBE_PREFILTER_SAMPLES :: 128
// The cull pass's views for the six capture faces, after the shadow views.
PROBE_FIRST_CULL_VIEW :: 1 + SHADOW_VIEW_COUNT
#assert(PROBE_FIRST_CULL_VIEW == 33) // As in cull.hlsl.

// Static constants for one downsample or prefilter draw (b3): the face, and
// the roughness when prefiltering. Laid out like PrefilterConstants.
PROBE_DOWNSAMPLE_PASSES :: (PROBE_CAPTURE_MIP_COUNT - 1) * PROBE_FACES
PROBE_PASS_COUNT :: PROBE_DOWNSAMPLE_PASSES + PROBE_MIP_COUNT * PROBE_FACES

// Per probe in view, read by the lit pass; laid out like scene.hlsl's.
GpuProbe :: struct {
    // From world space into the box's (the unit cube, -0.5 to 0.5) and back,
    // transposed for the shader's row vectors.
    world_to_box: alg.Matrix4f32,
    box_to_world: alg.Matrix4f32,
    // The world length of the box's x, y and z edges.
    size: [3]f32,
    blend_distance: f32,
    // Its cube in the probe array.
    slot: u32,
    box_projection: u32,
    _pad: [2]u32,
}
#assert(size_of(GpuProbe) == 160)

Probes :: struct {
    enabled: bool,
    // Probes also replace the sky's diffuse light (from their roughest
    // level). Off by default: a capture holds light that bounced once, so
    // interiors come out much darker than with the sky's light.
    diffuse: bool,

    // Each slot's cube in `array`, the entity it belongs to (-1: free), and
    // where it was captured from (once `captured`).
    slot_entity: [MAX_REFLECTION_PROBES]int,
    captured: [MAX_REFLECTION_PROBES]bool,
    captured_position: [MAX_REFLECTION_PROBES]alg.Vector3f32,
    // This frame: the probes in the GPU buffer, the probes in the scene, and
    // the slot being captured (-1: none) and from where.
    count, scene_count: int,
    capture_slot: int,
    capture_position: alg.Vector3f32,

    // The prefiltered cubes, every slot's six faces in turn.
    array: ^d3d12.IResource,
    // The capture: color with its full mip chain, and depth.
    capture_texture, capture_depth: ^d3d12.IResource,
    // RTVs: the capture's faces at every level (level * 6 + face), then the
    // capturing slot's faces at every level of `array`. DSVs: the faces.
    rtv_heap, dsv_heap: ^d3d12.IDescriptorHeap,
    // The array as cubes; the capture as a cube; each capture level alone as
    // six slices (the downsample source).
    srv_index, capture_srv_index, capture_level_srv_start: u32,

    // Per frame slot: the GpuProbe list, and the six faces' frame and sky
    // constants (written only on frames that capture).
    buffer: ^d3d12.IResource,
    mapped: [^]GpuProbe,
    frame_constant_buffer: ^d3d12.IResource,
    frame_constants: [^]FrameConstants,
    sky_constant_buffer: ^d3d12.IResource,
    sky_constants: [^]SkyConstants,
    pass_constant_buffer: ^d3d12.IResource,

    capture_pipeline_states: [Draw_Variant]^d3d12.IPipelineState,
    downsample_pipeline_state, prefilter_pipeline_state: ^d3d12.IPipelineState,
}

MAX_IRRADIANCE_VOLUMES :: 4
IRRADIANCE_VOLUME_MAX_CELLS :: 32
// The atlas holds every volume's cells, each slot a block of up to 32^3
// cells along z. A block has four planes along x: the red, green and blue
// coefficients (times the cell's validity), then the validity alone, so
// that filtering both and dividing weights the valid cells only.
VOLUME_PLANES :: 4
VOLUME_ATLAS_WIDTH :: VOLUME_PLANES * IRRADIANCE_VOLUME_MAX_CELLS
VOLUME_ATLAS_HEIGHT :: IRRADIANCE_VOLUME_MAX_CELLS
VOLUME_ATLAS_DEPTH :: MAX_IRRADIANCE_VOLUMES * IRRADIANCE_VOLUME_MAX_CELLS
VOLUME_FORMAT :: dxgi.FORMAT.R16G16B16A16_FLOAT
// The capture level the projection reads: 32 x 32 texels per face.
VOLUME_SH_LEVEL :: 3
// Passes over every cell: the first gives one bounce of light, each further
// one another.
DEFAULT_VOLUME_BOUNCES :: 2
MAX_VOLUME_BOUNCES :: 8
// Where a cell is captured from, in cells from its center: the center first,
// and while the capture comes out invalid (inside a wall or a model), the
// next of these, as DDGI moves its probes out of geometry.
VOLUME_CELL_OFFSETS := [?][3]f32{
    {0, 0, 0},
    {0.45, 0, 0}, {-0.45, 0, 0}, {0, 0.45, 0}, {0, -0.45, 0}, {0, 0, 0.45}, {0, 0, -0.45},
    {0.35, 0.35, 0.35}, {-0.35, 0.35, 0.35}, {0.35, -0.35, 0.35}, {-0.35, -0.35, 0.35},
    {0.35, 0.35, -0.35}, {-0.35, 0.35, -0.35}, {0.35, -0.35, -0.35}, {-0.35, -0.35, -0.35},
}
// Below this validity a capture counts as invalid and moves on.
VOLUME_RETRY_VALIDITY :: 0.5

// Cells per volume at most (its room in the dynamic atlases).
IRRADIANCE_VOLUME_MAX_TOTAL_CELLS :: 8192
// Dynamic volumes' atlases (volumes.hlsl): a tile per probe, 256 per row,
// each volume's probes from slot * IRRADIANCE_VOLUME_MAX_TOTAL_CELLS on.
DYNAMIC_ATLAS_COLUMNS :: 256
DYNAMIC_ATLAS_ROWS :: MAX_IRRADIANCE_VOLUMES * IRRADIANCE_VOLUME_MAX_TOTAL_CELLS / DYNAMIC_ATLAS_COLUMNS
#assert(DYNAMIC_ATLAS_ROWS == 128) // As volumes.hlsl.
DYNAMIC_IRRADIANCE_TILE :: 8
DYNAMIC_DISTANCE_TILE :: 16
// The rays texture: a row of up to this many rays per probe of the batch.
DYNAMIC_MAX_RAYS :: 256
DYNAMIC_MAX_BATCH :: 4096
DEFAULT_DYNAMIC_RAYS :: 128
DEFAULT_DYNAMIC_BATCH :: 2048
DEFAULT_DYNAMIC_HYSTERESIS :: f32(0.97)

// This frame's probe update, for PSVolumeRays (b3) and dynamic_volume.hlsl;
// laid out like volumes.hlsl's cbuffer.
DynamicVolumeConstants :: struct #align(256) {
    rotation: [3][4]f32,
    rays, batch, cursor, total: u32,
    hysteresis: f32,
    volume_count: u32,
    _pad: [2]f32,
}

Dynamic_Root_Slot :: enum u32 {Constants, Volumes, Rays, Atlases, Reset}

// A cell captured in some frame, whose validity is read back when that
// frame's slot comes round again.
VolumeCapture :: struct {
    active: bool,
    slot, cell: int,
    offset: u8,
    generation: u32,
}

// Per volume in use, read by the lit pass; laid out like scene.hlsl's.
GpuIrradianceVolume :: struct {
    // From world space into the box's unit cube and back, transposed.
    world_to_box: alg.Matrix4f32,
    box_to_world: alg.Matrix4f32,
    // The world length of the box's edges.
    size: [3]f32,
    blend_distance: f32,
    cells: [3]u32,
    // Its block's first slice in the atlas.
    first_z: u32,
    // How far along the normal the lookup moves, away from the surface the
    // nearest cells may be behind.
    normal_bias: f32,
    // Dynamic: its first probe in the atlases, its first place in the order
    // probes are updated in, its probe count, and the longest distance the
    // distance maps record.
    first_probe: u32,
    sequence_start: u32,
    probe_count: u32,
    max_distance: f32,
    _pad: [3]f32,
}
#assert(size_of(GpuIrradianceVolume) == 192)

IrradianceVolumes :: struct {
    enabled: bool,
    // Passes over the cells (DEFAULT_VOLUME_BOUNCES).
    bounces: i32,
    // Debug view: the lit pass shows only the diffuse ambient light.
    show: bool,

    // Each slot's entity (-1: free), what its cells were captured for (a
    // change of cells clears the block; a move captures again over the old
    // values), and how many cells it has captured, over every pass.
    slot_entity: [MAX_IRRADIANCE_VOLUMES]int,
    captured_world: [MAX_IRRADIANCE_VOLUMES]alg.Matrix4f32,
    captured_cells: [MAX_IRRADIANCE_VOLUMES][3]i32,
    progress: [MAX_IRRADIANCE_VOLUMES]int,
    clear_pending: [MAX_IRRADIANCE_VOLUMES]bool,
    // Per cell, the VOLUME_CELL_OFFSETS entry it is captured from; the cells
    // waiting to be captured again from their next one (before the pass goes
    // on); and each slot's resets, so that results of captures made before
    // one are ignored.
    cell_offset: [MAX_IRRADIANCE_VOLUMES][dynamic]u8,
    retry: [MAX_IRRADIANCE_VOLUMES][dynamic]int,
    generation: [MAX_IRRADIANCE_VOLUMES]u32,
    // This frame: the volumes in the GPU buffer and in the scene, and the
    // cell being captured (slot -1: none) with its offset.
    count, scene_count: int,
    capture_slot: int,
    capture_cell: [3]i32,
    capture_offset: [3]f32,
    // Per frame slot: the cell captured then. The projection also writes the
    // cell's validity to `result`, copied to `readback`.
    captures: [FRAME_COUNT]VolumeCapture,
    result, readback: ^d3d12.IResource,

    atlas: ^d3d12.IResource,
    srv_index, uav_index: u32,
    // Per frame slot: the GpuIrradianceVolume list.
    buffer: ^d3d12.IResource,
    mapped: [^]GpuIrradianceVolume,

    // The projection and clear passes (shaders/irradiance_volume.hlsl), and
    // the capture pipelines: like the probes', but drawing back faces too, so
    // a cell can tell it is inside a wall.
    root_signature: ^d3d12.IRootSignature,
    project_pipeline_state, clear_pipeline_state: ^d3d12.IPipelineState,
    capture_pipeline_states: [Draw_Variant]^d3d12.IPipelineState,

    // Dynamic volumes (DXR 1.1): the setting, rays per probe, the most
    // probes updated per frame, and how much of its old light a probe keeps
    // per update.
    ray_traced: bool,
    rays, batch_limit: i32,
    hysteresis: f32,
    // This frame's batch: where it starts in the update order, its size, and
    // the order's length (every listed volume's probes). Slots whose probes
    // start over this frame, and whether last frame was dynamic (turning it
    // on starts every slot over).
    cursor, batch, total: int,
    dynamic_reset: [MAX_IRRADIANCE_VOLUMES]bool,
    was_dynamic: bool,
    // The atlases (irradiance, distance, probe data), as consecutive SRVs
    // and UAVs; the rays texture with its SRV and RTV.
    irradiance, distance, probe_data, rays_texture: ^d3d12.IResource,
    dynamic_srv_start, dynamic_uav_start, rays_srv_index: u32,
    rays_rtv_heap: ^d3d12.IDescriptorHeap,
    // Per frame slot: DynamicVolumeConstants.
    dynamic_constant_buffer: ^d3d12.IResource,
    dynamic_constants: [^]DynamicVolumeConstants,
    dynamic_root_signature: ^d3d12.IRootSignature,
    ray_pipeline_state: ^d3d12.IPipelineState,
    blend_irradiance_pipeline_state, blend_distance_pipeline_state: ^d3d12.IPipelineState,
    relocate_pipeline_state, reset_pipeline_state: ^d3d12.IPipelineState,
}

// The root constants of the projection and clear passes (b0).
VolumePassConstants :: struct {
    cell: [3]u32,
    first_z: u32,
    // Where the cell was captured from, in cells from its center.
    offset: [3]f32,
    _pad: f32,
}

Volume_Root_Slot :: enum u32 {Constants, Capture, Atlas, Result}

renderer_create_probes :: proc() {
    r := &g_renderer
    p := &r.probes
    for &entity in p.slot_entity do entity = -1
    p.capture_slot = -1

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = PROBE_SIZE,
        Height = PROBE_SIZE,
        DepthOrArraySize = MAX_REFLECTION_PROBES * PROBE_FACES,
        MipLevels = PROBE_MIP_COUNT,
        Format = PROBE_FORMAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }
    dx_check(r.device->CreateCommittedResource(
        &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, nil, d3d12.IResource_UUID, (^rawptr)(&p.array),
    ))
    desc.DepthOrArraySize = PROBE_FACES
    desc.MipLevels = PROBE_CAPTURE_MIP_COUNT
    clear_color := d3d12.CLEAR_VALUE{Format = PROBE_FORMAT}
    dx_check(r.device->CreateCommittedResource(
        &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, &clear_color, d3d12.IResource_UUID, (^rawptr)(&p.capture_texture),
    ))
    desc.MipLevels = 1
    desc.Format = .D32_FLOAT
    desc.Flags = {.ALLOW_DEPTH_STENCIL, .DENY_SHADER_RESOURCE}
    clear_depth := d3d12.CLEAR_VALUE{Format = .D32_FLOAT}
    clear_depth.DepthStencil = {Depth = 1}
    dx_check(r.device->CreateCommittedResource(
        &heap_props, {}, &desc, {.DEPTH_WRITE}, &clear_depth, d3d12.IResource_UUID, (^rawptr)(&p.capture_depth),
    ))

    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = PROBE_CAPTURE_MIP_COUNT * PROBE_FACES + PROBE_MIP_COUNT * PROBE_FACES,
        Type = .RTV,
    }
    dx_check(r.device->CreateDescriptorHeap(&rtv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&p.rtv_heap)))
    dsv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = PROBE_FACES, Type = .DSV}
    dx_check(r.device->CreateDescriptorHeap(&dsv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&p.dsv_heap)))
    for face in 0..<u32(PROBE_FACES) {
        for level in 0..<u32(PROBE_CAPTURE_MIP_COUNT) {
            renderer_write_face_rtv(p.capture_texture, level, face, descriptor_handle(p.rtv_heap, .RTV, level * PROBE_FACES + face))
        }
        dsv := d3d12.DEPTH_STENCIL_VIEW_DESC{Format = .D32_FLOAT, ViewDimension = .TEXTURE2DARRAY}
        dsv.Texture2DArray = {FirstArraySlice = face, ArraySize = 1}
        r.device->CreateDepthStencilView(p.capture_depth, &dsv, descriptor_handle(p.dsv_heap, .DSV, face))
    }

    p.srv_index = renderer_alloc_srv()
    p.capture_srv_index = renderer_alloc_srv()
    p.capture_level_srv_start = renderer_alloc_srv(PROBE_CAPTURE_MIP_COUNT)
    srv := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = PROBE_FORMAT,
        ViewDimension = .TEXTURECUBEARRAY,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv.TextureCubeArray = {MipLevels = PROBE_MIP_COUNT, NumCubes = MAX_REFLECTION_PROBES}
    r.device->CreateShaderResourceView(p.array, &srv, renderer_srv_cpu(p.srv_index))
    srv.ViewDimension = .TEXTURECUBE
    srv.TextureCube = {MipLevels = PROBE_CAPTURE_MIP_COUNT}
    r.device->CreateShaderResourceView(p.capture_texture, &srv, renderer_srv_cpu(p.capture_srv_index))
    srv.ViewDimension = .TEXTURE2DARRAY
    for level in 0..<u32(PROBE_CAPTURE_MIP_COUNT) {
        srv.Texture2DArray = {MostDetailedMip = level, MipLevels = 1, ArraySize = PROBE_FACES}
        r.device->CreateShaderResourceView(p.capture_texture, &srv, renderer_srv_cpu(p.capture_level_srv_start + level))
    }

    mapped: rawptr
    p.buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_REFLECTION_PROBES * size_of(GpuProbe)))
    p.mapped = ([^]GpuProbe)(mapped)
    p.frame_constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * PROBE_FACES * size_of(FrameConstants)))
    p.frame_constants = ([^]FrameConstants)(mapped)
    p.sky_constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * PROBE_FACES * size_of(SkyConstants)))
    p.sky_constants = ([^]SkyConstants)(mapped)

    // The volumes' atlas, at rest a pixel-shader resource; the projection
    // and clear passes write it as a UAV.
    v := &r.volumes
    for &entity in v.slot_entity do entity = -1
    v.capture_slot = -1
    atlas_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE3D,
        Width = VOLUME_ATLAS_WIDTH,
        Height = VOLUME_ATLAS_HEIGHT,
        DepthOrArraySize = VOLUME_ATLAS_DEPTH,
        MipLevels = 1,
        Format = VOLUME_FORMAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_UNORDERED_ACCESS},
    }
    dx_check(r.device->CreateCommittedResource(
        &heap_props, {}, &atlas_desc, {.PIXEL_SHADER_RESOURCE}, nil, d3d12.IResource_UUID, (^rawptr)(&v.atlas),
    ))
    v.srv_index = renderer_alloc_srv()
    v.uav_index = renderer_alloc_srv()
    atlas_srv := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = VOLUME_FORMAT,
        ViewDimension = .TEXTURE3D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    atlas_srv.Texture3D = {MipLevels = 1}
    r.device->CreateShaderResourceView(v.atlas, &atlas_srv, renderer_srv_cpu(v.srv_index))
    atlas_uav := d3d12.UNORDERED_ACCESS_VIEW_DESC{Format = VOLUME_FORMAT, ViewDimension = .TEXTURE3D}
    atlas_uav.Texture3D = {WSize = VOLUME_ATLAS_DEPTH}
    r.device->CreateUnorderedAccessView(v.atlas, nil, &atlas_uav, renderer_srv_cpu(v.uav_index))
    v.buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_IRRADIANCE_VOLUMES * size_of(GpuIrradianceVolume)))
    v.mapped = ([^]GpuIrradianceVolume)(mapped)
    // A UAV between captures; committed buffers start in COMMON, which a
    // UAV access promotes from.
    v.result = create_buffer(16, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    v.readback = create_buffer(FRAME_COUNT * 16, .READBACK, {}, {.COPY_DEST})
    renderer_create_dynamic_volumes()

    p.pass_constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(PROBE_PASS_COUNT * size_of(PrefilterConstants)))
    passes := ([^]PrefilterConstants)(mapped)
    for face in 0..<PROBE_FACES {
        for level in 1..<PROBE_CAPTURE_MIP_COUNT {
            passes[renderer_probe_downsample_pass(level, face)] = {face = u32(face)}
        }
        for level in 0..<PROBE_MIP_COUNT {
            passes[renderer_probe_prefilter_pass(level, face)] = {
                roughness = f32(level) / f32(PROBE_MIP_COUNT - 1),
                face = u32(face),
                sample_count = PROBE_PREFILTER_SAMPLES,
            }
        }
    }
}

renderer_release_probes :: proc() {
    p := &g_renderer.probes
    p.array->Release()
    p.capture_texture->Release()
    p.capture_depth->Release()
    p.rtv_heap->Release()
    p.dsv_heap->Release()
    p.buffer->Release()
    p.frame_constant_buffer->Release()
    p.sky_constant_buffer->Release()
    p.pass_constant_buffer->Release()
    v := &g_renderer.volumes
    v.atlas->Release()
    v.buffer->Release()
    v.result->Release()
    v.readback->Release()
    v.root_signature->Release()
    for slot in 0..<MAX_IRRADIANCE_VOLUMES {
        delete(v.cell_offset[slot])
        delete(v.retry[slot])
    }
    if g_renderer.ray_tracing.supported {
        v.irradiance->Release()
        v.distance->Release()
        v.probe_data->Release()
        v.rays_texture->Release()
        v.rays_rtv_heap->Release()
        v.dynamic_constant_buffer->Release()
        v.dynamic_root_signature->Release()
    }
}

// The dynamic volumes' settings and resources, on GPUs with DXR 1.1. The
// atlases rest as pixel-shader resources (the lit pass and the rays read
// them) and are written as UAVs; the rays texture rests as a compute input.
// Committed resources start zeroed, so every probe starts never updated.
renderer_create_dynamic_volumes :: proc() {
    r := &g_renderer
    v := &r.volumes
    if !r.ray_tracing.supported do return
    v.ray_traced = true
    v.rays = DEFAULT_DYNAMIC_RAYS
    v.batch_limit = DEFAULT_DYNAMIC_BATCH
    v.hysteresis = DEFAULT_DYNAMIC_HYSTERESIS

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    Atlas :: struct {texture: ^^d3d12.IResource, width, height: u32, format: dxgi.FORMAT}
    atlases := [3]Atlas{
        {&v.irradiance, DYNAMIC_ATLAS_COLUMNS * DYNAMIC_IRRADIANCE_TILE, DYNAMIC_ATLAS_ROWS * DYNAMIC_IRRADIANCE_TILE, .R16G16B16A16_FLOAT},
        {&v.distance, DYNAMIC_ATLAS_COLUMNS * DYNAMIC_DISTANCE_TILE, DYNAMIC_ATLAS_ROWS * DYNAMIC_DISTANCE_TILE, .R16G16_FLOAT},
        {&v.probe_data, DYNAMIC_ATLAS_COLUMNS, DYNAMIC_ATLAS_ROWS, .R32G32B32A32_FLOAT},
    }
    v.dynamic_srv_start = renderer_alloc_srv(len(atlases))
    v.dynamic_uav_start = renderer_alloc_srv(len(atlases))
    for atlas, i in atlases {
        desc := d3d12.RESOURCE_DESC{
            Dimension = .TEXTURE2D,
            Width = u64(atlas.width),
            Height = atlas.height,
            DepthOrArraySize = 1,
            MipLevels = 1,
            Format = atlas.format,
            SampleDesc = {Count = 1},
            Flags = {.ALLOW_UNORDERED_ACCESS},
        }
        dx_check(r.device->CreateCommittedResource(
            &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, nil, d3d12.IResource_UUID, (^rawptr)(atlas.texture),
        ))
        renderer_write_srv(atlas.texture^, atlas.format, v.dynamic_srv_start + u32(i))
        uav := d3d12.UNORDERED_ACCESS_VIEW_DESC{Format = atlas.format, ViewDimension = .TEXTURE2D}
        r.device->CreateUnorderedAccessView(atlas.texture^, nil, &uav, renderer_srv_cpu(v.dynamic_uav_start + u32(i)))
    }

    rays_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = DYNAMIC_MAX_RAYS,
        Height = DYNAMIC_MAX_BATCH,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .R32G32B32A32_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }
    clear_value := d3d12.CLEAR_VALUE{Format = .R32G32B32A32_FLOAT}
    dx_check(r.device->CreateCommittedResource(
        &heap_props, {}, &rays_desc, {.NON_PIXEL_SHADER_RESOURCE}, &clear_value, d3d12.IResource_UUID, (^rawptr)(&v.rays_texture),
    ))
    v.rays_srv_index = renderer_alloc_srv()
    renderer_write_srv(v.rays_texture, .R32G32B32A32_FLOAT, v.rays_srv_index)
    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = 1, Type = .RTV}
    dx_check(r.device->CreateDescriptorHeap(&rtv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&v.rays_rtv_heap)))
    r.device->CreateRenderTargetView(v.rays_texture, nil, descriptor_handle(v.rays_rtv_heap, .RTV, 0))

    mapped: rawptr
    v.dynamic_constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * size_of(DynamicVolumeConstants)))
    v.dynamic_constants = ([^]DynamicVolumeConstants)(mapped)
}

// Whether this frame's volumes are dynamic (ray-traced probes).
renderer_dynamic_volumes_active :: proc() -> bool {
    r := &g_renderer
    return r.ray_tracing.supported && r.volumes.enabled && r.volumes.ray_traced
}

// A render target view of one face (array slice) of one level.
renderer_write_face_rtv :: proc(texture: ^d3d12.IResource, level, slice: u32, handle: d3d12.CPU_DESCRIPTOR_HANDLE) {
    rtv := d3d12.RENDER_TARGET_VIEW_DESC{Format = PROBE_FORMAT, ViewDimension = .TEXTURE2DARRAY}
    rtv.Texture2DArray = {MipSlice = level, FirstArraySlice = slice, ArraySize = 1}
    g_renderer.device->CreateRenderTargetView(texture, &rtv, handle)
}

// Slots of the static pass constants: downsampling into capture level
// `level` (1 and up), and prefiltering probe level `level`.
renderer_probe_downsample_pass :: proc(level, face: int) -> int {
    return (level - 1) * PROBE_FACES + face
}

renderer_probe_prefilter_pass :: proc(level, face: int) -> int {
    return PROBE_DOWNSAMPLE_PASSES + level * PROBE_FACES + face
}

// Every probe is captured again, one per frame: after the environment or
// lighting changed, or a new scene was loaded (with `forget`, which also
// frees the slots of entities that no longer exist). The volumes too, unless
// only the probes were asked for.
renderer_recapture_probes :: proc(forget := false, volumes := true) {
    p := &g_renderer.probes
    p.captured = {}
    if forget do for &entity in p.slot_entity do entity = -1
    if volumes do renderer_recapture_volumes(forget = forget)
}

// Every volume's cells are captured again over their current values, or,
// with `forget`, from cleared slots (a new scene).
renderer_recapture_volumes :: proc(forget := false) {
    v := &g_renderer.volumes
    v.progress = {}
    // Dynamic probes start over: their light no longer applies.
    for &reset in v.dynamic_reset do reset = true
    if forget do for &entity in v.slot_entity do entity = -1
}

// Captures one volume's cells again, keeping their values until replaced
// (dynamic: its probes start over).
renderer_recapture_volume :: proc(entity: int) {
    v := &g_renderer.volumes
    if slot := renderer_volume_slot(entity); slot >= 0 {
        v.progress[slot] = 0
        v.dynamic_reset[slot] = true
    }
}

renderer_volume_slot :: proc(entity: int) -> int {
    for owner, slot in g_renderer.volumes.slot_entity do if owner == entity do return slot
    return -1
}

renderer_volume_cell_count :: proc(cells: [3]i32) -> int {
    return int(cells.x) * int(cells.y) * int(cells.z)
}

// A volume's progress: cells captured in the current pass, the pass (from
// 0; `bounces` once complete), and whether it has a slot at all.
renderer_volume_progress :: proc(entity: int) -> (cells, pass: int, ok: bool) {
    v := &g_renderer.volumes
    slot := renderer_volume_slot(entity)
    if slot < 0 do return 0, 0, false
    count := renderer_volume_cell_count(v.captured_cells[slot])
    total := count * int(v.bounces)
    if v.progress[slot] >= total && len(v.retry[slot]) == 0 do return count, int(v.bounces), true
    if v.progress[slot] >= total do return count, int(v.bounces) - 1, true
    return v.progress[slot] % count, v.progress[slot] / count, true
}

// Gives each volume in the scene a slot, picks this frame's cell to capture
// if no reflection probe takes the capture, and lists the volumes for the
// lit pass (partly captured ones too: cells not captured yet have no
// weight). Volumes beyond MAX_IRRADIANCE_VOLUMES are ignored.
renderer_update_volumes :: proc(scene: ^Scene) {
    r := &g_renderer
    v := &r.volumes
    is_volume :: proc(scene: ^Scene, index: int) -> bool {
        return index < scene.entity_count && scene.alive[index] && scene.has_transform[index] && scene.has_irradiance_volume[index]
    }
    for &entity in v.slot_entity do if entity >= 0 && !is_volume(scene, entity) do entity = -1

    v.count, v.scene_count = 0, 0
    v.capture_slot = -1
    v.captures[r.frame_slot].active = false
    is_dynamic := renderer_dynamic_volumes_active()
    if is_dynamic && !v.was_dynamic do for &reset in v.dynamic_reset do reset = true
    v.was_dynamic = is_dynamic
    v.total = 0
    gpu := v.mapped[int(r.frame_slot) * MAX_IRRADIANCE_VOLUMES:]
    for i in 0..<scene.entity_count {
        if !is_volume(scene, i) do continue
        v.scene_count += 1
        volume := scene.irradiance_volumes[i]
        world := scene_world_matrix(scene, i)
        slot := renderer_volume_slot(i)
        if slot < 0 {
            for entity, s in v.slot_entity do if entity < 0 && slot < 0 do slot = s
            if slot < 0 do continue
            v.slot_entity[slot] = i
            v.captured_cells[slot] = {}
        }
        count := renderer_volume_cell_count(volume.cells)
        // New cells start from nothing; a move captures over the old values.
        // Either way the cells look for their capture points again.
        moved := v.captured_world[slot] != world
        if v.captured_cells[slot] != volume.cells {
            v.captured_cells[slot] = volume.cells
            v.clear_pending[slot] = true
            resize(&v.cell_offset[slot], count)
        }
        if moved || v.clear_pending[slot] {
            v.captured_world[slot] = world
            v.progress[slot] = 0
            for &offset in v.cell_offset[slot] do offset = 0
            clear(&v.retry[slot])
            v.generation[slot] += 1
            v.dynamic_reset[slot] = true
        }
        if !v.enabled do continue

        // Baked: cells moving out of geometry go first, then the pass goes
        // on. Dynamic volumes capture nothing.
        if !is_dynamic && v.capture_slot < 0 && r.probes.capture_slot < 0 {
            index := -1
            if len(v.retry[slot]) > 0 {
                index = pop(&v.retry[slot])
            } else if v.progress[slot] < count * int(v.bounces) {
                index = v.progress[slot] % count
                v.progress[slot] += 1
            }
            if index >= 0 {
                cell := [3]i32{i32(index) % volume.cells.x, i32(index) / volume.cells.x % volume.cells.y, i32(index) / (volume.cells.x * volume.cells.y)}
                offset := v.cell_offset[slot][index]
                v.capture_slot = slot
                v.capture_cell = cell
                v.capture_offset = VOLUME_CELL_OFFSETS[offset]
                v.captures[r.frame_slot] = {active = true, slot = slot, cell = index, offset = offset, generation = v.generation[slot]}
                local := (alg.Vector3f32{f32(cell.x), f32(cell.y), f32(cell.z)} + 0.5 + v.capture_offset) / alg.Vector3f32{f32(volume.cells.x), f32(volume.cells.y), f32(volume.cells.z)} - 0.5
                center := world * alg.Vector4f32{local.x, local.y, local.z, 1}
                r.probes.capture_position = center.xyz
            }
        }

        size := alg.Vector3f32{
            alg.length(alg.Vector3f32{world[0, 0], world[1, 0], world[2, 0]}),
            alg.length(alg.Vector3f32{world[0, 1], world[1, 1], world[2, 1]}),
            alg.length(alg.Vector3f32{world[0, 2], world[1, 2], world[2, 2]}),
        }
        cell_size := size / alg.Vector3f32{f32(volume.cells.x), f32(volume.cells.y), f32(volume.cells.z)}
        gpu[v.count] = GpuIrradianceVolume{
            world_to_box = alg.transpose(alg.matrix4_inverse_f32(world)),
            box_to_world = alg.transpose(world),
            size = size,
            blend_distance = volume.blend_distance,
            cells = {u32(volume.cells.x), u32(volume.cells.y), u32(volume.cells.z)},
            first_z = u32(slot * IRRADIANCE_VOLUME_MAX_CELLS),
            normal_bias = 0.2 * min(cell_size.x, cell_size.y, cell_size.z),
            first_probe = u32(slot * IRRADIANCE_VOLUME_MAX_TOTAL_CELLS),
            sequence_start = u32(v.total),
            probe_count = u32(count),
            max_distance = 1.5 * alg.length(cell_size),
        }
        v.count += 1
        v.total += count
    }

    v.batch = 0
    if is_dynamic && v.total > 0 do renderer_schedule_dynamic_volumes()
}

// This frame's batch of dynamic probes: the next ones in the update order
// (round-robin over every listed volume's probes), and a random rotation
// for their rays.
renderer_schedule_dynamic_volumes :: proc() {
    r := &g_renderer
    v := &r.volumes
    v.batch = min(int(v.batch_limit), v.total, DYNAMIC_MAX_BATCH)
    v.cursor %= v.total

    axis := alg.Vector3f32{rand.float32() * 2 - 1, rand.float32() * 2 - 1, rand.float32() * 2 - 1}
    if alg.length(axis) < 1e-3 do axis = {0, 1, 0}
    rotation := alg.matrix3_from_quaternion_f32(alg.quaternion_angle_axis_f32(rand.float32() * 2 * math.PI, alg.normalize(axis)))
    constants := DynamicVolumeConstants{
        rays = u32(v.rays),
        batch = u32(v.batch),
        cursor = u32(v.cursor),
        total = u32(v.total),
        hysteresis = v.hysteresis,
        volume_count = u32(v.count),
    }
    for row in 0..<3 do constants.rotation[row] = {rotation[row, 0], rotation[row, 1], rotation[row, 2], 0}
    v.dynamic_constants[r.frame_slot] = constants
    v.cursor = (v.cursor + v.batch) % v.total
}

renderer_dynamic_constants_address :: proc() -> u64 {
    r := &g_renderer
    return r.volumes.dynamic_constant_buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * size_of(DynamicVolumeConstants)
}

renderer_dynamic_atlas_barriers :: proc(before, after: d3d12.RESOURCE_STATES) {
    v := &g_renderer.volumes
    barriers := [3]d3d12.RESOURCE_BARRIER{
        resource_transition(v.irradiance, before, after),
        resource_transition(v.distance, before, after),
        resource_transition(v.probe_data, before, after),
    }
    g_renderer.command_list->ResourceBarrier(len(barriers), &barriers[0])
}

// The dynamic volumes' update, after the light clusters (probe rays light
// their hits with them) and before reflections and the lit pass, which read
// the result: probes of slots that start over are cleared, the batch's rays
// are traced, then blended into the probes, which then move.
renderer_update_dynamic_volumes :: proc() {
    r := &g_renderer
    v := &r.volumes
    renderer_begin_gpu_pass(.Dynamic_GI)
    defer renderer_end_gpu_pass(.Dynamic_GI)
    if !renderer_dynamic_volumes_active() do return

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    resets := false
    for reset in v.dynamic_reset do resets ||= reset
    if resets {
        renderer_begin_event("Start over")
        renderer_dynamic_atlas_barriers({.PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS})
        renderer_bind_dynamic_compute()
        r.command_list->SetPipelineState(v.reset_pipeline_state)
        for &reset, slot in v.dynamic_reset {
            if !reset do continue
            reset = false
            range := [2]u32{u32(slot * IRRADIANCE_VOLUME_MAX_TOTAL_CELLS), IRRADIANCE_VOLUME_MAX_TOTAL_CELLS}
            r.command_list->SetComputeRoot32BitConstants(u32(Dynamic_Root_Slot.Reset), 2, &range, 0)
            r.command_list->Dispatch(IRRADIANCE_VOLUME_MAX_TOTAL_CELLS / 64, 1, 1)
        }
        renderer_dynamic_atlas_barriers({.UNORDERED_ACCESS}, {.PIXEL_SHADER_RESOURCE})
        renderer_end_event()
    }
    if v.batch == 0 do return

    // One pixel per ray: the batch's probes are rows.
    renderer_begin_event("Probe rays")
    barrier := resource_transition(v.rays_texture, {.NON_PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET})
    r.command_list->ResourceBarrier(1, &barrier)
    rtv := descriptor_handle(v.rays_rtv_heap, .RTV, 0)
    r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
    viewport := d3d12.VIEWPORT{Width = f32(v.rays), Height = f32(v.batch), MaxDepth = 1}
    scissor := d3d12.RECT{right = v.rays, bottom = i32(v.batch)}
    r.command_list->RSSetViewports(1, &viewport)
    r.command_list->RSSetScissorRects(1, &scissor)
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(v.ray_pipeline_state)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())
    renderer_bind_cbv(.Prefilter_Constants, renderer_dynamic_constants_address())
    renderer_bind_objects()
    renderer_bind_srv(.Texture_T1, r.shadow_srv_index)
    renderer_bind_srv(.Shadow_Atlas, r.shadow_atlas_srv_index)
    renderer_bind_buffer_srv(.Shadow_Tiles, renderer_shadow_tile_address())
    renderer_bind_srv(.Irradiance, r.irradiance_srv_index)
    renderer_bind_srv(.Prefiltered, r.prefilter_srv_index)
    renderer_bind_buffer_srv(.Lights, renderer_light_buffer_address())
    renderer_bind_buffer_srv(.Cluster_Lights, r.cluster_buffer->GetGPUVirtualAddress())
    renderer_bind_probes()
    renderer_bind_ray_tracing()
    r.command_list->DrawInstanced(3, 1, 0, 0)
    barrier = resource_transition(v.rays_texture, {.RENDER_TARGET}, {.NON_PIXEL_SHADER_RESOURCE})
    r.command_list->ResourceBarrier(1, &barrier)
    renderer_end_event()

    renderer_begin_event("Blend and relocate")
    renderer_dynamic_atlas_barriers({.PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS})
    renderer_bind_dynamic_compute()
    r.command_list->SetPipelineState(v.blend_irradiance_pipeline_state)
    r.command_list->Dispatch(u32(v.batch), 1, 1)
    r.command_list->SetPipelineState(v.blend_distance_pipeline_state)
    r.command_list->Dispatch(u32(v.batch), 1, 1)
    // The blends read each probe's update count, which relocation then
    // advances.
    uav_barrier := d3d12.RESOURCE_BARRIER{Type = .UAV}
    uav_barrier.UAV = {pResource = v.probe_data}
    r.command_list->ResourceBarrier(1, &uav_barrier)
    r.command_list->SetPipelineState(v.relocate_pipeline_state)
    r.command_list->Dispatch(u32((v.batch + 63) / 64), 1, 1)
    renderer_dynamic_atlas_barriers({.UNORDERED_ACCESS}, {.PIXEL_SHADER_RESOURCE})
    renderer_end_event()
}

// The compute passes' root signature and bindings.
renderer_bind_dynamic_compute :: proc() {
    r := &g_renderer
    v := &r.volumes
    r.command_list->SetComputeRootSignature(v.dynamic_root_signature)
    r.command_list->SetComputeRootConstantBufferView(u32(Dynamic_Root_Slot.Constants), renderer_dynamic_constants_address())
    r.command_list->SetComputeRootShaderResourceView(u32(Dynamic_Root_Slot.Volumes), renderer_volume_buffer_address())
    r.command_list->SetComputeRootDescriptorTable(u32(Dynamic_Root_Slot.Rays), renderer_srv_gpu(v.rays_srv_index))
    r.command_list->SetComputeRootDescriptorTable(u32(Dynamic_Root_Slot.Atlases), renderer_srv_gpu(v.dynamic_uav_start))
}

// The validity of the cell frame `slot` captured, once the GPU has finished
// it: an invalid cell is queued to be captured from its next offset.
renderer_read_volume_capture :: proc(slot: u32) {
    v := &g_renderer.volumes
    capture := v.captures[slot]
    v.captures[slot].active = false
    if !capture.active || capture.generation != v.generation[capture.slot] do return
    if int(capture.offset) + 1 >= len(VOLUME_CELL_OFFSETS) do return

    read_range := d3d12.RANGE{Begin = uint(slot) * 16, End = uint(slot) * 16 + 4}
    mapped: rawptr
    dx_check(v.readback->Map(0, &read_range, &mapped))
    validity := ([^]f32)(mapped)[slot * 4]
    written_range := d3d12.RANGE{}
    v.readback->Unmap(0, &written_range)

    if validity >= VOLUME_RETRY_VALIDITY do return
    v.cell_offset[capture.slot][capture.cell] = capture.offset + 1
    append(&v.retry[capture.slot], capture.cell)
}

renderer_volume_buffer_address :: proc() -> u64 {
    r := &g_renderer
    return r.volumes.buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * MAX_IRRADIANCE_VOLUMES * size_of(GpuIrradianceVolume)
}

// Whether this frame captures, for a reflection probe or a volume cell.
renderer_capturing :: proc() -> bool {
    return g_renderer.probes.capture_slot >= 0 || g_renderer.volumes.capture_slot >= 0
}

// Gives each probe in the scene a slot, picks this frame's capture (the
// first probe not captured yet, or moved since), and lists the captured
// ones for the lit pass. Probes beyond MAX_REFLECTION_PROBES are ignored.
renderer_update_probes :: proc(scene: ^Scene) {
    r := &g_renderer
    p := &r.probes
    is_probe :: proc(scene: ^Scene, index: int) -> bool {
        return index < scene.entity_count && scene.alive[index] && scene.has_transform[index] && scene.has_reflection_probe[index]
    }
    for &entity, slot in p.slot_entity {
        if entity >= 0 && !is_probe(scene, entity) {
            entity = -1
            p.captured[slot] = false
        }
    }

    p.count, p.scene_count = 0, 0
    p.capture_slot = -1
    gpu := p.mapped[int(r.frame_slot) * MAX_REFLECTION_PROBES:]
    for i in 0..<scene.entity_count {
        if !is_probe(scene, i) do continue
        p.scene_count += 1
        slot := renderer_probe_slot(i)
        if slot < 0 {
            for entity, s in p.slot_entity do if entity < 0 && slot < 0 do slot = s
            if slot < 0 do continue
            p.slot_entity[slot] = i
        }

        world := scene_world_matrix(scene, i)
        position := alg.Vector3f32{world[0, 3], world[1, 3], world[2, 3]}
        if p.captured[slot] && p.captured_position[slot] != position do p.captured[slot] = false
        if !p.enabled do continue
        if !p.captured[slot] {
            // Captured later this frame, so listed from the next one.
            if p.capture_slot < 0 {
                p.capture_slot = slot
                p.capture_position = position
                p.captured[slot] = true
                p.captured_position[slot] = position
            }
            continue
        }

        probe := scene.reflection_probes[i]
        gpu[p.count] = GpuProbe{
            world_to_box = alg.transpose(alg.matrix4_inverse_f32(world)),
            box_to_world = alg.transpose(world),
            size = {
                alg.length(alg.Vector3f32{world[0, 0], world[1, 0], world[2, 0]}),
                alg.length(alg.Vector3f32{world[0, 1], world[1, 1], world[2, 1]}),
                alg.length(alg.Vector3f32{world[0, 2], world[1, 2], world[2, 2]}),
            },
            blend_distance = probe.blend_distance,
            slot = u32(slot),
            box_projection = u32(probe.box_projection),
        }
        p.count += 1
    }
    renderer_update_volumes(scene)
}

// The slot of an entity's probe, or -1 if it has none (or not yet).
renderer_probe_slot :: proc(entity: int) -> int {
    for owner, slot in g_renderer.probes.slot_entity do if owner == entity do return slot
    return -1
}

renderer_probe_buffer_address :: proc() -> u64 {
    r := &g_renderer
    return r.probes.buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * MAX_REFLECTION_PROBES * size_of(GpuProbe)
}

renderer_bind_probes :: proc() {
    renderer_bind_buffer_srv(.Probes, renderer_probe_buffer_address())
    renderer_bind_srv(.Probe_Maps, g_renderer.probes.srv_index)
    renderer_bind_buffer_srv(.Volumes, renderer_volume_buffer_address())
    renderer_bind_srv(.Volume_Atlas, g_renderer.volumes.srv_index)
}

// The six capture faces' view-projections (cull frustums and constants).
renderer_probe_face_view_projections :: proc(far_clip: f32) -> [PROBE_FACES]alg.Matrix4f32 {
    return cube_face_view_projections(g_renderer.probes.capture_position, PROBE_NEAR, far_clip)
}

// The capture faces' frame constants: the frame's, seen from the probe,
// without screen-space effects. Their sky shows the environment as lighting
// uses it (IBL intensity, or the ambient color), not the visible background,
// since the probe stands in for that light.
renderer_write_probe_capture_constants :: proc(frame: FrameConstants, sky: SkyConstants, far_clip: f32) {
    r := &g_renderer
    p := &r.probes
    position := p.capture_position
    projection := perspective_lh(math.PI / 2, 1, PROBE_NEAR, far_clip)
    settings := r.environment_settings
    for face in 0..<PROBE_FACES {
        view := look_at_lh(position, position + CUBE_FACE_DIRECTIONS[face], CUBE_FACE_UPS[face])
        constants := frame
        constants.view = view
        constants.projection = projection
        constants.view_projection = view * projection
        constants.previous_view_projection = constants.view_projection
        constants.view_position = position
        constants.capture_view = 1
        constants.ao_enabled, constants.ao_show = 0, 0
        constants.ssr_enabled = 0
        constants.light_show_clusters = 0
        constants.shadow_show_cascades = 0
        constants.volume_show = 0
        p.frame_constants[int(r.frame_slot) * PROBE_FACES + face] = constants

        forward := CUBE_FACE_DIRECTIONS[face]
        right := alg.normalize(alg.cross(CUBE_FACE_UPS[face], forward))
        face_sky := sky
        face_sky.forward = forward
        face_sky.right = right
        face_sky.up = alg.cross(forward, right)
        face_sky.tan_half_fov = 1
        face_sky.aspect = 1
        if settings.ambient_mode == .HDRI {
            face_sky.background_mode = .HDRI
            face_sky.background_brightness = settings.intensity
        } else {
            face_sky.background_mode = .Solid
            face_sky.background_color = settings.ambient_color
            face_sky.background_brightness = settings.ambient_intensity
        }
        p.sky_constants[int(r.frame_slot) * PROBE_FACES + face] = face_sky
    }
}

// Captures this frame's probe, if any, then gives the capture its mips and
// prefilters it into the probe's slot. Runs after the shadow pass.
renderer_render_probe_capture :: proc(draws: []Draw, face_batches: [PROBE_FACES][]DrawBatch) {
    r := &g_renderer
    p := &r.probes
    v := &r.volumes
    renderer_begin_gpu_pass(.Probe_Capture)
    defer renderer_end_gpu_pass(.Probe_Capture)
    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    renderer_clear_volume_slots()
    if !renderer_capturing() do return
    volume_cell := v.capture_slot >= 0

    barrier := resource_transition(p.capture_texture, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET})
    r.command_list->ResourceBarrier(1, &barrier)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_set_square_viewport(PROBE_SIZE)

    // What the lit pass binds, except the screen-space effects (off here).
    renderer_bind_srv(.Texture_T1, r.shadow_srv_index)
    renderer_bind_srv(.Shadow_Atlas, r.shadow_atlas_srv_index)
    renderer_bind_buffer_srv(.Shadow_Tiles, renderer_shadow_tile_address())
    renderer_bind_srv(.Irradiance, r.irradiance_srv_index)
    renderer_bind_srv(.Prefiltered, r.prefilter_srv_index)
    renderer_bind_srv(.Texture_T8, renderer_ao_srv())
    renderer_bind_srv(.Reflections, r.ssr_srv_index)
    renderer_bind_buffer_srv(.Lights, renderer_light_buffer_address())
    renderer_bind_buffer_srv(.Cluster_Lights, r.cluster_buffer->GetGPUVirtualAddress())
    renderer_bind_probes()
    renderer_bind_ray_tracing()

    frame_constants := p.frame_constant_buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * PROBE_FACES * size_of(FrameConstants)
    sky_constants := p.sky_constant_buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * PROBE_FACES * size_of(SkyConstants)
    for face in 0..<u32(PROBE_FACES) {
        renderer_begin_event(CUBE_FACE_NAMES[face])
        defer renderer_end_event()
        rtv := descriptor_handle(p.rtv_heap, .RTV, face)
        dsv := descriptor_handle(p.dsv_heap, .DSV, face)
        r.command_list->ClearDepthStencilView(dsv, {.DEPTH}, 1, 0, 0, nil)

        // The sky first, as in the lit pass, then the opaque scene over it.
        r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
        r.command_list->SetPipelineState(r.sky_pipeline_state)
        renderer_bind_cbv(.Sky_Constants, sky_constants + u64(face) * size_of(SkyConstants))
        renderer_bind_srv(.Texture_T0, r.environment_srv_index)
        r.command_list->DrawInstanced(3, 1, 0, 0)

        r.command_list->OMSetRenderTargets(1, &rtv, false, &dsv)
        renderer_bind_cbv(.Frame_Constants, frame_constants + u64(face) * size_of(FrameConstants))
        renderer_draw_batches(draws, face_batches[face], v.capture_pipeline_states if volume_cell else p.capture_pipeline_states)
    }

    // Each capture level from the one above (2 x 2 texels each).
    renderer_begin_event("Capture mips")
    renderer_probe_level_barriers(0, {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE})
    r.command_list->SetPipelineState(p.downsample_pipeline_state)
    for level in 1..<PROBE_CAPTURE_MIP_COUNT {
        renderer_set_square_viewport(PROBE_SIZE >> u32(level))
        renderer_bind_srv(.Texture_T1, p.capture_level_srv_start + u32(level - 1))
        for face in 0..<PROBE_FACES {
            rtv := descriptor_handle(p.rtv_heap, .RTV, u32(level * PROBE_FACES + face))
            r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
            renderer_bind_cbv(.Prefilter_Constants, renderer_probe_pass_address(renderer_probe_downsample_pass(level, face)))
            r.command_list->DrawInstanced(3, 1, 0, 0)
        }
        renderer_probe_level_barriers(level, {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE})
    }
    renderer_end_event()

    if volume_cell {
        renderer_project_volume_cell()
        return
    }

    renderer_begin_event("Prefilter")
    barrier = resource_transition(p.array, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET})
    r.command_list->ResourceBarrier(1, &barrier)
    r.command_list->SetPipelineState(p.prefilter_pipeline_state)
    renderer_bind_srv(.Texture_T0, p.capture_srv_index)
    first_rtv := u32(PROBE_CAPTURE_MIP_COUNT * PROBE_FACES)
    for level in 0..<PROBE_MIP_COUNT {
        renderer_set_square_viewport(PROBE_SIZE >> u32(level))
        for face in 0..<PROBE_FACES {
            // Views are copied when bound, so these slots are rewritten each capture.
            rtv := descriptor_handle(p.rtv_heap, .RTV, first_rtv + u32(level * PROBE_FACES + face))
            renderer_write_face_rtv(p.array, u32(level), u32(p.capture_slot * PROBE_FACES + face), rtv)
            r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
            renderer_bind_cbv(.Prefilter_Constants, renderer_probe_pass_address(renderer_probe_prefilter_pass(level, face)))
            r.command_list->DrawInstanced(3, 1, 0, 0)
        }
    }
    barrier = resource_transition(p.array, {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE})
    r.command_list->ResourceBarrier(1, &barrier)
    renderer_end_event()
}

CUBE_FACE_NAMES := [6]string{"Face +X", "Face -X", "Face +Y", "Face -Y", "Face +Z", "Face -Z"}

renderer_probe_pass_address :: proc(pass: int) -> u64 {
    return g_renderer.probes.pass_constant_buffer->GetGPUVirtualAddress() + u64(pass) * size_of(PrefilterConstants)
}

// Transitions the six faces of one capture level.
renderer_probe_level_barriers :: proc(level: int, before, after: d3d12.RESOURCE_STATES) {
    barriers: [PROBE_FACES]d3d12.RESOURCE_BARRIER
    for &barrier, face in barriers {
        barrier = resource_transition(g_renderer.probes.capture_texture, before, after)
        barrier.Transition.Subresource = u32(level + face * PROBE_CAPTURE_MIP_COUNT)
    }
    g_renderer.command_list->ResourceBarrier(len(barriers), &barriers[0])
}

renderer_set_square_viewport :: proc(size: u32) {
    viewport := d3d12.VIEWPORT{Width = f32(size), Height = f32(size), MaxDepth = 1}
    scissor := d3d12.RECT{right = i32(size), bottom = i32(size)}
    g_renderer.command_list->RSSetViewports(1, &viewport)
    g_renderer.command_list->RSSetScissorRects(1, &scissor)
}

// The capture pipelines (the lit pass's shader with its own depth test and
// write, and the alpha test for cutouts, since there is no prepass), the
// downsample and the prefilter, from the mesh passes' and full-screen
// passes' base states.
renderer_create_probe_pipelines :: proc(mesh_desc, fullscreen: d3d12.GRAPHICS_PIPELINE_STATE_DESC) {
    r := &g_renderer
    p := &r.probes
    capture_masked_ps := renderer_compile_shader("shaders/scene.hlsl", "PSCaptureMasked", "ps")
    defer capture_masked_ps->Release()
    for variant in Draw_Variant {
        desc := mesh_desc
        if variant == .Double_Sided || variant == .Masked_Double_Sided do desc.RasterizerState.CullMode = .NONE
        if variant == .Masked || variant == .Masked_Double_Sided do desc.PS = shader_bytecode(capture_masked_ps)
        renderer_create_pso(&desc, &p.capture_pipeline_states[variant])
    }
    PREFILTER :: "shaders/environment_prefilter.hlsl"
    renderer_create_fullscreen_pso(fullscreen, PREFILTER, "PSProbeDownsample", PROBE_FORMAT, &p.downsample_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, PREFILTER, "PSProbePrefilter", PROBE_FORMAT, &p.prefilter_pipeline_state)

    // Volume cells: one-sided surfaces are drawn from behind too, writing
    // zero coverage (alpha) there; double-sided ones are seen from both sides
    // anyway and draw as for probes.
    capture_volume_ps := renderer_compile_shader("shaders/scene.hlsl", "PSCaptureVolume", "ps")
    defer capture_volume_ps->Release()
    capture_volume_masked_ps := renderer_compile_shader("shaders/scene.hlsl", "PSCaptureVolumeMasked", "ps")
    defer capture_volume_masked_ps->Release()
    for variant in Draw_Variant {
        desc := mesh_desc
        desc.RasterizerState.CullMode = .NONE
        switch variant {
            case .Opaque: desc.PS = shader_bytecode(capture_volume_ps)
            case .Masked: desc.PS = shader_bytecode(capture_volume_masked_ps)
            case .Double_Sided:
            case .Masked_Double_Sided: desc.PS = shader_bytecode(capture_masked_ps)
        }
        renderer_create_pso(&desc, &r.volumes.capture_pipeline_states[variant])
    }
}

// The volumes' compute root signature (made once) and the projection and
// clear pipelines; rebuilt by shader hot-reload.
renderer_create_volume_compute_pipelines :: proc() {
    r := &g_renderer
    v := &r.volumes
    if v.root_signature == nil {
        capture_range := d3d12.DESCRIPTOR_RANGE{RangeType = .SRV, NumDescriptors = 1}
        atlas_range := d3d12.DESCRIPTOR_RANGE{RangeType = .UAV, NumDescriptors = 1}
        params: [Volume_Root_Slot]d3d12.ROOT_PARAMETER
        params[.Constants].ParameterType = ._32BIT_CONSTANTS
        params[.Constants].Constants = {Num32BitValues = size_of(VolumePassConstants) / 4}
        params[.Capture].ParameterType = .DESCRIPTOR_TABLE
        params[.Capture].DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &capture_range}
        params[.Atlas].ParameterType = .DESCRIPTOR_TABLE
        params[.Atlas].DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &atlas_range}
        params[.Result].ParameterType = .UAV
        params[.Result].Descriptor = {ShaderRegister = 1}
        rs_desc := d3d12.ROOT_SIGNATURE_DESC{NumParameters = len(params), pParameters = &params[Volume_Root_Slot(0)]}
        v.root_signature = create_root_signature(&rs_desc, "Irradiance volumes")
    }
    entries := [2]cstring{"CSProjectCell", "CSClearSlot"}
    pipelines := [2]^^d3d12.IPipelineState{&v.project_pipeline_state, &v.clear_pipeline_state}
    for entry, i in entries {
        cs := renderer_compile_shader("shaders/irradiance_volume.hlsl", entry, "cs")
        defer cs->Release()
        if renderer_skip_pipeline() do continue
        desc := d3d12.COMPUTE_PIPELINE_STATE_DESC{pRootSignature = v.root_signature, CS = shader_bytecode(cs)}
        renderer_check_pipeline(r.device->CreateComputePipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(pipelines[i])))
    }

    // Dynamic volumes' passes (dynamic_volume.hlsl), on GPUs with DXR 1.1:
    // the update constants (b3), the volume list (t12), the rays (t0), the
    // three atlases (u0-u2), and a reset range (b1).
    if !r.ray_tracing.supported do return
    if v.dynamic_root_signature == nil {
        rays_range := d3d12.DESCRIPTOR_RANGE{RangeType = .SRV, NumDescriptors = 1}
        atlas_range := d3d12.DESCRIPTOR_RANGE{RangeType = .UAV, NumDescriptors = 3}
        params: [Dynamic_Root_Slot]d3d12.ROOT_PARAMETER
        params[.Constants].ParameterType = .CBV
        params[.Constants].Descriptor = {ShaderRegister = 3}
        params[.Volumes].ParameterType = .SRV
        params[.Volumes].Descriptor = {ShaderRegister = 12}
        params[.Rays].ParameterType = .DESCRIPTOR_TABLE
        params[.Rays].DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &rays_range}
        params[.Atlases].ParameterType = .DESCRIPTOR_TABLE
        params[.Atlases].DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &atlas_range}
        params[.Reset].ParameterType = ._32BIT_CONSTANTS
        params[.Reset].Constants = {ShaderRegister = 1, Num32BitValues = 2}
        rs_desc := d3d12.ROOT_SIGNATURE_DESC{NumParameters = len(params), pParameters = &params[Dynamic_Root_Slot(0)]}
        v.dynamic_root_signature = create_root_signature(&rs_desc, "Dynamic volumes")
    }
    dynamic_entries := [4]cstring{"CSBlendIrradiance", "CSBlendDistance", "CSRelocate", "CSResetProbes"}
    dynamic_pipelines := [4]^^d3d12.IPipelineState{
        &v.blend_irradiance_pipeline_state, &v.blend_distance_pipeline_state,
        &v.relocate_pipeline_state, &v.reset_pipeline_state,
    }
    for entry, i in dynamic_entries {
        cs := renderer_compile_shader("shaders/dynamic_volume.hlsl", entry, "cs")
        defer cs->Release()
        if renderer_skip_pipeline() do continue
        desc := d3d12.COMPUTE_PIPELINE_STATE_DESC{pRootSignature = v.dynamic_root_signature, CS = shader_bytecode(cs)}
        renderer_check_pipeline(r.device->CreateComputePipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(dynamic_pipelines[i])))
    }
}

renderer_volume_atlas_barrier :: proc(before, after: d3d12.RESOURCE_STATES) {
    barrier := resource_transition(g_renderer.volumes.atlas, before, after)
    g_renderer.command_list->ResourceBarrier(1, &barrier)
}

// Zeroes the blocks of slots whose cells changed, so their cells have no
// weight until captured. The SRV heap must be set.
renderer_clear_volume_slots :: proc() {
    r := &g_renderer
    v := &r.volumes
    pending := false
    for clear in v.clear_pending do pending ||= clear
    if !pending do return

    renderer_begin_event("Clear volumes")
    defer renderer_end_event()
    renderer_volume_atlas_barrier({.PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS})
    r.command_list->SetComputeRootSignature(v.root_signature)
    r.command_list->SetPipelineState(v.clear_pipeline_state)
    r.command_list->SetComputeRootDescriptorTable(u32(Volume_Root_Slot.Atlas), renderer_srv_gpu(v.uav_index))
    for &clear, slot in v.clear_pending {
        if !clear do continue
        clear = false
        constants := VolumePassConstants{first_z = u32(slot * IRRADIANCE_VOLUME_MAX_CELLS)}
        r.command_list->SetComputeRoot32BitConstants(u32(Volume_Root_Slot.Constants), size_of(constants) / 4, &constants, 0)
        // 4 x 4 x 4 threads per group (irradiance_volume.hlsl).
        r.command_list->Dispatch(VOLUME_ATLAS_WIDTH / 4, VOLUME_ATLAS_HEIGHT / 4, IRRADIANCE_VOLUME_MAX_CELLS / 4)
    }
    renderer_volume_atlas_barrier({.UNORDERED_ACCESS}, {.PIXEL_SHADER_RESOURCE})
}

// Reduces the capture (its mips made) to the cell's coefficients in the
// atlas.
renderer_project_volume_cell :: proc() {
    r := &g_renderer
    v := &r.volumes
    renderer_begin_event("Project to SH")
    defer renderer_end_event()

    barriers := [2]d3d12.RESOURCE_BARRIER{
        resource_transition(r.probes.capture_texture, {.PIXEL_SHADER_RESOURCE}, {.NON_PIXEL_SHADER_RESOURCE}),
        resource_transition(v.atlas, {.PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS}),
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
    r.command_list->SetComputeRootSignature(v.root_signature)
    r.command_list->SetPipelineState(v.project_pipeline_state)
    constants := VolumePassConstants{
        cell = {u32(v.capture_cell.x), u32(v.capture_cell.y), u32(v.capture_cell.z)},
        first_z = u32(v.capture_slot * IRRADIANCE_VOLUME_MAX_CELLS),
        offset = v.capture_offset,
    }
    r.command_list->SetComputeRoot32BitConstants(u32(Volume_Root_Slot.Constants), size_of(constants) / 4, &constants, 0)
    r.command_list->SetComputeRootDescriptorTable(u32(Volume_Root_Slot.Capture), renderer_srv_gpu(r.probes.capture_level_srv_start + VOLUME_SH_LEVEL))
    r.command_list->SetComputeRootDescriptorTable(u32(Volume_Root_Slot.Atlas), renderer_srv_gpu(v.uav_index))
    r.command_list->SetComputeRootUnorderedAccessView(u32(Volume_Root_Slot.Result), v.result->GetGPUVirtualAddress())
    r.command_list->Dispatch(1, 1, 1)
    barriers[0] = resource_transition(r.probes.capture_texture, {.NON_PIXEL_SHADER_RESOURCE}, {.PIXEL_SHADER_RESOURCE})
    barriers[1] = resource_transition(v.atlas, {.UNORDERED_ACCESS}, {.PIXEL_SHADER_RESOURCE})
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])

    // The validity, for renderer_read_volume_capture. The buffer was
    // promoted to a UAV from COMMON, and decays back after the frame.
    barrier := resource_transition(v.result, {.UNORDERED_ACCESS}, {.COPY_SOURCE})
    r.command_list->ResourceBarrier(1, &barrier)
    r.command_list->CopyBufferRegion(v.readback, u64(r.frame_slot) * 16, v.result, 0, 16)
}
