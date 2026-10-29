package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import win32 "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"
import "core:math"
import alg "core:math/linalg"

import "core:image"
import "core:image/png"

FRAME_COUNT :: 2

SHADOW_MAP_SIZE :: 2048
SRV_HEAP_CAPACITY :: 65536 // Includes FRAME_COUNT * MAX_DRAWS material tables.

// Bloom mip chain levels: half resolution down to 1/64 (about 30x17 at 1080p).
BLOOM_MIP_COUNT :: 6
BLOOM_PASS_COUNT :: 3 // Prefilter, downsample, upsample.

IRRADIANCE_WIDTH :: 64
IRRADIANCE_HEIGHT :: 32

PREFILTER_WIDTH :: 1024
PREFILTER_HEIGHT :: 512
PREFILTER_MIP_COUNT :: 5

GPU_PASS_COUNT :: len(GPU_Pass)
GPU_TIMESTAMP_COUNT :: GPU_PASS_COUNT * 2

GPU_Pass :: enum u32{
    Shadow,
    Scene,
    Bloom_Prefilter,
    Bloom_Downsample,
    Bloom_Upsample,
    Post_Process,
    Depth_Prepass,
    SSAO,
    FXAA,
    TAA,
    Auto_Exposure,
    SSR,
    Light_Clusters,
    Fog,
}

Vertex :: struct {
    position:   [3]f32,
    normal:     [3]f32,
    texcoord:   [2]f32,
    tangent:   [4]f32,
}

// A point or spot light as the shader sees it (scene.hlsl's GpuLight).
GpuLight :: struct {
    position: [3]f32,
    range: f32,
    // Color times intensity.
    radiance: [3]f32,
    // Cone fade: saturate(cos(angle to the axis) * spot_scale + spot_offset),
    // squared. A point light has scale 0 and offset 1: no cone.
    spot_offset: f32,
    direction: [3]f32, // The cone's axis; unused for point lights.
    spot_scale: f32,
    // Shadow slot: for a spot light, its spot_shadow_view_projection and
    // spot shadow map slice; for a point light, its cube in the point shadow
    // map. -1 for none.
    shadow_index: i32,
    // World size of one shadow-map texel per unit of distance along the axis.
    shadow_texel_scale: f32,
    // Point lights: the cube faces' near plane (the far plane is the range).
    shadow_near: f32,
    _pad: f32,
}

GpuMesh :: struct {
    vertex_buffer: ^d3d12.IResource,
    vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW,

    index_buffer: ^d3d12.IResource,
    index_buffer_view: d3d12.INDEX_BUFFER_VIEW,
    index_count: u32,

}

GpuTexture :: struct {resource: ^d3d12.IResource, srv_index: u32}

renderer_alloc_srv :: proc(count: u32 = 1) -> u32 {
    r := &g_renderer
    assert(r.srv_next + count <= SRV_HEAP_CAPACITY, "SRV heap capacity exceeded")
    result := r.srv_next
    r.srv_next += count
    return result
}

// Copies a draw's material textures (albedo, normal, roughness, metallic,
// emissive, occlusion) into its slot of this frame's material ring and
// returns the table to bind.
// The slot is free: begin_frame waited for the frame that last used it.
renderer_material_table :: proc(
    draw_index: int,
    textures: [MATERIAL_TEXTURE_COUNT]TextureHandle,
) -> d3d12.GPU_DESCRIPTOR_HANDLE {
    r := &g_renderer
    assert(draw_index >= 0 && draw_index < MAX_DRAWS)
    first := r.material_srv_start +
             u32((int(r.frame_slot) * MAX_DRAWS + draw_index) * MATERIAL_TEXTURE_COUNT)

    destination, source: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&destination)
    r.srv_staging_heap->GetCPUDescriptorHandleForHeapStart(&source)
    for texture, i in textures {
        assert(assets_texture_valid(texture))
        to := destination
        to.ptr += uint(first + u32(i)) * uint(r.srv_descriptor_size)
        from := source
        from.ptr += uint(r.textures[texture].srv_index) * uint(r.srv_descriptor_size)
        r.device->CopyDescriptorsSimple(1, to, from, .CBV_SRV_UAV)
    }
    return renderer_srv_gpu(first)
}

// Written once per frame and shared by every draw (b4).
FrameConstants :: struct #align(256) {
    view: alg.Matrix4f32,
    // Includes the TAA sub-pixel jitter when TAA is on.
    projection: alg.Matrix4f32,
    // Unjittered, this frame and last: motion vectors exclude the jitter.
    view_projection: alg.Matrix4f32,
    previous_view_projection: alg.Matrix4f32,
    cascade_view_projection: [SHADOW_CASCADE_COUNT]alg.Matrix4f32,

    view_position: [3]f32,
    // Point and spot lights in the light buffer (those in view).
    light_count: u32,

    sun_direction: [3]f32,
    sun_intensity: f32,

    sun_color: [3]f32,
    environment_intensity: f32,

    environment_sin, environment_cos: f32,
    ambient_intensity: f32,
    ambient_mode: AmbientLightingMode,

    ambient_color: [3]f32,
    // Shadow bias in shadow-map texels; each cascade scales it by its texel depth.
    shadow_bias_constant: f32,

    shadow_bias_slope: f32,
    // Distance from the camera over which sun shadows fade out.
    shadow_fade_start: f32,
    shadow_fade_end: f32,
    // Nonzero tints receivers by cascade, for inspecting the splits.
    shadow_show_cascades: u32,

    // Per cascade: view depth where it ends, world size of a texel, and the
    // shadow-map depth change across one texel facing the sun.
    cascade_split_depth: [SHADOW_CASCADE_COUNT]f32,
    cascade_texel_world: [SHADOW_CASCADE_COUNT]f32,
    cascade_texel_depth: [SHADOW_CASCADE_COUNT]f32,

    // Screen-space ambient occlusion: world-space sample radius, the exponent
    // applied to the result, and whether ambient light uses it.
    ao_radius: f32,
    ao_intensity: f32,
    ao_enabled: u32,
    // Nonzero shows the occlusion buffer instead of lighting.
    ao_show: u32,

    // Screen-space reflections (renderer_ssr.odin): view-space ray length and
    // surface thickness, and the roughness above which there are none.
    ssr_max_distance: f32,
    ssr_thickness: f32,
    ssr_max_roughness: f32,
    ssr_enabled: u32,
    // Nonzero (with TAA) spreads rays over the specular lobe, varying by frame.
    ssr_stochastic: u32,
    ssr_frame: u32,
    _ssr_pad: [2]f32,

    // Clustered lighting (renderer_lights.odin): the depth slice of view
    // depth z is log2(z) * cluster_depth_scale + cluster_depth_bias.
    cluster_screen_size: [2]f32,
    cluster_depth_scale: f32,
    cluster_depth_bias: f32,
    // Nonzero shows each pixel's cluster light count instead of lighting.
    light_show_clusters: u32,
    _cluster_pad: [3]f32,

    // Volumetric fog (renderer_fog.odin). Density is extinction per unit at
    // or below fog_height, falling off exponentially above it.
    fog_albedo: [3]f32,
    fog_density: f32,
    // Radiance reaching the fog evenly from every direction.
    fog_ambient: [3]f32,
    fog_height: f32,
    fog_height_falloff: f32,
    // Henyey-Greenstein g.
    fog_anisotropy: f32,
    fog_max_distance: f32,
    fog_history_valid: u32,
    fog_frame: u32,
    _fog_pad: [3]f32,

    // View-projection of each spot shadow slot (GpuLight.shadow_index).
    spot_shadow_view_projection: [SPOT_SHADOW_COUNT]alg.Matrix4f32,
    // Each point shadow slot's six cube faces.
    point_shadow_face_view_projection: [POINT_SHADOW_COUNT * POINT_SHADOW_FACES]alg.Matrix4f32,
}

#assert(SHADOW_CASCADE_COUNT == 4) // Packed as float4 rows in scene.hlsl.
#assert(size_of(FrameConstants) == 2816)

// Written per draw (b0).
ObjectConstants :: struct #align(256) {
    model: alg.Matrix4f32,
    // Inverse model matrix; its upper 3x3 transforms normals under
    // non-uniform scale when used with the shader's row-vector convention.
    normal_matrix: alg.Matrix4f32,
    // Last frame's model matrix (transposed like `model`), for motion vectors.
    previous_model: alg.Matrix4f32,

    material_tint: [3]f32,
    uv_scale: f32,

    roughness: f32,
    metallic: f32,
    normal_strength: f32,
    unlit: u32,

    use_roughness_map: u32,
    use_metallic_map: u32,
    use_occlusion_map: u32,
    occlusion_strength: f32,

    // Emission color times strength; the shader multiplies in the map.
    emissive: [3]f32,
    // Albedo alpha below this is cut out by the cutout pipelines: alpha-mask
    // materials, and blended ones in the shadow pass.
    alpha_cutoff: f32,

    // Blended materials: albedo alpha is multiplied by this.
    opacity: f32,
}

// Constant-buffer views start on 256-byte boundaries.
#assert(size_of(ObjectConstants) == 512)

// Missing from older scene files, which therefore keep Reinhard.
ToneMapper :: enum u32 {Reinhard, ACES, AgX}

// The first value is what files saved before this setting existed load as.
AntiAliasing :: enum u32 {FXAA, None, TAA}

PostConstants :: struct #align(256) {
    exposure: f32,
    bloom_threshold: f32,
    bloom_strength: f32,
    tone_mapper: ToneMapper,
    // One pixel in UV units, for FXAA's and TAA's neighbour lookups.
    texel_size: [2]f32,
    // Zero when the TAA history holds nothing usable (first frame, resize).
    taa_history_valid: u32,
    // Share of the new frame in each TAA blend.
    taa_blend: f32,
    // Nonzero: exposure multiplies the automatic exposure (auto_exposure.hlsl).
    auto_exposure: u32,
    // Contrast-adaptive sharpening after TAA, 0-1.
    sharpness: f32,
    _pad0: [2]f32,
    // Takes a sky pixel's clip position (on the far plane) to last frame's:
    // the inverse of this frame's rotation-only, unjittered view-projection
    // times last frame's. TAA uses it where nothing was drawn.
    sky_reprojection: alg.Matrix4f32,
}

SkyConstants :: struct #align(256) {
    forward: [3]f32,
    tan_half_fov: f32,

    right: [3]f32,
    aspect: f32,

    up: [3]f32,
    background_brightness: f32,
    environment_sin, environment_cos: f32,
    _pad1: [2]f32,
    background_color: [3]f32,
    background_mode: BackgroundMode,
}

#assert(size_of(SkyConstants) == 256)

PrefilterConstants :: struct #align(256) {
    roughness: f32,
    _pad0: [3]f32,
}

Renderer :: struct {
    device: ^d3d12.IDevice,
    info_queue: ^d3d12.IInfoQueue, // Debug builds only.
    swap_chain: ^dxgi.ISwapChain3,
    command_queue: ^d3d12.ICommandQueue,

    width: u32,
    height: u32,

    rtv_heap: ^d3d12.IDescriptorHeap,
    rtv_descriptor_size: u32,
    render_targets: [FRAME_COUNT]^d3d12.IResource,

    command_allocators: [FRAME_COUNT]^d3d12.ICommandAllocator,
    command_list: ^d3d12.IGraphicsCommandList,

    fence: ^d3d12.IFence,
    fence_value: u64,
    fence_event: win32.HANDLE,

    root_signature: ^d3d12.IRootSignature,

    viewport: d3d12.VIEWPORT,
    scissor_rect: d3d12.RECT,

    object_constant_buffer: ^d3d12.IResource,
    object_cb_mapped_data: [^]ObjectConstants,

    frame_constant_buffer: ^d3d12.IResource,
    frame_cb_mapped_data: [^]FrameConstants,

    depth_buffer: ^d3d12.IResource,
    dsv_heap: ^d3d12.IDescriptorHeap,

    meshes: []GpuMesh,

    textures: []GpuTexture,
    srv_heap: ^d3d12.IDescriptorHeap,
    srv_staging_heap: ^d3d12.IDescriptorHeap,
    // Ring of per-draw material tables, one region per frame in flight.
    material_srv_start: u32,
    srv_descriptor_size: u32,
    srv_next: u32,
    shadow_srv_index, hdr_srv_index, bloom_srv_start: u32,
    environment_srv_index, irradiance_srv_index, prefilter_srv_index: u32,
    // Temporary sun-free panorama used only while baking the IBL maps.
    environment_bake_srv_index: u32,

    shadow_map: ^d3d12.IResource,
    shadow_dsv_heap: ^d3d12.IDescriptorHeap,
    // Spot light shadows (renderer_shadow.odin): one slice per slot, the
    // entity each slot went to this frame (-1: unused), and pipelines with a
    // slope-scaled depth bias.
    spot_shadow_map: ^d3d12.IResource,
    spot_shadow_dsv_heap: ^d3d12.IDescriptorHeap,
    spot_shadow_srv_index: u32,
    spot_shadow_entities: [SPOT_SHADOW_COUNT]int,
    spot_shadow_pipeline_states: [Draw_Variant]^d3d12.IPipelineState,
    // Point light shadows: six slices (cube faces) per slot. They use the
    // spot pipelines (same bias).
    point_shadow_map: ^d3d12.IResource,
    point_shadow_dsv_heap: ^d3d12.IDescriptorHeap,
    point_shadow_srv_index: u32,
    point_shadow_entities: [POINT_SHADOW_COUNT]int,
    shadow_pipeline_states: [Draw_Variant]^d3d12.IPipelineState,

    hdr_texture: ^d3d12.IResource,
    hdr_rtv_heap: ^d3d12.IDescriptorHeap,

    hdr_pipeline_states: [Draw_Variant]^d3d12.IPipelineState,
    // Blended surfaces: front faces, and back faces of double-sided ones.
    transparent_front_pipeline_state, transparent_back_pipeline_state: ^d3d12.IPipelineState,
    post_pipeline_state: ^d3d12.IPipelineState,

    // One texture with the whole chain (renderer_post.odin); per-level RTVs
    // and single-level SRVs. Small windows get fewer levels.
    bloom_texture: ^d3d12.IResource,
    bloom_mip_count: u32,
    bloom_rtv_heap: ^d3d12.IDescriptorHeap,

    // Prefilter, downsample, upsample.
    bloom_pipeline_states: [BLOOM_PASS_COUNT]^d3d12.IPipelineState,

    post_constant_buffer: ^d3d12.IResource,
    post_cb_mapped_data: [^]PostConstants,

    post_exposure: f32,
    post_threshold: f32,
    post_strength: f32,
    post_tone_mapper: ToneMapper,
    post_anti_aliasing: AntiAliasing,

    // Auto-exposure (renderer_post.odin, auto_exposure.hlsl). With it on,
    // post_exposure is unused and the compensation scales the result.
    auto_exposure: AutoExposureSettings,
    // Jump to the measured exposure next frame instead of adapting.
    auto_exposure_reset: bool,
    // The automatic exposure in EV, read back a few frames late (display only).
    auto_exposure_ev: f32,
    auto_exposure_tick: time.Tick,
    exposure_root_signature: ^d3d12.IRootSignature,
    exposure_histogram_pipeline, exposure_adapt_pipeline: ^d3d12.IPipelineState,
    // Histogram bins (kept zeroed between frames), the exposure itself, and
    // per-frame-slot copies of it for the CPU.
    exposure_histogram, exposure_buffer, exposure_readback: ^d3d12.IResource,

    // Tone-mapped (display-encoded) frame that FXAA reads.
    ldr_texture: ^d3d12.IResource,
    ldr_rtv_heap: ^d3d12.IDescriptorHeap,
    ldr_srv_index: u32,
    fxaa_pipeline_state: ^d3d12.IPipelineState,
    // Contrast-adaptive sharpening after TAA; like FXAA, it reads the
    // tone-mapped image and writes the back buffer.
    sharpen_pipeline_state: ^d3d12.IPipelineState,

    // TAA: two HDR histories used in turn (one read, one written), and the
    // per-pixel motion written by the depth prepass.
    taa_history: [2]^d3d12.IResource,
    taa_rtv_heap: ^d3d12.IDescriptorHeap,
    taa_srv_start: u32,
    taa_write_index: int,
    taa_history_valid: bool,
    taa_resolve_pipeline_state: ^d3d12.IPipelineState,
    velocity_texture: ^d3d12.IResource,
    velocity_rtv_heap: ^d3d12.IDescriptorHeap,
    velocity_srv_index: u32,
    // The HDR image bloom and tone mapping read: the scene, or TAA's output.
    scene_color_srv_index: u32,
    scene_color: ^d3d12.IResource,

    // Last frame's unjittered camera and model matrices, for motion vectors.
    // A model is only reused if it was recorded on the previous frame.
    frame_counter: u64,
    previous_view_projection: alg.Matrix4f32,
    // Last frame's rotation-only view-projection, for sky motion.
    previous_sky_view_projection: alg.Matrix4f32,
    // Strength of the sharpening pass after TAA (0: off).
    post_sharpness: f32,
    // This frame's submesh draws (rebuilt by renderer_prepare_frame).
    frame_draws: FrameDraws,

    previous_models: [MAX_ENTITIES]alg.Matrix4f32,
    previous_model_frame: [MAX_ENTITIES]u64,

    // Shadow depth bias in shadow-map texels: constant, and scaled by the
    // receiver's slope towards the sun.
    shadow_bias_constant: f32,
    shadow_bias_slope: f32,
    // Camera distance covered by the sun's shadow cascades.
    shadow_distance: f32,
    shadow_show_cascades: bool,

    ao_enabled: bool,
    ao_show: bool,
    ao_radius: f32,
    ao_intensity: f32,
    // Raw (noisy) and blurred occlusion, plus their RTVs.
    ao_targets: [AO_TARGET_COUNT]^d3d12.IResource,
    ao_rtv_heap: ^d3d12.IDescriptorHeap,
    ao_srv_start, depth_srv_index: u32,
    depth_prepass_pipeline_states: [Draw_Variant]^d3d12.IPipelineState,
    ssao_pipeline_state: ^d3d12.IPipelineState,
    ssao_blur_pipeline_state: ^d3d12.IPipelineState,

    // Screen-space reflections (renderer_ssr.odin).
    ssr_enabled: bool,
    ssr_show: bool,
    ssr_max_distance: f32,
    ssr_thickness: f32,
    ssr_max_roughness: f32,
    // The prepass's view-space normal and roughness, and the traced
    // reflections (color, confidence), with their two RTVs.
    surface_texture, ssr_texture: ^d3d12.IResource,
    ssr_rtv_heap: ^d3d12.IDescriptorHeap,
    surface_srv_index, ssr_srv_index: u32,
    ssr_pipeline_state: ^d3d12.IPipelineState,
    // Last frame's scene color holds an image of this size to reflect.
    ssr_history_valid: bool,

    // Clustered lighting (renderer_lights.odin): per-frame-slot light buffers
    // (mapped), each cluster's light list, and the pass that builds them.
    light_buffer: ^d3d12.IResource,
    light_mapped_data: [^]GpuLight,
    cluster_buffer: ^d3d12.IResource,
    cluster_root_signature: ^d3d12.IRootSignature,
    cluster_pipeline_state: ^d3d12.IPipelineState,
    light_show_clusters: bool,
    // Point and spot lights in view this frame, and in the scene (display only).
    visible_light_count, scene_light_count: int,

    // Volumetric fog (renderer_fog.odin): the settings, the cell volumes (two
    // written in turn, then the integrated one) with their SRVs and UAVs, and
    // whether the volume last written can serve as history at this distance.
    fog: FogSettings,
    fog_volumes: [FOG_VOLUME_COUNT]^d3d12.IResource,
    fog_srv_start, fog_uav_start: u32,
    fog_root_signature: ^d3d12.IRootSignature,
    fog_inject_pipeline_state, fog_integrate_pipeline_state, fog_apply_pipeline_state: ^d3d12.IPipelineState,
    fog_write_index: int,
    fog_history_ready: bool,
    fog_history_distance: f32,

    // Material texture mips are rendered on the GPU (texture_mips.odin), with
    // scratch views for building one texture at a time.
    mip_pipeline: ^d3d12.IPipelineState,
    mip_rtv_heap: ^d3d12.IDescriptorHeap,
    mip_srv_start: u32,

    timestamp_heap: ^d3d12.IQueryHeap,
    timestamp_readback: ^d3d12.IResource,
    timestamp_frequency: u64,

    gpu_pass_ms: [GPU_PASS_COUNT]f32,
    fps: f32,
    frame_ms: f32,

    frustum_culling_enabled: bool,
    culling_stats: CullingStats,

    environment_texture: ^d3d12.IResource,
    environment_settings: EnvironmentSettings,
    environment_pending: Maybe(EnvironmentSettings),
    environment_status: string,
    environment_loaded_asset, environment_filtered_asset: EnvironmentHandle,
    // Whether the IBL maps were baked with the panorama's sun removed.
    environment_filtered_without_sun: bool,
    // The sun measured in the most recently decoded panorama.
    environment_sun: HdriSun,
    // Average radiance over the sphere of the panorama the IBL maps were baked
    // from (without its sun when that was extracted); lights the fog.
    environment_average_radiance: [3]f32,
    environment_sun_asset: EnvironmentHandle,
    sky_pipeline_state: ^d3d12.IPipelineState,

    sky_constant_buffer: ^d3d12.IResource,
    sky_cb_mapped_data: [^]SkyConstants,

    irradiance_texture: ^d3d12.IResource,
    irradiance_rtv_heap: ^d3d12.IDescriptorHeap,
    irradiance_pipeline_state: ^d3d12.IPipelineState,

    prefilter_texture: ^d3d12.IResource,
    prefilter_rtv_heap: ^d3d12.IDescriptorHeap,
    prefilter_pipeline_state: ^d3d12.IPipelineState,

    prefilter_constant_buffer: ^d3d12.IResource,
    prefilter_cb_mapped_data: [^]PrefilterConstants,

    selection_root_signature: ^d3d12.IRootSignature,
    selection_pipeline_state: ^d3d12.IPipelineState,

    // Shader hot-reload. Stamps sum the write times of shaders/*.hlsl: as
    // loaded, as last polled, and for the IBL bake shaders as last baked.
    shader_stamp, shader_polled_stamp, environment_shader_stamp: u64,
    shader_poll_time: time.Time,
    // Why the last reload was rejected ("" when it succeeded).
    shader_error: string,
    shader_reload_count: int,
    shader_reload_ms: f32,
    // Used only inside renderer_build_pipelines: shaders by
    // "path|entry|target", whether the creation code is only being run to
    // list them, and the first error.
    shader_blobs: map[string]^d3d12.IBlob,
    shader_collecting: bool,
    shader_build_error: string,

    frame_index: u32,
    frame_slot: u32,
    frame_fence_values: [FRAME_COUNT]u64,
}

g_renderer: Renderer

// Debug builds only: prints new D3D12 debug-layer messages to stderr, at most
// a few per message ID so a per-frame problem does not flood the console.
DEBUG_MESSAGE_REPEAT_LIMIT :: 5
g_debug_message_counts: map[d3d12.MESSAGE_ID]int

renderer_print_debug_messages :: proc() {
    when ODIN_DEBUG {
        q := g_renderer.info_queue
        if q == nil do return
        count := q->GetNumStoredMessages()
        for i in 0..<count {
            size: d3d12.SIZE_T
            if q->GetMessageA(i, nil, &size) < 0 do continue
            buffer := make([]u8, int(size), context.temp_allocator)
            message := (^d3d12.MESSAGE)(raw_data(buffer))
            if q->GetMessageA(i, message, &size) < 0 do continue

            seen := g_debug_message_counts[message.ID]
            g_debug_message_counts[message.ID] = seen + 1
            if seen < DEBUG_MESSAGE_REPEAT_LIMIT {
                // IDs as numbers: Odin's enum lacks many of the debug layer's IDs.
                fmt.eprintf("D3D12 %v [%d]: %s\n", message.Severity, i32(message.ID), message.pDescription)
            } else if seen == DEBUG_MESSAGE_REPEAT_LIMIT {
                fmt.eprintf("D3D12 [%d]: further repeats hidden\n", i32(message.ID))
            }
        }
        q->ClearStoredMessages()
    }
}

dx_check:: proc(hr: win32.HRESULT, loc := #caller_location){
    if hr < 0{
        fmt.panicf("DX12 error 0x%X at %v", u32(hr), loc)
    }
}

// Every pipeline's shaders come through here, already compiled by
// renderer_build_pipelines. While it is only listing them, this records the
// request and returns a placeholder the caller releases as usual.
renderer_compile_shader :: proc(path: string, entry, target: cstring) -> ^d3d12.IBlob {
    r := &g_renderer
    key := fmt.tprintf("%s|%s|%s", path, entry, target)
    blob: ^d3d12.IBlob
    if r.shader_collecting {
        if key not_in r.shader_blobs do r.shader_blobs[strings.clone(key)] = nil
        dx_check(d3dc.CreateBlob(4, &blob))
        return blob
    }
    blob = r.shader_blobs[key]
    assert(blob != nil, "shader was not compiled by renderer_build_pipelines")
    blob->AddRef()
    return blob
}

// Compiles every requested shader on its own thread and returns the first
// error. Debug builds keep symbols and skip optimization so tools like PIX can
// step through them.
renderer_compile_shader_set :: proc() -> (error: string) {
    r := &g_renderer
    Job :: struct {
        key: string,
        blob, errors: ^d3d12.IBlob,
        hr: win32.HRESULT,
    }
    compile :: proc(job: ^Job) {
        parts := strings.split(job.key, "|", context.temp_allocator)
        flags: u32 = 0
        when ODIN_DEBUG {
            flags = u32(d3dc.D3DCOMPILE_FLAG.DEBUG | d3dc.D3DCOMPILE_FLAG.SKIP_OPTIMIZATION)
        }
        job.hr = d3dc.CompileFromFile(
            win32.utf8_to_wstring(parts[0]), nil, nil,
            strings.clone_to_cstring(parts[1], context.temp_allocator),
            strings.clone_to_cstring(parts[2], context.temp_allocator),
            flags, 0, &job.blob, &job.errors,
        )
    }

    jobs := make([dynamic]Job, 0, len(r.shader_blobs), context.temp_allocator)
    for key in r.shader_blobs do append(&jobs, Job{key = key})
    // Sorted, so the error reported is the same every time.
    slice.sort_by(jobs[:], proc(a, b: Job) -> bool { return a.key < b.key })
    threads := make([]^thread.Thread, len(jobs), context.temp_allocator)
    for &job, i in jobs do threads[i] = thread.create_and_start_with_poly_data(&job, compile)
    thread.join_multiple(..threads)
    for t in threads do thread.destroy(t)

    // An error in a shared file fails every entry point in it alike: print
    // each distinct message once.
    // Messages name files by absolute path; shown relative to the working
    // directory, they fit the panel.
    directory, _ := os.get_working_directory(context.temp_allocator)
    directory_prefix := strings.concatenate({directory, "\\"}, context.temp_allocator)
    printed := make(map[string]bool, context.temp_allocator)
    for job in jobs {
        r.shader_blobs[job.key] = job.blob
        message: string
        if job.errors != nil {
            message = strings.trim_space(string(cstring(job.errors->GetBufferPointer())))
            message, _ = strings.replace_all(message, directory_prefix, "", context.temp_allocator)
            if message not_in printed {
                printed[strings.clone(message, context.temp_allocator)] = true
                fmt.println(job.key, "compiler messages:", message)
            }
        }
        if job.hr < 0 && error == "" {
            error = strings.clone(message) if message != "" else fmt.aprintf("%s failed to compile (0x%X).", job.key, u32(job.hr))
        }
        if job.errors != nil do job.errors->Release()
    }
    return
}

// Records a pipeline creation failure (for example a shader using a register
// the root signature lacks) for renderer_build_pipelines to report.
renderer_check_pipeline :: proc(hr: win32.HRESULT) {
    r := &g_renderer
    if hr >= 0 || r.shader_build_error != "" do return
    r.shader_build_error = fmt.aprintf("Pipeline creation failed (0x%X); the debug layer output says why.", u32(hr))
}

// True while pipelines should not be created: the shaders are only being
// listed, or the build has already failed.
renderer_skip_pipeline :: proc() -> bool {
    return g_renderer.shader_collecting || g_renderer.shader_build_error != ""
}

// Creates every pipeline in renderer_pipeline_slots. The creation code runs
// twice: first only to list the shaders it needs, which are then compiled in
// parallel, then for real. Returns the first error ("" on success); pipelines
// created before a failure are left in their slots.
renderer_build_pipelines :: proc() -> (error: string) {
    r := &g_renderer
    create :: proc() {
        renderer_create_pipelines()
        renderer_create_selection_pso()
        renderer_create_exposure_pipelines()
        renderer_create_light_cluster_pipeline()
        renderer_create_fog_pipelines()
    }
    r.shader_collecting = true
    create()
    r.shader_collecting = false

    r.shader_build_error = renderer_compile_shader_set()
    if r.shader_build_error == "" do create()
    error = r.shader_build_error
    r.shader_build_error = ""

    for key, blob in r.shader_blobs {
        if blob != nil do blob->Release()
        delete(key)
    }
    clear(&r.shader_blobs)
    return
}

// Every pipeline state built from shaders/, for hot-reload and shutdown.
renderer_pipeline_slots :: proc() -> []^^d3d12.IPipelineState {
    r := &g_renderer
    slots := make([dynamic]^^d3d12.IPipelineState, context.temp_allocator)
    for variant in Draw_Variant {
        append(&slots,
            &r.shadow_pipeline_states[variant], &r.spot_shadow_pipeline_states[variant],
            &r.depth_prepass_pipeline_states[variant], &r.hdr_pipeline_states[variant],
        )
    }
    for &pso in r.bloom_pipeline_states do append(&slots, &pso)
    append(&slots,
        &r.transparent_front_pipeline_state, &r.transparent_back_pipeline_state,
        &r.post_pipeline_state, &r.fxaa_pipeline_state, &r.sharpen_pipeline_state,
        &r.taa_resolve_pipeline_state, &r.sky_pipeline_state,
        &r.irradiance_pipeline_state, &r.prefilter_pipeline_state,
        &r.ssao_pipeline_state, &r.ssao_blur_pipeline_state, &r.ssr_pipeline_state, &r.mip_pipeline,
        &r.cluster_pipeline_state,
        &r.fog_inject_pipeline_state, &r.fog_integrate_pipeline_state, &r.fog_apply_pipeline_state,
        &r.selection_pipeline_state,
        &r.exposure_histogram_pipeline, &r.exposure_adapt_pipeline,
    )
    return slots[:]
}

// Rebuilds every pipeline from shaders/ and swaps the new set in only if all
// of it built; otherwise the old pipelines stay and shader_error says why.
renderer_reload_shaders :: proc() {
    r := &g_renderer
    start := time.tick_now()
    // Earlier frames may still be using the old pipelines.
    renderer_wait_for_gpu()

    slots := renderer_pipeline_slots()
    old := make([]^d3d12.IPipelineState, len(slots), context.temp_allocator)
    for slot, i in slots {
        old[i] = slot^
        slot^ = nil
    }
    delete(r.shader_error)
    r.shader_error = renderer_build_pipelines()

    failed := r.shader_error != ""
    for slot, i in slots {
        stale := slot^ if failed else old[i]
        if stale != nil do stale->Release()
        if failed do slot^ = old[i]
    }
    r.shader_reload_count += 1
    r.shader_reload_ms = f32(time.duration_milliseconds(time.tick_since(start)))
    if failed {
        fmt.println("Shader reload failed; keeping the previous shaders.")
    } else {
        fmt.printf("Shaders reloaded in %.0f ms.\n", r.shader_reload_ms)
    }
}

SHADER_POLL_INTERVAL :: 250 * time.Millisecond

// Sums the write times of shaders/*.hlsl, so editing, adding, or removing a
// file changes it. `environment` covers only the IBL bake shaders.
renderer_shader_stamp :: proc() -> (all, environment: u64) {
    data: win32.WIN32_FIND_DATAW
    find := win32.FindFirstFileW(win32.L("shaders\\*.hlsl"), &data)
    if find == win32.INVALID_HANDLE_VALUE do return
    defer win32.FindClose(find)
    for {
        stamp := u64(data.ftLastWriteTime.dwHighDateTime) << 32 | u64(data.ftLastWriteTime.dwLowDateTime)
        all += stamp
        name_buffer: [win32.MAX_PATH * 3]u8
        name := win32.wstring_to_utf8(name_buffer[:], win32.wstring(raw_data(data.cFileName[:])))
        if strings.equal_fold(name, "irradiance.hlsl") || strings.equal_fold(name, "environment_prefilter.hlsl") {
            environment += stamp
        }
        if !win32.FindNextFileW(find, &data) do break
    }
    return
}

// Called once a frame: reloads shaders after an edit has settled (the stamp
// held for one poll, so a save in progress is not compiled half-written), and
// re-bakes the IBL maps when their shaders changed.
renderer_poll_shaders :: proc() {
    r := &g_renderer
    if time.since(r.shader_poll_time) < SHADER_POLL_INTERVAL do return
    first_poll := r.shader_poll_time == {}
    r.shader_poll_time = time.now()

    stamp, environment := renderer_shader_stamp()
    // The first poll records the shaders startup built from.
    if first_poll {
        r.shader_stamp, r.shader_polled_stamp, r.environment_shader_stamp = stamp, stamp, environment
        return
    }
    settled := stamp == r.shader_polled_stamp
    r.shader_polled_stamp = stamp
    if !settled || stamp == r.shader_stamp do return

    r.shader_stamp = stamp
    renderer_reload_shaders()
    if r.shader_error == "" && environment != r.environment_shader_stamp {
        r.environment_shader_stamp = environment
        if _, pending := r.environment_pending.?; !pending {
            r.environment_filtered_asset = 0
            r.environment_pending = r.environment_settings
        }
    }
}

renderer_init :: proc() {
    r := &g_renderer

    r.width = WINDOW_WIDTH
    r.height = WINDOW_HEIGHT

    r.post_exposure = 1.0
    r.auto_exposure = DEFAULT_AUTO_EXPOSURE
    for &entity in r.spot_shadow_entities do entity = -1
    for &entity in r.point_shadow_entities do entity = -1
    r.post_threshold = 1.0
    r.post_strength = 0.6
    r.post_tone_mapper = .ACES
    // New scenes use TAA; files saved without the setting load as FXAA.
    r.post_anti_aliasing = .TAA
    r.post_sharpness = DEFAULT_SHARPNESS

    r.shadow_bias_constant = DEFAULT_SHADOW_BIAS_CONSTANT
    r.shadow_bias_slope = DEFAULT_SHADOW_BIAS_SLOPE
    r.shadow_distance = DEFAULT_SHADOW_DISTANCE

    r.ao_enabled = true
    r.ao_radius = DEFAULT_AO_RADIUS
    r.ao_intensity = DEFAULT_AO_INTENSITY

    r.ssr_enabled = true
    r.ssr_max_distance = DEFAULT_SSR_MAX_DISTANCE
    r.ssr_thickness = DEFAULT_SSR_THICKNESS
    r.ssr_max_roughness = DEFAULT_SSR_MAX_ROUGHNESS

    r.fog = renderer_default_fog_settings()

    r.frustum_culling_enabled = true

    // DEBUG LAYER
    when ODIN_DEBUG {
        debug: ^d3d12.IDebug
        if win32.SUCCEEDED(d3d12.GetDebugInterface(d3d12.IDebug_UUID, (^rawptr)(&debug))) {
            debug->EnableDebugLayer()
            debug->Release()
        }
    }

    // FACTORY
    factory_flags: dxgi.CREATE_FACTORY
    when ODIN_DEBUG {
        factory_flags = { .DEBUG }
    }

    factory: ^dxgi.IFactory6
    dx_check(dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory6_UUID, (^rawptr)(&factory)))
    defer factory->Release()

    // ADAPTER
    adapter: ^dxgi.IAdapter1
    dx_check(factory->EnumAdapterByGpuPreference(
        0,
        .HIGH_PERFORMANCE,
        dxgi.IAdapter1_UUID,
        (^rawptr)(&adapter),
    ))
    defer adapter->Release()

    // DEVICE
    dx_check(d3d12.CreateDevice(adapter, ._12_0, d3d12.IDevice_UUID, (^rawptr)(&r.device)))

    // Debug-layer messages go to an attached debugger; also read them back so
    // a plain console run of a debug build shows them.
    when ODIN_DEBUG {
        r.device->QueryInterface(d3d12.IInfoQueue_UUID, (^rawptr)(&r.info_queue))
    }

    // COMMAND QUEUE
    queue_desc := d3d12.COMMAND_QUEUE_DESC{
        Type = .DIRECT,
        Flags = {},
    }
    dx_check(r.device->CreateCommandQueue(&queue_desc, d3d12.ICommandQueue_UUID, (^rawptr)(&r.command_queue)))

    // SWAP CHAIN
    sc_desc := dxgi.SWAP_CHAIN_DESC1{
        BufferCount = FRAME_COUNT,
        Width = r.width,
        Height = r.height,
        Format = .R8G8B8A8_UNORM,
        BufferUsage = {.RENDER_TARGET_OUTPUT},
        SwapEffect = .FLIP_DISCARD,
        SampleDesc = { Count = 1, Quality = 0},
    }

    swap_chain1: ^dxgi.ISwapChain1
    dx_check(factory->CreateSwapChainForHwnd(
        r.command_queue,
        g_hwnd,
        &sc_desc,
        nil, nil,
        &swap_chain1
    ))
    defer swap_chain1->Release()

    factory->MakeWindowAssociation(g_hwnd, {.NO_ALT_ENTER})

    dx_check(swap_chain1->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&r.swap_chain)))
    r.frame_index = r.swap_chain->GetCurrentBackBufferIndex()

    // RTV DESCRIPTOR HEAP
    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = FRAME_COUNT,
        Type = .RTV,
        Flags = {},
    }
    dx_check(r.device->CreateDescriptorHeap(&rtv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&r.rtv_heap)))
    
    r.rtv_descriptor_size = r.device->GetDescriptorHandleIncrementSize(.RTV)

    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)
    for i in 0..<FRAME_COUNT {
        dx_check(r.swap_chain->GetBuffer(u32(i), d3d12.IResource_UUID, (^rawptr)(&r.render_targets[i])))
        r.device->CreateRenderTargetView(r.render_targets[i], nil, rtv_handle)
        rtv_handle.ptr += uint(r.rtv_descriptor_size)
    }

    // COMMAND ALLOCATORS
    for i in 0..<FRAME_COUNT{
        dx_check(r.device->CreateCommandAllocator(
            .DIRECT,
            d3d12.ICommandAllocator_UUID,
            (^rawptr)(&r.command_allocators[i]),
        ))
    }

    // COMMAND LIST
    dx_check(r.device->CreateCommandList(
        0,
        .DIRECT,
        r.command_allocators[0],
        nil,
        d3d12.IGraphicsCommandList_UUID,
        (^rawptr)(&r.command_list),
    ))
    r.command_list->Close()

    // FENCE
    dx_check(r.device->CreateFence(0, {}, d3d12.IFence_UUID, (^rawptr)(&r.fence)))

    r.fence_event = win32.CreateEventW(nil, false, false, nil)
    if r.fence_event == nil{
        panic("Failed to create fence event")
    }

    dx_check(r.command_queue->GetTimestampFrequency(&r.timestamp_frequency))

    renderer_create_timestamp_resources()
}

// The single root signature every pass uses. Passes bind by slot name; the
// layout table below is the only place registers are assigned.
Root_Slot :: enum u32 {
    Object_Constants,    // b0: per-draw transforms and material values
    Texture_T0,          // t0: main input of full-screen passes (sky panorama, scene color, ...)
    Texture_T1,          // t1: second input (shadow cascades, bloom, TAA history)
    Post_Constants,      // b1
    Sky_Constants,       // b2
    Environment,         // t2: HDR panorama while baking the IBL maps
    Irradiance,          // t3
    Prefilter_Constants, // b3
    Prefiltered,         // t4
    Material,            // t10-t15: albedo, normal, roughness, metallic, emissive, occlusion
    Frame_Constants,     // b4: camera, lights, shadows, AO, TAA matrices
    Shadow_Cascade,      // b5: root constant, the cascade being drawn
    Texture_T8,          // t8: ambient occlusion, or TAA motion vectors
    Depth,               // t9: scene depth
    Mip_Constants,       // b6: root constant, texture mip builder flags
    Exposure_Buffer,     // t16: root SRV, the automatic exposure (auto_exposure.hlsl)
    Spot_Shadows,        // t5: spot light shadow maps (one slice per slot)
    Point_Shadows,       // t6: point light shadow cube maps (one cube per slot)
    Surface,             // t7: view-space normal and roughness from the prepass
    Reflections,         // t17: screen-space reflections for the lit pass
    Lights,              // t18: root SRV, this frame's visible point and spot lights
    Cluster_Lights,      // t19: root SRV, each light cluster's light list
}

// SRV: a root shader-resource view of a buffer, bound by GPU address.
Root_Param_Kind :: enum {CBV, Table, Constants, SRV}

Root_Param :: struct {
    kind: Root_Param_Kind,
    register: u32,  // b# for CBVs and constants, first t# for tables
    count: u32,     // SRVs in a table, or 32-bit values for constants
    visibility: d3d12.SHADER_VISIBILITY,
}

MATERIAL_TEXTURE_COUNT :: 6

ROOT_LAYOUT := [Root_Slot]Root_Param{
    .Object_Constants    = {.CBV, 0, 0, .ALL},
    .Texture_T0          = {.Table, 0, 1, .PIXEL},
    .Texture_T1          = {.Table, 1, 1, .PIXEL},
    .Post_Constants      = {.CBV, 1, 0, .PIXEL},
    .Sky_Constants       = {.CBV, 2, 0, .PIXEL},
    .Environment         = {.Table, 2, 1, .PIXEL},
    .Irradiance          = {.Table, 3, 1, .PIXEL},
    .Prefilter_Constants = {.CBV, 3, 0, .PIXEL},
    .Prefiltered         = {.Table, 4, 1, .PIXEL},
    .Material            = {.Table, 10, MATERIAL_TEXTURE_COUNT, .PIXEL},
    .Frame_Constants     = {.CBV, 4, 0, .ALL},
    .Shadow_Cascade      = {.Constants, 5, 1, .VERTEX},
    .Texture_T8          = {.Table, 8, 1, .PIXEL},
    .Depth               = {.Table, 9, 1, .PIXEL},
    .Mip_Constants       = {.Constants, 6, 1, .PIXEL},
    .Exposure_Buffer     = {.SRV, 16, 0, .PIXEL},
    .Spot_Shadows        = {.Table, 5, 1, .PIXEL},
    .Point_Shadows       = {.Table, 6, 1, .PIXEL},
    .Surface             = {.Table, 7, 1, .PIXEL},
    .Reflections         = {.Table, 17, 1, .PIXEL},
    .Lights              = {.SRV, 18, 0, .PIXEL},
    .Cluster_Lights      = {.SRV, 19, 0, .PIXEL},
}

// Binds a draw's object constants and geometry and draws its submesh range.
renderer_draw :: proc(draws: []Draw, draw_index: u32) {
    r := &g_renderer
    i := int(draw_index)
    assert(i < len(draws))
    draw := draws[i]
    renderer_bind_cbv(.Object_Constants, renderer_object_cb_address(i))

    assert(int(draw.mesh) > 0 && int(draw.mesh) < len(r.meshes))
    gpu_mesh := &r.meshes[draw.mesh]
    r.command_list->IASetVertexBuffers(0, 1, &gpu_mesh.vertex_buffer_view)
    r.command_list->IASetIndexBuffer(&gpu_mesh.index_buffer_view)
    r.command_list->DrawIndexedInstanced(draw.index_count, 1, draw.first_index, 0, 0)
}

// Draws a pass's draws with their material tables, switching to each draw's
// pipeline variant from `pipelines` when it changes. The SRV heap must be set.
renderer_draw_list :: proc(draws: []Draw, indices: []u32, pipelines: [Draw_Variant]^d3d12.IPipelineState) {
    r := &g_renderer
    current: Maybe(Draw_Variant)
    for draw_index in indices {
        draw := &draws[draw_index]
        if current != draw.variant {
            r.command_list->SetPipelineState(pipelines[draw.variant])
            current = draw.variant
        }
        r.command_list->SetGraphicsRootDescriptorTable(u32(Root_Slot.Material), draw.material_table)
        renderer_draw(draws, draw_index)
    }
}

renderer_bind_cbv :: proc(slot: Root_Slot, address: u64) {
    assert(ROOT_LAYOUT[slot].kind == .CBV)
    g_renderer.command_list->SetGraphicsRootConstantBufferView(u32(slot), address)
}

renderer_bind_buffer_srv :: proc(slot: Root_Slot, address: u64) {
    assert(ROOT_LAYOUT[slot].kind == .SRV)
    g_renderer.command_list->SetGraphicsRootShaderResourceView(u32(slot), address)
}

// Binds the table at `slot` starting at descriptor `srv_index` of the SRV heap.
renderer_bind_srv :: proc(slot: Root_Slot, srv_index: u32) {
    assert(ROOT_LAYOUT[slot].kind == .Table)
    g_renderer.command_list->SetGraphicsRootDescriptorTable(u32(slot), renderer_srv_gpu(srv_index))
}

renderer_create_root_signature :: proc() {
    r := &g_renderer

    params: [Root_Slot]d3d12.ROOT_PARAMETER
    ranges: [Root_Slot]d3d12.DESCRIPTOR_RANGE
    for layout, slot in ROOT_LAYOUT {
        param := &params[slot]
        param.ShaderVisibility = layout.visibility
        switch layout.kind {
            case .SRV:
                param.ParameterType = .SRV
                param.Descriptor = {ShaderRegister = layout.register}
            case .CBV:
                param.ParameterType = .CBV
                param.Descriptor = {ShaderRegister = layout.register}
            case .Constants:
                param.ParameterType = ._32BIT_CONSTANTS
                param.Constants = {ShaderRegister = layout.register, Num32BitValues = layout.count}
            case .Table:
                ranges[slot] = {
                    RangeType = .SRV,
                    NumDescriptors = layout.count,
                    BaseShaderRegister = layout.register,
                }
                param.ParameterType = .DESCRIPTOR_TABLE
                param.DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &ranges[slot]}
        }
    }

    linear_wrap := d3d12.STATIC_SAMPLER_DESC{
        Filter = .MIN_MAG_MIP_LINEAR,
        AddressU = .WRAP,
        AddressV = .WRAP,
        AddressW = .WRAP,
        ShaderVisibility = .PIXEL,
        MaxLOD = 16.0,
    }
    shadow_comparison := d3d12.STATIC_SAMPLER_DESC{
        Filter = .COMPARISON_MIN_MAG_LINEAR_MIP_POINT,
        AddressU = .BORDER,
        AddressV = .BORDER,
        AddressW = .BORDER,
        ComparisonFunc = .LESS_EQUAL,
        BorderColor = .OPAQUE_WHITE,
        ShaderRegister = 1,
        ShaderVisibility = .PIXEL,
    }
    material := linear_wrap
    material.Filter = .ANISOTROPIC
    material.MaxAnisotropy = 16
    material.ComparisonFunc = .ALWAYS
    material.ShaderRegister = 2
    // Panoramas wrap around horizontally but not over the poles.
    environment := linear_wrap
    environment.AddressV = .CLAMP
    environment.ShaderRegister = 3
    // Screen-space lookups (FXAA, TAA) must not wrap to the opposite edge.
    clamp := linear_wrap
    clamp.AddressU = .CLAMP
    clamp.AddressV = .CLAMP
    clamp.AddressW = .CLAMP
    clamp.ShaderRegister = 4
    samplers := [?]d3d12.STATIC_SAMPLER_DESC{linear_wrap, shadow_comparison, material, environment, clamp}

    rs_desc := d3d12.ROOT_SIGNATURE_DESC{
        NumParameters = len(params),
        pParameters = &params[Root_Slot(0)],
        NumStaticSamplers = len(samplers),
        pStaticSamplers = &samplers[0],
        Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT},
    }

    signature, errors: ^d3d12.IBlob
    hr := d3d12.SerializeRootSignature(&rs_desc, ._1, &signature, &errors)
    if errors != nil {
        fmt.println("Root signature:", cstring(errors->GetBufferPointer()))
        errors->Release()
    }
    dx_check(hr)
    defer signature->Release()

    dx_check(r.device->CreateRootSignature(
        0,
        signature->GetBufferPointer(),
        signature->GetBufferSize(),
        d3d12.IRootSignature_UUID,
        (^rawptr)(&r.root_signature),
    ))
}

shader_bytecode :: proc(blob: ^d3d12.IBlob) -> d3d12.SHADER_BYTECODE {
    if blob == nil do return {}
    return {pShaderBytecode = blob->GetBufferPointer(), BytecodeLength = blob->GetBufferSize()}
}

renderer_create_pso :: proc(desc: ^d3d12.GRAPHICS_PIPELINE_STATE_DESC, pso: ^^d3d12.IPipelineState) {
    r := &g_renderer
    if renderer_skip_pipeline() do return
    renderer_check_pipeline(r.device->CreateGraphicsPipelineState(desc, d3d12.IPipelineState_UUID, (^rawptr)(pso)))
}

// A full-screen pass: `base` (no depth, no input layout) with this pixel
// shader, writing one target of `format`.
renderer_create_fullscreen_pso :: proc(
    base: d3d12.GRAPHICS_PIPELINE_STATE_DESC,
    path: string,
    entry: cstring,
    format: dxgi.FORMAT,
    pso: ^^d3d12.IPipelineState,
) {
    ps := renderer_compile_shader(path, entry, "ps_5_1")
    defer ps->Release()
    desc := base
    desc.PS = shader_bytecode(ps)
    desc.RTVFormats[0] = format
    renderer_create_pso(&desc, pso)
}

renderer_create_pipelines :: proc() {
    r := &g_renderer

    scene_vs := renderer_compile_shader("shaders/scene.hlsl", "VSMain", "vs_5_1")
    defer scene_vs->Release()
    scene_ps := renderer_compile_shader("shaders/scene.hlsl", "PSMain", "ps_5_1")
    defer scene_ps->Release()
    transparent_ps := renderer_compile_shader("shaders/scene.hlsl", "PSTransparent", "ps_5_1")
    defer transparent_ps->Release()
    shadow_vs := renderer_compile_shader("shaders/scene.hlsl", "VSShadow", "vs_5_1")
    defer shadow_vs->Release()
    depth_vs := renderer_compile_shader("shaders/scene.hlsl", "VSDepth", "vs_5_1")
    defer depth_vs->Release()
    prepass_ps := renderer_compile_shader("shaders/scene.hlsl", "PSPrepass", "ps_5_1")
    defer prepass_ps->Release()
    prepass_mask_ps := renderer_compile_shader("shaders/scene.hlsl", "PSPrepassMasked", "ps_5_1")
    defer prepass_mask_ps->Release()
    shadow_mask_ps := renderer_compile_shader("shaders/scene.hlsl", "PSShadowMasked", "ps_5_1")
    defer shadow_mask_ps->Release()
    fullscreen_vs := renderer_compile_shader("shaders/post_process.hlsl", "VSMain", "vs_5_1")
    defer fullscreen_vs->Release()

    // Matches Vertex.
    input_layout := [?]d3d12.INPUT_ELEMENT_DESC{
        {SemanticName = "POSITION", Format = .R32G32B32_FLOAT, AlignedByteOffset = 0, InputSlotClass = .PER_VERTEX_DATA},
        {SemanticName = "NORMAL", Format = .R32G32B32_FLOAT, AlignedByteOffset = 12, InputSlotClass = .PER_VERTEX_DATA},
        {SemanticName = "TEXCOORD", Format = .R32G32_FLOAT, AlignedByteOffset = 24, InputSlotClass = .PER_VERTEX_DATA},
        {SemanticName = "TANGENT", Format = .R32G32B32A32_FLOAT, AlignedByteOffset = 32, InputSlotClass = .PER_VERTEX_DATA},
    }

    // Base state for mesh drawing: back-face culling, depth test and write,
    // one opaque color target.
    mesh_desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC{
        pRootSignature = r.root_signature,
        VS = shader_bytecode(scene_vs),
        PS = shader_bytecode(scene_ps),
        InputLayout = {pInputElementDescs = &input_layout[0], NumElements = len(input_layout)},
        RasterizerState = {FillMode = .SOLID, CullMode = .BACK, DepthClipEnable = true},
        BlendState = {RenderTarget = {0 = {
            SrcBlend = .ONE,
            DestBlend = .ZERO,
            BlendOp = .ADD,
            SrcBlendAlpha = .ONE,
            DestBlendAlpha = .ZERO,
            BlendOpAlpha = .ADD,
            LogicOp = .NOOP,
            RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
        }}},
        DepthStencilState = {DepthEnable = true, DepthWriteMask = .ALL, DepthFunc = .LESS},
        DSVFormat = .D32_FLOAT,
        SampleMask = max(u32),
        PrimitiveTopologyType = .TRIANGLE,
        NumRenderTargets = 1,
        SampleDesc = {Count = 1},
    }
    mesh_desc.RTVFormats[0] = .R16G16B16A16_FLOAT

    // One pipeline per draw variant in each mesh pass: double-sided materials
    // draw without culling, and cutouts discard pixels in the depth-only passes.
    for variant in Draw_Variant {
        masked := variant == .Masked || variant == .Masked_Double_Sided
        variant_desc := mesh_desc
        if variant == .Double_Sided || variant == .Masked_Double_Sided {
            variant_desc.RasterizerState.CullMode = .NONE
        }

        // Shadow cascades: depth only. No rasterizer bias: scene.hlsl applies
        // the adjustable receiver bias.
        shadow_desc := variant_desc
        shadow_desc.VS = shader_bytecode(shadow_vs)
        shadow_desc.PS = shader_bytecode(shadow_mask_ps) if masked else {}
        shadow_desc.NumRenderTargets = 0
        shadow_desc.RTVFormats[0] = .UNKNOWN
        renderer_create_pso(&shadow_desc, &r.shadow_pipeline_states[variant])

        // Spot shadows are perspective, where a fixed receiver bias does not
        // fit every distance; a rasterizer slope-scaled bias does the bulk.
        spot_shadow_desc := shadow_desc
        spot_shadow_desc.RasterizerState.DepthBias = SPOT_SHADOW_DEPTH_BIAS
        spot_shadow_desc.RasterizerState.SlopeScaledDepthBias = SPOT_SHADOW_SLOPE_BIAS
        renderer_create_pso(&spot_shadow_desc, &r.spot_shadow_pipeline_states[variant])

        // Depth prepass, which also writes per-pixel motion for TAA and the
        // surface buffer for SSR. VSDepth computes positions with the same
        // code as VSMain, so the lit pass can test LESS_EQUAL against it.
        depth_desc := variant_desc
        depth_desc.VS = shader_bytecode(depth_vs)
        depth_desc.PS = shader_bytecode(prepass_mask_ps if masked else prepass_ps)
        depth_desc.NumRenderTargets = 2
        depth_desc.RTVFormats[0] = .R16G16_FLOAT
        depth_desc.RTVFormats[1] = SSR_FORMAT
        renderer_create_pso(&depth_desc, &r.depth_prepass_pipeline_states[variant])

        // Lit pass into the HDR target, testing against the prepass without
        // writing. Cutouts shade only where their prepass depth survived
        // (EQUAL), so the lit pass does not repeat the alpha test.
        lit_desc := variant_desc
        lit_desc.DepthStencilState.DepthFunc = .EQUAL if masked else .LESS_EQUAL
        lit_desc.DepthStencilState.DepthWriteMask = .ZERO
        renderer_create_pso(&lit_desc, &r.hdr_pipeline_states[variant])
    }

    // Blended surfaces: over the lit image by their alpha, depth-tested
    // against the prepass without writing. Double-sided ones draw twice, back
    // faces (front culled) and then front faces.
    transparent_desc := mesh_desc
    transparent_desc.PS = shader_bytecode(transparent_ps)
    transparent_desc.BlendState.RenderTarget[0] = {
        BlendEnable = true,
        SrcBlend = .SRC_ALPHA,
        DestBlend = .INV_SRC_ALPHA,
        BlendOp = .ADD,
        SrcBlendAlpha = .ONE,
        DestBlendAlpha = .INV_SRC_ALPHA,
        BlendOpAlpha = .ADD,
        LogicOp = .NOOP,
        RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
    }
    transparent_desc.DepthStencilState.DepthFunc = .LESS_EQUAL
    transparent_desc.DepthStencilState.DepthWriteMask = .ZERO
    renderer_create_pso(&transparent_desc, &r.transparent_front_pipeline_state)
    transparent_desc.RasterizerState.CullMode = .FRONT
    renderer_create_pso(&transparent_desc, &r.transparent_back_pipeline_state)

    // Full-screen triangle: no input layout, culling, or depth.
    fullscreen := mesh_desc
    fullscreen.VS = shader_bytecode(fullscreen_vs)
    fullscreen.InputLayout = {}
    fullscreen.RasterizerState.CullMode = .NONE
    fullscreen.DepthStencilState = {DepthEnable = false, DepthWriteMask = .ZERO, DepthFunc = .ALWAYS}
    fullscreen.DSVFormat = .UNKNOWN

    POST :: "shaders/post_process.hlsl"
    renderer_create_fullscreen_pso(fullscreen, POST, "PSMain", .R8G8B8A8_UNORM, &r.post_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, POST, "PSFxaa", .R8G8B8A8_UNORM, &r.fxaa_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, POST, "PSSharpen", .R8G8B8A8_UNORM, &r.sharpen_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, POST, "PSTaaResolve", .R16G16B16A16_FLOAT, &r.taa_resolve_pipeline_state)
    bloom_entries := [BLOOM_PASS_COUNT]cstring{"PSBloomPrefilter", "PSBloomDownsample", "PSBloomUpsample"}
    for entry, i in bloom_entries {
        bloom := fullscreen
        if i == 2 {
            // Upsamples add onto the level the downsample left behind.
            bloom.BlendState.RenderTarget[0].BlendEnable = true
            bloom.BlendState.RenderTarget[0].SrcBlend = .ONE
            bloom.BlendState.RenderTarget[0].DestBlend = .ONE
        }
        renderer_create_fullscreen_pso(bloom, POST, entry, .R16G16B16A16_FLOAT, &r.bloom_pipeline_states[i])
    }

    renderer_create_fullscreen_pso(fullscreen, "shaders/sky.hlsl", "PSMain", .R16G16B16A16_FLOAT, &r.sky_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, "shaders/irradiance.hlsl", "PSMain", .R16G16B16A16_FLOAT, &r.irradiance_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, "shaders/environment_prefilter.hlsl", "PSMain", .R16G16B16A16_FLOAT, &r.prefilter_pipeline_state)

    // SSAO's pixel shaders live in scene.hlsl to share its frame constants.
    renderer_create_fullscreen_pso(fullscreen, "shaders/scene.hlsl", "PSSsao", .R8_UNORM, &r.ssao_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, "shaders/scene.hlsl", "PSSsaoBlur", .R8_UNORM, &r.ssao_blur_pipeline_state)
    renderer_create_fullscreen_pso(fullscreen, "shaders/scene.hlsl", "PSSsr", SSR_FORMAT, &r.ssr_pipeline_state)
    // Fog over the lit image: fog.rgb + scene * fog.a, keeping the scene's alpha.
    fog_apply := fullscreen
    fog_apply.BlendState.RenderTarget[0] = {
        BlendEnable = true,
        SrcBlend = .ONE,
        DestBlend = .SRC_ALPHA,
        BlendOp = .ADD,
        SrcBlendAlpha = .ZERO,
        DestBlendAlpha = .ONE,
        BlendOpAlpha = .ADD,
        LogicOp = .NOOP,
        RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
    }
    renderer_create_fullscreen_pso(fog_apply, "shaders/scene.hlsl", "PSFogApply", .R16G16B16A16_FLOAT, &r.fog_apply_pipeline_state)

    renderer_create_fullscreen_pso(fullscreen, "shaders/texture_mips.hlsl", "PSDownsample", .R8G8B8A8_UNORM, &r.mip_pipeline)
}

renderer_load_assets :: proc(){
    r := &g_renderer

    renderer_create_root_signature()

    r.meshes = make([]GpuMesh, len(g_assets.meshes))
    for i in 1..<len(g_assets.meshes) {
        dx_check(renderer_upload_mesh(
            &r.meshes[i],
            g_assets.meshes[i].data,
        ))
    }

    // CONSTANT BUFFER
    renderer_create_frame_constant_buffers()

    // â”€â”€ 6. Viewport & Scissor â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    r.viewport = d3d12.VIEWPORT {
        Width    = WINDOW_WIDTH,
        Height   = WINDOW_HEIGHT,
        MinDepth = 0,
        MaxDepth = 1,
    }
    r.scissor_rect = d3d12.RECT {
        right  = WINDOW_WIDTH,
        bottom = WINDOW_HEIGHT,
    }
}

renderer_upload_mesh :: proc(gpu: ^GpuMesh, mesh: MeshData) -> (hr: win32.HRESULT) {
    r := &g_renderer

    defer if hr < 0 {
        if gpu.vertex_buffer != nil do gpu.vertex_buffer->Release()
        if gpu.index_buffer != nil do gpu.index_buffer->Release()
        gpu^ = {}
    }

    // Vertex size keeps the index data 4-byte aligned in the staging buffer.
    vb_size := u64(len(mesh.vertices) * size_of(Vertex))
    ib_size := u64(len(mesh.indices) * size_of(u32))

    buffer_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = vb_size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }

    // Static geometry lives in GPU-local memory. Buffers start in COMMON and
    // are implicitly promoted to COPY_DEST by the copy below.
    default_heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    hr = r.device->CreateCommittedResource(
        &default_heap, {}, &buffer_desc, d3d12.RESOURCE_STATE_COMMON, nil,
        d3d12.IResource_UUID, (^rawptr)(&gpu.vertex_buffer),
    )
    if hr < 0 do return

    buffer_desc.Width = ib_size
    hr = r.device->CreateCommittedResource(
        &default_heap, {}, &buffer_desc, d3d12.RESOURCE_STATE_COMMON, nil,
        d3d12.IResource_UUID, (^rawptr)(&gpu.index_buffer),
    )
    if hr < 0 do return

    buffer_desc.Width = vb_size + ib_size
    upload_heap := d3d12.HEAP_PROPERTIES{Type = .UPLOAD}
    upload_buffer: ^d3d12.IResource
    hr = r.device->CreateCommittedResource(
        &upload_heap, {}, &buffer_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil,
        d3d12.IResource_UUID, (^rawptr)(&upload_buffer),
    )
    if hr < 0 do return
    defer upload_buffer->Release()

    mapped: rawptr
    write_range := d3d12.RANGE{Begin = 0, End = 0}
    hr = upload_buffer->Map(0, &write_range, &mapped)
    if hr < 0 do return
    runtime.mem_copy(mapped, raw_data(mesh.vertices), int(vb_size))
    runtime.mem_copy(
        rawptr(uintptr(mapped) + uintptr(vb_size)),
        raw_data(mesh.indices),
        int(ib_size),
    )
    upload_buffer->Unmap(0, nil)

    hr = r.command_allocators[0]->Reset()
    if hr < 0 do return
    hr = r.command_list->Reset(r.command_allocators[0], nil)
    if hr < 0 do return

    r.command_list->CopyBufferRegion(gpu.vertex_buffer, 0, upload_buffer, 0, vb_size)
    r.command_list->CopyBufferRegion(gpu.index_buffer, 0, upload_buffer, vb_size, ib_size)

    barriers := [2]d3d12.RESOURCE_BARRIER{
        {Type = .TRANSITION},
        {Type = .TRANSITION},
    }
    barriers[0].Transition = {
        pResource = gpu.vertex_buffer,
        StateBefore = {.COPY_DEST},
        StateAfter = {.VERTEX_AND_CONSTANT_BUFFER},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    barriers[1].Transition = {
        pResource = gpu.index_buffer,
        StateBefore = {.COPY_DEST},
        StateAfter = {.INDEX_BUFFER},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(u32(len(barriers)), raw_data(barriers[:]))

    hr = r.command_list->Close()
    if hr < 0 do return

    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))

    // The staging buffer must outlive the copy.
    renderer_wait_for_gpu()

    gpu.vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW{
        BufferLocation = gpu.vertex_buffer->GetGPUVirtualAddress(),
        StrideInBytes = size_of(Vertex),
        SizeInBytes = u32(vb_size),
    }
    gpu.index_buffer_view = d3d12.INDEX_BUFFER_VIEW{
        BufferLocation = gpu.index_buffer->GetGPUVirtualAddress(),
        Format = .R32_UINT,
        SizeInBytes = u32(ib_size),
    }
    gpu.index_count = u32(len(mesh.indices))
    return
}

renderer_create_depth_buffer :: proc(){
    r := &g_renderer

    // [0] writes depth (prepass); [1] is read-only, for passes that test
    // against it while the depth is also bound as a shader resource.
    if r.dsv_heap == nil {
        dsv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
            NumDescriptors = 2,
            Type = .DSV,
            Flags = {},
        }
        dx_check(r.device->CreateDescriptorHeap(
            &dsv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.dsv_heap),
        ))
    }

    depth_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.width),
        Height = r.height,
        DepthOrArraySize = 1,
        MipLevels = 1,
        // Typeless so SSAO can read it as R32_FLOAT.
        Format = .R32_TYPELESS,
        SampleDesc = { Count = 1 },
        Flags = {.ALLOW_DEPTH_STENCIL},
    }

    clear_value := d3d12.CLEAR_VALUE{
        Format = .D32_FLOAT,
    }
    clear_value.DepthStencil = {Depth = 1.0, Stencil = 0}

    heap_props := d3d12.HEAP_PROPERTIES { Type = .DEFAULT }

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &depth_desc,
        { .DEPTH_WRITE },
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.depth_buffer),
    ))

    dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC{
        Format = .D32_FLOAT,
        ViewDimension = .TEXTURE2D,
        Flags = {},
    }
    dsv_handle : d3d12.CPU_DESCRIPTOR_HANDLE
    r.dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)

    r.device->CreateDepthStencilView(
        r.depth_buffer,
        &dsv_desc,
        dsv_handle,
    )

    dsv_desc.Flags = {.READ_ONLY_DEPTH}
    dsv_handle.ptr += uint(r.device->GetDescriptorHandleIncrementSize(.DSV))
    r.device->CreateDepthStencilView(r.depth_buffer, &dsv_desc, dsv_handle)
}

renderer_depth_dsv :: proc(read_only: bool) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    r := &g_renderer
    handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.dsv_heap->GetCPUDescriptorHandleForHeapStart(&handle)
    if read_only {
        handle.ptr += uint(r.device->GetDescriptorHandleIncrementSize(.DSV))
    }
    return handle
}

renderer_resize:: proc(width, height: u32){
    r := &g_renderer

    if width == 0 || height == 0 || (width == r.width && height == r.height){
        return
    }

    renderer_wait_for_gpu()

    r.hdr_texture->Release()
    r.ldr_texture->Release()
    for target in r.ao_targets do target->Release()
    renderer_release_taa_targets()
    renderer_release_ssr_targets()
    r.bloom_texture->Release()

    for i in 0..<FRAME_COUNT{
        r.render_targets[i]->Release()
    }
    r.depth_buffer->Release()

    dx_check(r.swap_chain->ResizeBuffers(
        FRAME_COUNT,
        width,
        height,
        .R8G8B8A8_UNORM,
        {},
    ))

    r.width = width
    r.height = height
    r.frame_index = r.swap_chain->GetCurrentBackBufferIndex()

    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

    for i in 0..<FRAME_COUNT{
        dx_check(r.swap_chain->GetBuffer(
            u32(i),
            d3d12.IResource_UUID,
            (^rawptr)(&r.render_targets[i]),
        ))
        r.device->CreateRenderTargetView(r.render_targets[i], nil, rtv_handle)
        rtv_handle.ptr += uint(r.rtv_descriptor_size)
    }

    renderer_create_depth_buffer()

    r.viewport.Width = f32(width)
    r.viewport.Height = f32(height)
    r.scissor_rect.right = i32(width)
    r.scissor_rect.bottom = i32(height)

    renderer_create_hdr_target()
    renderer_create_bloom_targets()
    renderer_create_ssao_targets()
    renderer_create_taa_targets()
    renderer_create_ssr_targets()
}

renderer_load_textures :: proc(){
    r := &g_renderer

    srv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = SRV_HEAP_CAPACITY,
        Type = .CBV_SRV_UAV,
        Flags = {.SHADER_VISIBLE},
    }

    dx_check(r.device->CreateDescriptorHeap(
        &srv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.srv_heap),
    ))

    // CPU-only mirror of the texture SRVs: the copy source for per-draw
    // material tables (copying out of a shader-visible heap is slow).
    srv_heap_desc.Flags = {}
    dx_check(r.device->CreateDescriptorHeap(
        &srv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.srv_staging_heap),
    ))

    r.srv_descriptor_size = r.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV)

    // Per frame in flight and per draw: albedo, normal, roughness, metallic.
    r.material_srv_start = renderer_alloc_srv(FRAME_COUNT * MAX_DRAWS * MATERIAL_TEXTURE_COUNT)

    r.shadow_srv_index = renderer_alloc_srv()
    r.spot_shadow_srv_index = renderer_alloc_srv()
    r.point_shadow_srv_index = renderer_alloc_srv()
    r.hdr_srv_index = renderer_alloc_srv()
    r.ldr_srv_index = renderer_alloc_srv()
    r.taa_srv_start = renderer_alloc_srv(2)
    r.velocity_srv_index = renderer_alloc_srv()
    r.bloom_srv_start = renderer_alloc_srv(BLOOM_MIP_COUNT)
    r.environment_srv_index = renderer_alloc_srv()
    r.irradiance_srv_index = renderer_alloc_srv()
    r.prefilter_srv_index = renderer_alloc_srv()
    r.environment_bake_srv_index = renderer_alloc_srv()
    r.ao_srv_start = renderer_alloc_srv(AO_TARGET_COUNT)
    r.depth_srv_index = renderer_alloc_srv()
    r.surface_srv_index = renderer_alloc_srv()
    r.ssr_srv_index = renderer_alloc_srv()
    // These slots stay valid before an HDRI is loaded or its IBL maps are baked.
    null_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R16G16B16A16_FLOAT, ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        Texture2D = {MipLevels = 1},
    }
    environment_slots := [3]u32{r.environment_srv_index, r.irradiance_srv_index, r.prefilter_srv_index}
    for index in environment_slots {
        srv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
        srv.ptr += uint(index) * uint(r.srv_descriptor_size)
        r.device->CreateShaderResourceView(nil, &null_desc, srv)
    }
    renderer_create_mip_resources()
    r.textures = make([]GpuTexture, len(g_assets.textures))
    for i in 1..<len(g_assets.textures) do r.textures[i].srv_index = renderer_alloc_srv()

    // Decode a batch in parallel, then upload it in order.
    batch := assets_decode_batch_size()
    for first := 1; first < len(g_assets.textures); first += batch {
        count := min(batch, len(g_assets.textures) - first)
        descs := make([]TextureDesc, count, context.temp_allocator)
        for &desc, i in descs do desc = g_assets.textures[first + i].desc
        decoded := make([]DecodedTexture, count, context.temp_allocator)
        assets_decode_textures(descs, decoded)
        for texture, i in decoded {
            if texture.message != "" do panic(texture.message)
            dx_check(renderer_upload_texture(
                &r.textures[first + i], descs[i], texture.pixels, texture.width, texture.height,
            ))
            g_assets.textures[first + i].alpha = assets_texture_alpha(descs[i], texture.pixels, texture.width, texture.height)
            delete(texture.pixels, runtime.heap_allocator())
        }
    }
}

// Frees a removed asset's GPU data; the GPU must be idle. The SRV slot stays
// allocated (handles are not reused), so its descriptor is simply never bound.
renderer_release_mesh :: proc(handle: MeshHandle) {
    mesh := &g_renderer.meshes[handle]
    if mesh.vertex_buffer != nil do mesh.vertex_buffer->Release()
    if mesh.index_buffer != nil do mesh.index_buffer->Release()
    mesh^ = {}
}

renderer_release_texture :: proc(handle: TextureHandle) {
    texture := &g_renderer.textures[handle]
    if texture.resource != nil do texture.resource->Release()
    texture.resource = nil
}

renderer_upload_texture :: proc(
    gpu: ^GpuTexture,
    desc: TextureDesc,
    pixels: []u8,
    width32, height32: u32,
) -> (hr: win32.HRESULT) {
    r := &g_renderer

    defer if hr < 0 && gpu.resource != nil {
        gpu.resource->Release()
        gpu.resource = nil
    }

    width, height := u64(width32), u64(height32)
    is_normal_map := desc.usage == .normal
    is_linear_data := desc.usage != .albedo && desc.usage != .emissive

    // Color textures are sRGB-encoded: the _SRGB format makes the sampler
    // decode to linear before filtering. Data maps stay UNORM.
    format: dxgi.FORMAT = .R8G8B8A8_UNORM_SRGB if !is_linear_data else .R8G8B8A8_UNORM

    // Only level 0 is uploaded; the GPU renders the rest of the chain. The
    // resource is typeless so the mip builder can view it as plain UNORM.
    mip_count := texture_mip_count(width32, height32)
    tex_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = width,
        Height = u32(height),
        DepthOrArraySize = 1,
        MipLevels = u16(mip_count),
        Format = .R8G8B8A8_TYPELESS,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET} if mip_count > 1 else {},
    }

    default_heap := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
    hr = r.device->CreateCommittedResource(
        &default_heap,
        {},
        &tex_desc,
        { .COPY_DEST },
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&gpu.resource),
    )
    if hr < 0 do return

    // UPLOAD BUFFER
    layout: d3d12.PLACED_SUBRESOURCE_FOOTPRINT
    row_count: u32
    row_size, upload_size: u64
    r.device->GetCopyableFootprints(&tex_desc, 0, 1, 0, &layout, &row_count, &row_size, &upload_size)

    upload_heap := d3d12.HEAP_PROPERTIES { Type = .UPLOAD }
    upload_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = upload_size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = { Count = 1},
        Layout = .ROW_MAJOR,
    }

    upload_buffer: ^d3d12.IResource
    hr = r.device->CreateCommittedResource(
        &upload_heap,
        {},
        &upload_desc,
        d3d12.RESOURCE_STATE_GENERIC_READ,
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&upload_buffer),
    )
    if hr < 0 do return
    defer upload_buffer->Release()

    mapped: rawptr
    hr = upload_buffer->Map(0, nil, &mapped)
    if hr < 0 do return
    for y in 0..<int(row_count) {
        destination_row := uintptr(mapped) + uintptr(layout.Offset) +
            uintptr(u64(y) * u64(layout.Footprint.RowPitch))
        source_row := uintptr(raw_data(pixels)) + uintptr(u64(y) * row_size)
        runtime.mem_copy(rawptr(destination_row), rawptr(source_row), int(row_size))
    }
    upload_buffer->Unmap(0, nil)

    hr = r.command_allocators[0]->Reset()
    if hr < 0 do return
    hr = r.command_list->Reset(r.command_allocators[0], nil)
    if hr < 0 do return

    src_location := d3d12.TEXTURE_COPY_LOCATION{
        pResource = upload_buffer,
        Type = .PLACED_FOOTPRINT,
    }
    src_location.PlacedFootprint = layout
    dst_location := d3d12.TEXTURE_COPY_LOCATION{
        pResource = gpu.resource,
        Type = .SUBRESOURCE_INDEX,
        SubresourceIndex = 0,
    }
    r.command_list->CopyTextureRegion(&dst_location, 0, 0, 0, &src_location, nil)

    // Level 0: COPY_DEST â†’ PIXEL_SHADER_RESOURCE; the mip builder moves the rest.
    copy_barrier := d3d12.RESOURCE_BARRIER { Type = .TRANSITION }
    copy_barrier.Transition = {
        pResource   = gpu.resource,
        StateBefore = { .COPY_DEST },
        StateAfter  = { .PIXEL_SHADER_RESOURCE },
        Subresource = 0,
    }
    r.command_list->ResourceBarrier(1, &copy_barrier)
    mip_mode: Texture_Mip_Mode = .Normal if is_normal_map else .Data if is_linear_data else .Srgb
    renderer_record_texture_mips(gpu.resource, width32, height32, mip_count, mip_mode)
    hr = r.command_list->Close()
    if hr < 0 do return

    lists := []^d3d12.ICommandList{ r.command_list }
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))

    renderer_wait_for_gpu()

    // â”€â”€ SRV â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
        Format                  = format,
        ViewDimension           = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = { MipLevels = mip_count }

    srv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv_handle)
    srv_handle.ptr += uint(gpu.srv_index) * uint(r.srv_descriptor_size)

    r.device->CreateShaderResourceView(gpu.resource, &srv_desc, srv_handle)

    staging_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_staging_heap->GetCPUDescriptorHandleForHeapStart(&staging_handle)
    staging_handle.ptr += uint(gpu.srv_index) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(gpu.resource, &srv_desc, staging_handle)

    return
}

renderer_render_frame :: proc(scene: ^Scene) {
    r := &g_renderer

    r.frame_index = r.swap_chain->GetCurrentBackBufferIndex()
    renderer_begin_frame()

    frame := renderer_prepare_frame(scene)

    draws := frame.draws[:frame.draw_count]
    shadow_draws: [SHADOW_VIEW_COUNT][]u32
    for view in 0..<SHADOW_VIEW_COUNT {
        shadow_draws[view] = frame.shadow_indices[view][:frame.shadow_draw_count[view]]
    }
    renderer_render_shadow_pass(draws, shadow_draws)

    // Depth first: SSAO and SSR read it, and the lit pass only shades
    // visible pixels. SSR reads last frame's image before the lit pass
    // overwrites the HDR target.
    visible := frame.scene_indices[:frame.scene_draw_count]
    renderer_render_depth_prepass(draws, visible)
    renderer_render_ssao()
    renderer_render_ssr()
    renderer_build_light_clusters()
    renderer_render_fog()
    transparent := frame.transparent_indices[:frame.transparent_draw_count]
    renderer_render_scene_pass(draws, visible, transparent)

    // TAA resolves in HDR, so bloom and tone mapping see the stable image.
    renderer_render_taa()
    renderer_render_auto_exposure()
    renderer_render_bloom()
    renderer_render_post_process(scene)
    r.ssr_history_valid = true

    // The prepass left depth readable; the next frame's prepass writes it.
    depth_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    depth_barrier.Transition = {
        pResource = r.depth_buffer,
        StateBefore = {.DEPTH_READ, .PIXEL_SHADER_RESOURCE},
        StateAfter = {.DEPTH_WRITE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &depth_barrier)

    renderer_submit_frame()
    dx_check(r.swap_chain->Present(1, {}))
    renderer_print_debug_messages()
}

renderer_begin_gpu_pass :: proc(pass: GPU_Pass) {
    r := &g_renderer
    r.command_list->EndQuery(
        r.timestamp_heap,
        .TIMESTAMP,
        r.frame_slot * GPU_TIMESTAMP_COUNT + u32(pass) * 2,
    )
}

renderer_end_gpu_pass :: proc(pass: GPU_Pass) {
    r := &g_renderer
    r.command_list->EndQuery(
        r.timestamp_heap,
        .TIMESTAMP,
        r.frame_slot * GPU_TIMESTAMP_COUNT + u32(pass) * 2 + 1,
    )
}

renderer_read_gpu_timings :: proc(slot: u32) {
    r := &g_renderer
    first_tick := int(slot) * GPU_TIMESTAMP_COUNT

    read_range := d3d12.RANGE{
        Begin = uint(first_tick * size_of(u64)),
        End = uint((first_tick + GPU_TIMESTAMP_COUNT) * size_of(u64)),
    }

    mapped: rawptr
    dx_check(r.timestamp_readback->Map(0, &read_range, &mapped))

    // Map returns the buffer's base address, including when Begin is nonzero.
    ticks := ([^]u64)(mapped)
    for i in 0..<GPU_PASS_COUNT {
        start_tick := ticks[first_tick + i * 2]
        end_tick := ticks[first_tick + i * 2 + 1]

        r.gpu_pass_ms[i] = f32(
            f64(end_tick - start_tick) * 1000.0 /
            f64(r.timestamp_frequency),
        )
    }

    written_range := d3d12.RANGE{Begin = 0, End = 0}
    r.timestamp_readback->Unmap(0, &written_range)
}

renderer_wait_for_gpu :: proc() {
    r := &g_renderer

    r.fence_value += 1
    dx_check(r.command_queue->Signal(r.fence, r.fence_value))
    renderer_wait_for_fence(r.fence_value)
}

renderer_destroy :: proc(){
    r:= &g_renderer
    renderer_wait_for_gpu()
    debug_ui_destroy()

    win32.CloseHandle(r.fence_event)
    r.fence->Release()
    r.command_list->Release()
    for i in 0..<FRAME_COUNT{
        r.command_allocators[i]->Release()
        r.render_targets[i]->Release()
    }
    r.rtv_heap->Release()
    r.swap_chain->Release()
    r.command_queue->Release()

    r.root_signature->Release()

    r.object_constant_buffer->Release()
    r.frame_constant_buffer->Release()

    r.depth_buffer->Release()
    r.dsv_heap->Release()

    // Assets removed from the catalog were released already.
    for &mesh in r.meshes[1:] {
        if mesh.vertex_buffer != nil do mesh.vertex_buffer->Release()
        if mesh.index_buffer != nil do mesh.index_buffer->Release()
    }

    for texture in r.textures[1:] {
        if texture.resource != nil do texture.resource->Release()
    }
    delete(r.meshes)
    delete(r.textures)
    r.srv_heap->Release()
    r.srv_staging_heap->Release()

    r.shadow_map->Release()
    r.shadow_dsv_heap->Release()
    r.spot_shadow_map->Release()
    r.spot_shadow_dsv_heap->Release()
    r.point_shadow_map->Release()
    r.point_shadow_dsv_heap->Release()

    r.hdr_texture->Release()
    r.hdr_rtv_heap->Release()
    r.ldr_texture->Release()
    r.ldr_rtv_heap->Release()
    renderer_release_taa_targets()
    r.taa_rtv_heap->Release()
    r.velocity_rtv_heap->Release()
    renderer_release_ssr_targets()
    renderer_release_light_clusters()
    renderer_release_fog()
    r.ssr_rtv_heap->Release()
    r.selection_root_signature->Release()

    r.bloom_texture->Release()
    r.bloom_rtv_heap->Release()

    for target in r.ao_targets do target->Release()
    r.ao_rtv_heap->Release()
    renderer_release_auto_exposure()
    r.mip_rtv_heap->Release()

    for slot in renderer_pipeline_slots() do slot^->Release()
    delete(r.shader_error)
    delete(r.shader_blobs)

    r.post_constant_buffer->Release()

    r.timestamp_readback->Release()
    r.timestamp_heap->Release()

    if r.environment_texture != nil do r.environment_texture->Release()
    r.sky_constant_buffer->Release()

    if r.irradiance_texture != nil do r.irradiance_texture->Release()
    if r.irradiance_rtv_heap != nil do r.irradiance_rtv_heap->Release()

    if r.prefilter_texture != nil do r.prefilter_texture->Release()
    if r.prefilter_rtv_heap != nil do r.prefilter_rtv_heap->Release()
    if r.prefilter_constant_buffer != nil do r.prefilter_constant_buffer->Release()

    // Everything above should be released by now: list anything still alive
    // besides the device and its debug interfaces.
    when ODIN_DEBUG {
        debug_device: ^d3d12.IDebugDevice
        if r.device->QueryInterface(d3d12.IDebugDevice_UUID, (^rawptr)(&debug_device)) >= 0 {
            debug_device->ReportLiveDeviceObjects({.DETAIL, .IGNORE_INTERNAL})
            debug_device->Release()
        }
    }
    renderer_print_debug_messages()
    if r.info_queue != nil do r.info_queue->Release()
    delete(g_debug_message_counts)
    r.device->Release()
}

perspective_lh :: proc(fovy, aspect, near, far: f32) -> alg.Matrix4f32 {
    tan_half_fov := math.tan(fovy * 0.5)

    return {
        1 / (aspect * tan_half_fov), 0,                0,                          0,
        0,                           1 / tan_half_fov, 0,                          0,
        0,                           0,                far / (far - near),          1,
        0,                           0,                -(near * far) / (far - near), 0,
    }
}

look_at_lh :: proc(eye, centre, up: alg.Vector3f32) -> alg.Matrix4f32 {
    f := alg.normalize(centre - eye)
    r := alg.normalize(alg.cross(up, f))
    u := alg.cross(f, r)

    return {
        r.x, u.x, f.x, 0,
        r.y, u.y, f.y, 0,
        r.z, u.z, f.z, 0,
        -alg.dot(r, eye), -alg.dot(u, eye), -alg.dot(f, eye), 1,
    }
}

orthographic_lh :: proc(left, right, bottom, top, near, far: f32) -> alg.Matrix4f32 {
    return {
        2 / (right - left), 0, 0, 0,
        0, 2 / (top - bottom), 0, 0,
        0, 0, 1 / (far - near), 0,
        -(right + left) / (right - left),
        -(top + bottom) / (top - bottom),
        -near / (far - near),
        1,
    }
}
