package main

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// Screen-space reflections. The depth prepass also writes each pixel's
// view-space shading normal and roughness (the surface buffer); before the lit
// pass, a full-screen pass marches each reflected ray through the depth buffer
// and reads the surface it hits from last frame's HDR image. The lit pass
// blends that over the environment's specular by the hit's confidence. With
// TAA, rays spread over the specular lobe and the history averages them.
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

// (Re)creates the surface buffer and the reflection target. Called with the
// other screen-sized targets, at startup and on resize.
renderer_create_ssr_targets :: proc() {
    r := &g_renderer

    if r.ssr_rtv_heap == nil {
        heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = 2, Type = .RTV}
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

    // The scene color from before the resize is gone.
    r.ssr_history_valid = false
}

renderer_release_ssr_targets :: proc() {
    r := &g_renderer
    r.surface_texture->Release()
    r.ssr_texture->Release()
}

// 0: the surface buffer, 1: the reflections.
renderer_ssr_rtv :: proc(index: int) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    return descriptor_handle(g_renderer.ssr_rtv_heap, .RTV, u32(index))
}

// Whether this frame traces reflections: also needs last frame's image.
renderer_ssr_active :: proc() -> bool {
    r := &g_renderer
    return r.ssr_enabled && r.ssr_history_valid
}

renderer_render_ssr :: proc() {
    r := &g_renderer

    renderer_begin_gpu_pass(.SSR)
    if renderer_ssr_active() {
        barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
        barrier.Transition = {
            pResource = r.ssr_texture,
            StateBefore = {.PIXEL_SHADER_RESOURCE},
            StateAfter = {.RENDER_TARGET},
            Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
        }
        r.command_list->ResourceBarrier(1, &barrier)

        rtv := renderer_ssr_rtv(1)
        r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
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

        barrier.Transition.StateBefore = {.RENDER_TARGET}
        barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
        r.command_list->ResourceBarrier(1, &barrier)
    }
    renderer_end_gpu_pass(.SSR)
}
