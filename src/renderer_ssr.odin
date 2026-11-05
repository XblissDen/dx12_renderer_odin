package main

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// Screen-space reflections. The depth prepass also writes each pixel's
// view-space shading normal and roughness (the surface buffer); before the lit
// pass, a full-screen pass marches each reflected ray through the depth buffer
// and reads the surface it hits from last frame's HDR image. The lit pass
// blends that over the environment's specular by the hit's confidence. With
// TAA, rays spread over the specular lobe and the history averages them.
//
// On GPUs with DXR 1.1 the same target is filled by ray-traced reflections
// instead (renderer_render_ray_reflections): the reflected ray is traced
// through the scene's TLAS and its hit is shaded, so off-screen and hidden
// surfaces reflect too.
//
// Either way, one ray per pixel leaves rough reflections noisy. The denoiser
// (renderer_denoise_reflections) cleans them up on its own, with or without
// TAA: a spatial filter sized by roughness and hit distance
// (PSReflectionFilter), then a history averaged over frames at the same
// surface (PSReflectionAccumulate). The lit pass reads the history.
DEFAULT_SSR_MAX_DISTANCE :: f32(30)
DEFAULT_SSR_THICKNESS :: f32(0.5)
DEFAULT_SSR_MAX_ROUGHNESS :: f32(0.6)
MIN_SSR_MAX_DISTANCE :: f32(1)
MAX_SSR_MAX_DISTANCE :: f32(200)
MIN_SSR_THICKNESS :: f32(0.01)
MAX_SSR_THICKNESS :: f32(5)
MIN_SSR_MAX_ROUGHNESS :: f32(0.1)
MAX_SSR_MAX_ROUGHNESS :: f32(1)

SSR_FORMAT :: dxgi.FORMAT.R16G16B16A16_FLOAT

// The denoiser's targets: the traced rays' hit distances, the spatially
// filtered reflections, then two each of the history (color, confidence)
// and its meta (view depth, frames averaged, hit distance), written in turn.
REFLECTION_TARGET_HIT :: 0
REFLECTION_TARGET_FILTERED :: 1
REFLECTION_TARGET_HISTORY :: 2 // and 3
REFLECTION_TARGET_META :: 4    // and 5
REFLECTION_TARGET_COUNT :: 6
REFLECTION_HIT_FORMAT :: dxgi.FORMAT.R16_FLOAT
// RTVs: the surface buffer, the reflections, then the denoiser's targets.
REFLECTION_FIRST_RTV :: 2

// (Re)creates the surface buffer, the reflection target and the denoiser's
// targets. Called with the other screen-sized targets, at startup and on
// resize.
renderer_create_ssr_targets :: proc() {
    r := &g_renderer

    if r.ssr_rtv_heap == nil {
        heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = REFLECTION_FIRST_RTV + REFLECTION_TARGET_COUNT, Type = .RTV}
        dx_check(r.device->CreateDescriptorHeap(&heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&r.ssr_rtv_heap)))
    }

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.width),
        Height = r.height,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = SSR_FORMAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }
    // The surface buffer clears to roughness 1 (no reflection) where nothing draws.
    clear_values := [2]d3d12.CLEAR_VALUE{{Format = SSR_FORMAT}, {Format = SSR_FORMAT}}
    clear_values[0].Color = {0, 0, 0, 1}

    targets := [2]^^d3d12.IResource{&r.surface_texture, &r.ssr_texture}
    srvs := [2]u32{r.surface_srv_index, r.ssr_srv_index}
    for target, i in targets {
        dx_check(r.device->CreateCommittedResource(
            &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, &clear_values[i],
            d3d12.IResource_UUID, (^rawptr)(target),
        ))
        r.device->CreateRenderTargetView(target^, nil, renderer_ssr_rtv(i))
        renderer_write_srv(target^, SSR_FORMAT, srvs[i])
    }

    for &target, i in r.reflection_targets {
        format := REFLECTION_HIT_FORMAT if i == REFLECTION_TARGET_HIT else SSR_FORMAT
        desc.Format = format
        clear_value := d3d12.CLEAR_VALUE{Format = format}
        dx_check(r.device->CreateCommittedResource(
            &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, &clear_value,
            d3d12.IResource_UUID, (^rawptr)(&target),
        ))
        r.device->CreateRenderTargetView(target, nil, renderer_ssr_rtv(REFLECTION_FIRST_RTV + i))
        renderer_write_srv(target, format, r.reflection_srv_start + u32(i))
    }

    // The scene color and the reflection history from before the resize are gone.
    r.ssr_history_valid = false
    r.reflection_history_valid = false
}

renderer_release_ssr_targets :: proc() {
    r := &g_renderer
    r.surface_texture->Release()
    r.ssr_texture->Release()
    for target in r.reflection_targets do target->Release()
}

// 0: the surface buffer, 1: the reflections, then the denoiser's targets
// from REFLECTION_FIRST_RTV.
renderer_ssr_rtv :: proc(index: int) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    return descriptor_handle(g_renderer.ssr_rtv_heap, .RTV, u32(index))
}

// Whether this frame traces reflections: also needs last frame's image.
renderer_ssr_active :: proc() -> bool {
    r := &g_renderer
    return r.ssr_enabled && r.ssr_history_valid && !renderer_ray_reflections_active()
}

// Whether the lit pass gets reflections this frame, from rays or SSR.
renderer_reflections_active :: proc() -> bool {
    return renderer_ray_reflections_active() || renderer_ssr_active()
}

// Whether this frame's reflections go through the denoiser.
renderer_reflection_denoise_active :: proc() -> bool {
    return g_renderer.reflection_denoise && renderer_reflections_active()
}

// The SRV of the reflections the lit pass reads: the denoiser's history, or
// the traced reflections as they are.
renderer_reflection_srv :: proc() -> u32 {
    r := &g_renderer
    if renderer_reflection_denoise_active() {
        return r.reflection_srv_start + u32(REFLECTION_TARGET_HISTORY + r.reflection_current)
    }
    return r.ssr_srv_index
}

// Ray-traced or screen-space reflections into the reflection target (and
// their hit distances), then the denoiser. The lit pass blends the result
// over the probes' and environment's specular.
renderer_render_ssr :: proc() {
    r := &g_renderer

    renderer_begin_gpu_pass(.SSR)
    if renderer_ray_reflections_active() {
        renderer_render_ray_reflections()
    } else if renderer_ssr_active() {
        renderer_begin_reflection_targets()
        heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
        r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
        r.command_list->SetGraphicsRootSignature(r.root_signature)
        r.command_list->SetPipelineState(r.ssr_pipeline_state)
        renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())
        // Last frame's scene color: TAA's output or the HDR target, which
        // this frame's lit pass has not yet overwritten.
        renderer_bind_srv(.Texture_T0, r.scene_color_srv_index)
        renderer_bind_srv(.Surface, r.surface_srv_index)
        renderer_bind_srv(.Texture_T8, r.velocity_srv_index)
        renderer_bind_srv(.Depth, r.depth_srv_index)
        r.command_list->RSSetViewports(1, &r.viewport)
        r.command_list->RSSetScissorRects(1, &r.scissor_rect)
        r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
        r.command_list->DrawInstanced(3, 1, 0, 0)
        renderer_end_reflection_targets()
    }
    renderer_end_gpu_pass(.SSR)
    renderer_denoise_reflections()
}

// Makes the reflection target and the hit distances this pass's render targets.
@(private="file")
renderer_begin_reflection_targets :: proc() {
    r := &g_renderer
    hit := r.reflection_targets[REFLECTION_TARGET_HIT]
    barriers := [2]d3d12.RESOURCE_BARRIER{
        resource_transition(r.ssr_texture, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET}),
        resource_transition(hit, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET}),
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
    rtvs := [2]d3d12.CPU_DESCRIPTOR_HANDLE{renderer_ssr_rtv(1), renderer_ssr_rtv(REFLECTION_FIRST_RTV + REFLECTION_TARGET_HIT)}
    r.command_list->OMSetRenderTargets(len(rtvs), &rtvs[0], false, nil)
}

@(private="file")
renderer_end_reflection_targets :: proc() {
    r := &g_renderer
    hit := r.reflection_targets[REFLECTION_TARGET_HIT]
    barriers := [2]d3d12.RESOURCE_BARRIER{
        resource_transition(r.ssr_texture, {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE}),
        resource_transition(hit, {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE}),
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
}

// The denoiser: this frame's reflections filtered in space (PSReflectionFilter,
// into the filtered target), then averaged with last frame's history at the
// same surface (PSReflectionAccumulate, into the other history and meta).
// Both read the hit distances (t2) and last frame's meta (t1), along with the
// surface buffer, depth and motion vectors.
renderer_denoise_reflections :: proc() {
    r := &g_renderer
    renderer_begin_gpu_pass(.Reflection_Denoise)
    defer renderer_end_gpu_pass(.Reflection_Denoise)
    if !renderer_reflection_denoise_active() {
        // Kept only while every frame adds to it.
        r.reflection_history_valid = false
        return
    }
    previous := r.reflection_current
    r.reflection_current = 1 - previous
    srv :: proc(target: int) -> u32 {return g_renderer.reflection_srv_start + u32(target)}

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())
    renderer_bind_srv(.Surface, r.surface_srv_index)
    renderer_bind_srv(.Depth, r.depth_srv_index)
    renderer_bind_srv(.Texture_T8, r.velocity_srv_index)
    renderer_bind_srv(.Environment, srv(REFLECTION_TARGET_HIT))
    renderer_bind_srv(.Texture_T1, srv(REFLECTION_TARGET_META + previous))

    renderer_bind_srv(.Reflections, r.ssr_srv_index)
    renderer_reflection_fullscreen({REFLECTION_TARGET_FILTERED}, r.reflection_filter_pipeline_state)

    renderer_bind_srv(.Reflections, srv(REFLECTION_TARGET_FILTERED))
    renderer_bind_srv(.Texture_T0, srv(REFLECTION_TARGET_HISTORY + previous))
    current := r.reflection_current
    renderer_reflection_fullscreen(
        {REFLECTION_TARGET_HISTORY + current, REFLECTION_TARGET_META + current},
        r.reflection_accumulate_pipeline_state,
    )
    r.reflection_history_valid = true
}

// A full-screen draw into some of the denoiser's targets.
@(private="file")
renderer_reflection_fullscreen :: proc(targets: []int, pso: ^d3d12.IPipelineState) {
    r := &g_renderer
    barriers: [2]d3d12.RESOURCE_BARRIER
    rtvs: [2]d3d12.CPU_DESCRIPTOR_HANDLE
    for target, i in targets {
        barriers[i] = resource_transition(r.reflection_targets[target], {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET})
        rtvs[i] = renderer_ssr_rtv(REFLECTION_FIRST_RTV + target)
    }
    r.command_list->ResourceBarrier(u32(len(targets)), &barriers[0])
    r.command_list->OMSetRenderTargets(u32(len(targets)), &rtvs[0], false, nil)
    r.command_list->SetPipelineState(pso)
    r.command_list->DrawInstanced(3, 1, 0, 0)
    for target, i in targets {
        barriers[i] = resource_transition(r.reflection_targets[target], {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE})
    }
    r.command_list->ResourceBarrier(u32(len(targets)), &barriers[0])
}

// One reflected ray per pixel through the TLAS (PSRayReflections), shaded
// where it hits with what the lit pass binds: lights and their clusters,
// shadow maps, probes, volumes and the environment.
renderer_render_ray_reflections :: proc() {
    r := &g_renderer
    renderer_begin_reflection_targets()
    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.ray_reflection_pipeline_state)
    renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())
    renderer_bind_srv(.Surface, r.surface_srv_index)
    renderer_bind_srv(.Depth, r.depth_srv_index)
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
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)
    renderer_end_reflection_targets()
}
