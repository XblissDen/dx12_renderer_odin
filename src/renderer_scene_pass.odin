package main

import d3d12 "vendor:directx/d3d12"

renderer_render_scene_pass :: proc(draws: []Draw, draw_indices, transparent_indices: []u32) {
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
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, nil)

    clear_color := [4]f32{0.1, 0.1, 0.2, 1.0}
    r.command_list->ClearRenderTargetView(hdr_rtv, &clear_color, 0, nil)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.sky_pipeline_state)

    sky_heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(sky_heaps))

    renderer_bind_cbv(.Sky_Constants, renderer_sky_cb_address())
    renderer_bind_srv(.Texture_T0, r.environment_srv_index)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    // Now draw scene geometry over the sky, testing against the prepass depth.
    dsv_handle := renderer_depth_dsv(read_only = true)
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, &dsv_handle)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    renderer_bind_srv(.Texture_T1, r.shadow_srv_index)
    renderer_bind_srv(.Spot_Shadows, r.spot_shadow_srv_index)
    renderer_bind_srv(.Point_Shadows, r.point_shadow_srv_index)
    renderer_bind_srv(.Irradiance, r.irradiance_srv_index)
    renderer_bind_srv(.Prefiltered, r.prefilter_srv_index)
    // Blurred ambient occlusion (ignored by the shader while disabled).
    renderer_bind_srv(.Texture_T8, r.ao_srv_start + 1)
    // Screen-space reflections (likewise ignored while off).
    renderer_bind_srv(.Reflections, r.ssr_srv_index)

    // viewport, scissor
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)

    // Geometry
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())
    renderer_bind_buffer_srv(.Lights, renderer_light_buffer_address())
    renderer_bind_buffer_srv(.Cluster_Lights, r.cluster_buffer->GetGPUVirtualAddress())

    renderer_draw_list(draws, draw_indices, r.hdr_pipeline_states)

    // Blended surfaces over the result, farthest first. They also write their
    // motion into the prepass's velocity target where they are mostly
    // opaque, so TAA follows moving glass instead of what is behind it.
    if len(transparent_indices) > 0 {
        velocity_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
        velocity_barrier.Transition = {
            pResource = r.velocity_texture,
            StateBefore = {.PIXEL_SHADER_RESOURCE},
            StateAfter = {.RENDER_TARGET},
            Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
        }
        r.command_list->ResourceBarrier(1, &velocity_barrier)
        rtvs := [2]d3d12.CPU_DESCRIPTOR_HANDLE{hdr_rtv, renderer_velocity_rtv()}
        r.command_list->OMSetRenderTargets(len(rtvs), &rtvs[0], false, &dsv_handle)

        for draw_index in transparent_indices {
            draw := &draws[draw_index]
            r.command_list->SetGraphicsRootDescriptorTable(u32(Root_Slot.Material), draw.material_table)
            if draw.variant == .Double_Sided || draw.variant == .Masked_Double_Sided {
                r.command_list->SetPipelineState(r.transparent_back_pipeline_state)
                renderer_draw(draws, draw_index)
            }
            r.command_list->SetPipelineState(r.transparent_front_pipeline_state)
            renderer_draw(draws, draw_index)
        }

        velocity_barrier.Transition.StateBefore = {.RENDER_TARGET}
        velocity_barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
        r.command_list->ResourceBarrier(1, &velocity_barrier)
    }

    // Fog over everything, glass included (at the depth behind the glass).
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, nil)
    renderer_apply_fog()

    // Scene render target becomes a shader input.
    hdr_barrier.Transition.StateBefore = {.RENDER_TARGET}
    hdr_barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &hdr_barrier)

    renderer_end_gpu_pass(.Scene)
}

renderer_render_post_process :: proc(scene: ^Scene) {
    r := &g_renderer

    renderer_begin_gpu_pass(.Post_Process)
    // Now acquire the swap-chain back buffer for the post-process pass.
    back_buffer_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    back_buffer_barrier.Transition = {
        pResource = r.render_targets[r.frame_index],
        StateBefore = d3d12.RESOURCE_STATE_PRESENT,
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &back_buffer_barrier)

    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)
    rtv_handle.ptr += uint(r.frame_index * r.rtv_descriptor_size)

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

    r.command_list->OMSetRenderTargets(1, &tone_map_rtv, false, nil)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    renderer_bind_cbv(.Post_Constants, renderer_post_cb_address())
    renderer_bind_buffer_srv(.Exposure_Buffer, r.exposure_buffer->GetGPUVirtualAddress())
    r.command_list->SetPipelineState(r.post_pipeline_state)
    // "Show reflections only" tone maps this frame's raw SSR output instead
    // (before TAA, so stochastic rays show their noise). It must not replace
    // the scene color, which next frame's SSR reflects.
    show_reflections := r.ssr_show && renderer_ssr_active()
    renderer_bind_srv(.Texture_T0, r.ssr_srv_index if show_reflections else r.scene_color_srv_index)
    renderer_bind_srv(.Texture_T1, r.bloom_srv_start)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

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

    // The outline and UI draw after anti-aliasing, so text stays crisp.
    renderer_render_selection(scene)
    r.command_list->OMSetRenderTargets(1, &rtv_handle, false, nil)

    debug_ui_render()

    // Presentable again.
    back_buffer_barrier.Transition.StateBefore = {.RENDER_TARGET}
    back_buffer_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT
    r.command_list->ResourceBarrier(1, &back_buffer_barrier)

    renderer_end_gpu_pass(.Post_Process)
}
