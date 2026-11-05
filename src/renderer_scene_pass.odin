package main

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// Weighted blended order-independent transparency (McGuire and Bavoil,
// 2013). Each blended surface adds its premultiplied color and alpha, times
// a weight that falls with distance, into the accumulation target, and
// multiplies the revealage target (how much of the scene still shows) by
// 1 - alpha. The composite then lays the weighted average color over the lit
// image by 1 - revealage. Neither sum depends on the order surfaces arrive
// in. The accumulation is 32-bit float: weights reach 3000 and HDR
// highlights are bright, which would overflow half floats.
OIT_ACCUMULATION_FORMAT :: dxgi.FORMAT.R32G32B32A32_FLOAT
OIT_REVEALAGE_FORMAT :: dxgi.FORMAT.R16_FLOAT
// Nothing accumulated, everything revealed.
OIT_CLEAR_COLORS := [2][4]f32{{0, 0, 0, 0}, {1, 0, 0, 0}}

// (Re)creates the accumulation and revealage targets with the other
// screen-sized targets.
renderer_create_oit_targets :: proc() {
    r := &g_renderer
    if r.oit_rtv_heap == nil {
        heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = len(r.oit_targets), Type = .RTV}
        dx_check(r.device->CreateDescriptorHeap(&heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&r.oit_rtv_heap)))
    }
    formats := [2]dxgi.FORMAT{OIT_ACCUMULATION_FORMAT, OIT_REVEALAGE_FORMAT}
    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    for &target, i in r.oit_targets {
        desc := d3d12.RESOURCE_DESC{
            Dimension = .TEXTURE2D,
            Width = u64(r.width),
            Height = r.height,
            DepthOrArraySize = 1,
            MipLevels = 1,
            Format = formats[i],
            SampleDesc = {Count = 1},
            Flags = {.ALLOW_RENDER_TARGET},
        }
        clear_value := d3d12.CLEAR_VALUE{Format = formats[i]}
        clear_value.Color = OIT_CLEAR_COLORS[i]
        dx_check(r.device->CreateCommittedResource(
            &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, &clear_value,
            d3d12.IResource_UUID, (^rawptr)(&target),
        ))
        r.device->CreateRenderTargetView(target, nil, renderer_oit_rtv(i))
        renderer_write_srv(target, formats[i], r.oit_srv_start + u32(i))
    }
}

renderer_release_oit_targets :: proc() {
    for target in g_renderer.oit_targets do target->Release()
}

// 0: accumulation, 1: revealage.
renderer_oit_rtv :: proc(index: int) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    return descriptor_handle(g_renderer.oit_rtv_heap, .RTV, u32(index))
}

renderer_render_scene_pass :: proc(draws: []Draw, batches, late_batches, transparent_batches: []DrawBatch) {
    r := &g_renderer

    renderer_begin_gpu_pass(.Scene)
    hdr_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    hdr_barrier.Transition = {
        pResource = r.hdr_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &hdr_barrier)

    hdr_rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.hdr_rtv_heap->GetCPUDescriptorHandleForHeapStart(&hdr_rtv)

    // First fill the HDR target with the sky, without a depth buffer.
    renderer_begin_event("Sky")
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, nil)

    clear_color := [4]f32{0.1, 0.1, 0.2, 1.0}
    r.command_list->ClearRenderTargetView(hdr_rtv, &clear_color, 0, nil)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.sky_pipeline_state)

    sky_heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(sky_heaps))

    renderer_bind_cbv(.Sky_Constants, renderer_sky_cb_address())
    renderer_bind_srv(.Texture_T0, renderer_background_srv())

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)
    renderer_end_event()

    // Now draw scene geometry over the sky, testing against the prepass depth.
    renderer_begin_event("Opaque")
    dsv_handle := renderer_depth_dsv(read_only = true)
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, &dsv_handle)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    renderer_bind_srv(.Texture_T1, r.shadow_srv_index)
    renderer_bind_srv(.Shadow_Atlas, r.shadow_atlas_srv_index)
    renderer_bind_buffer_srv(.Shadow_Tiles, renderer_shadow_tile_address())
    renderer_bind_srv(.Irradiance, r.irradiance_srv_index)
    renderer_bind_srv(.Prefiltered, r.prefilter_srv_index)
    // Blurred ambient occlusion (ignored by the shader while disabled).
    renderer_bind_srv(.Texture_T8, renderer_ao_srv())
    // Reflections, denoised or not (likewise ignored while off).
    renderer_bind_srv(.Reflections, renderer_reflection_srv())

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())
    renderer_bind_buffer_srv(.Lights, renderer_light_buffer_address())
    renderer_bind_buffer_srv(.Cluster_Lights, r.cluster_buffer->GetGPUVirtualAddress())
    renderer_bind_probes()
    renderer_bind_ray_tracing()

    // The prepass's early and late calls.
    renderer_draw_batches(draws, batches, r.hdr_pipeline_states)
    renderer_draw_batches(draws, late_batches, r.hdr_pipeline_states)
    renderer_end_event()

    // Blended surfaces, order-independent: they accumulate into their own
    // targets, then one full-screen pass composites them over the result.
    // They also write their motion into the prepass's velocity target where
    // they are mostly opaque, so TAA follows moving glass instead of what is
    // behind it.
    if len(transparent_batches) > 0 {
        renderer_begin_event("Blended")
        defer renderer_end_event()
        barriers := [3]d3d12.RESOURCE_BARRIER{
            resource_transition(r.oit_targets[0], {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET}),
            resource_transition(r.oit_targets[1], {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET}),
            resource_transition(r.velocity_texture, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET}),
        }
        r.command_list->ResourceBarrier(len(barriers), &barriers[0])
        rtvs := [3]d3d12.CPU_DESCRIPTOR_HANDLE{renderer_oit_rtv(0), renderer_oit_rtv(1), renderer_velocity_rtv()}
        for target, i in OIT_CLEAR_COLORS {
            clear := target
            r.command_list->ClearRenderTargetView(rtvs[i], &clear, 0, nil)
        }
        r.command_list->OMSetRenderTargets(len(rtvs), &rtvs[0], false, &dsv_handle)

        // One draw per call, sorted back to front (renderer_batch_draws
        // without merging): the colors do not depend on the order, but the
        // motion of the nearest mostly-opaque surface, drawn last, wins.
        // Culled calls draw no instances.
        renderer_bind_objects()
        for batch in transparent_batches {
            variant := draws[batch.draw].variant
            double_sided := variant == .Double_Sided || variant == .Masked_Double_Sided
            r.command_list->SetPipelineState(r.transparent_pipeline_states[int(double_sided)])
            renderer_execute_draws(batch.command, 1)
        }

        for &barrier in barriers {
            barrier.Transition.StateBefore = {.RENDER_TARGET}
            barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
        }
        r.command_list->ResourceBarrier(len(barriers), &barriers[0])

        r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, nil)
        r.command_list->SetPipelineState(r.oit_composite_pipeline_state)
        renderer_bind_srv(.Texture_T0, r.oit_srv_start)
        renderer_bind_srv(.Texture_T1, r.oit_srv_start + 1)
        r.command_list->DrawInstanced(3, 1, 0, 0)
    }

    // Fog over everything, glass included (at the depth behind the glass).
    renderer_begin_event("Fog")
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, nil)
    renderer_apply_fog()
    renderer_end_event()

    hdr_barrier.Transition.StateBefore = {.RENDER_TARGET}
    hdr_barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &hdr_barrier)

    renderer_end_gpu_pass(.Scene)
}

renderer_render_post_process :: proc(scene: ^Scene) {
    r := &g_renderer

    renderer_begin_gpu_pass(.Post_Process)
    back_buffer_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    back_buffer_barrier.Transition = {
        pResource = r.render_targets[r.frame_index],
        StateBefore = d3d12.RESOURCE_STATE_PRESENT,
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &back_buffer_barrier)

    rtv_handle := descriptor_handle(r.rtv_heap, .RTV, r.frame_index)

    // With FXAA, or sharpening after TAA, tone mapping writes an intermediate
    // image that that pass then filters into the back buffer; otherwise it
    // writes the back buffer directly.
    fxaa := r.post_anti_aliasing == .FXAA
    sharpen := r.post_anti_aliasing == .TAA && r.post_sharpness > 0
    final_pass := fxaa || sharpen
    ldr_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    ldr_barrier.Transition = {
        pResource = r.ldr_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    tone_map_rtv := rtv_handle
    if final_pass {
        r.command_list->ResourceBarrier(1, &ldr_barrier)
        r.ldr_rtv_heap->GetCPUDescriptorHandleForHeapStart(&tone_map_rtv)
    }

    renderer_begin_event("Tone mapping")
    r.command_list->OMSetRenderTargets(1, &tone_map_rtv, false, nil)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    renderer_bind_cbv(.Post_Constants, renderer_post_cb_address())
    renderer_bind_buffer_srv(.Exposure_Buffer, r.exposure_buffer->GetGPUVirtualAddress())
    r.command_list->SetPipelineState(r.post_pipeline_state)
    // "Show reflections only" tone maps the reflections the lit pass used
    // instead: denoised, or this frame's raw ones (before TAA, so stochastic
    // rays show their noise). It must not replace the scene color, which next
    // frame's SSR reflects.
    show_reflections := r.ssr_show && renderer_reflections_active()
    renderer_bind_srv(.Texture_T0, renderer_reflection_srv() if show_reflections else r.scene_color_srv_index)
    renderer_bind_srv(.Texture_T1, r.bloom_srv_start)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)
    renderer_end_event()

    if final_pass {
        ldr_barrier.Transition.StateBefore = {.RENDER_TARGET}
        ldr_barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
        r.command_list->ResourceBarrier(1, &ldr_barrier)

        renderer_begin_gpu_pass(.FXAA)
        r.command_list->OMSetRenderTargets(1, &rtv_handle, false, nil)
        r.command_list->SetPipelineState(r.fxaa_pipeline_state if fxaa else r.sharpen_pipeline_state)
        renderer_bind_srv(.Texture_T0, r.ldr_srv_index)
        r.command_list->DrawInstanced(3, 1, 0, 0)
        renderer_end_gpu_pass(.FXAA)
    } else {
        // Empty timestamps: every pass's queries are resolved each frame.
        renderer_begin_gpu_pass(.FXAA)
        renderer_end_gpu_pass(.FXAA)
    }

    // Debug lines, the outline and the UI draw after anti-aliasing, so they
    // stay crisp.
    renderer_begin_event("Debug lines")
    renderer_render_debug_lines(scene, rtv_handle)
    renderer_end_event()
    renderer_begin_event("Selection outline")
    renderer_render_selection(scene, rtv_handle)
    renderer_end_event()
    renderer_begin_event("UI")
    r.command_list->OMSetRenderTargets(1, &rtv_handle, false, nil)
    debug_ui_render()
    renderer_end_event()

    back_buffer_barrier.Transition.StateBefore = {.RENDER_TARGET}
    back_buffer_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT
    r.command_list->ResourceBarrier(1, &back_buffer_barrier)

    renderer_end_gpu_pass(.Post_Process)
}
