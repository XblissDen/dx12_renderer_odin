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

import "core:math"
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
// frees the slots of entities that no longer exist).
renderer_recapture_probes :: proc(forget := false) {
    p := &g_renderer.probes
    p.captured = {}
    if forget do for &entity in p.slot_entity do entity = -1
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
    renderer_begin_gpu_pass(.Probe_Capture)
    defer renderer_end_gpu_pass(.Probe_Capture)
    if p.capture_slot < 0 do return

    barrier := resource_transition(p.capture_texture, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET})
    r.command_list->ResourceBarrier(1, &barrier)

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_set_square_viewport(PROBE_SIZE)

    // What the lit pass binds, except the screen-space effects (off here).
    renderer_bind_srv(.Texture_T1, r.shadow_srv_index)
    renderer_bind_srv(.Spot_Shadows, r.spot_shadow_srv_index)
    renderer_bind_srv(.Point_Shadows, r.point_shadow_srv_index)
    renderer_bind_srv(.Irradiance, r.irradiance_srv_index)
    renderer_bind_srv(.Prefiltered, r.prefilter_srv_index)
    renderer_bind_srv(.Texture_T8, r.ao_srv_start + 1)
    renderer_bind_srv(.Reflections, r.ssr_srv_index)
    renderer_bind_buffer_srv(.Lights, renderer_light_buffer_address())
    renderer_bind_buffer_srv(.Cluster_Lights, r.cluster_buffer->GetGPUVirtualAddress())
    renderer_bind_probes()

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
        renderer_draw_batches(draws, face_batches[face], p.capture_pipeline_states)
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
    capture_masked_ps := renderer_compile_shader("shaders/scene.hlsl", "PSCaptureMasked", "ps_5_1")
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
}
