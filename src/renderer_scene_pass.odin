package main

import d3d12 "vendor:directx/d3d12"

renderer_render_scene_pass :: proc(
    draw_meshes: []MeshHandle,
    draw_textures: []TextureHandle,
    draw_normals: []TextureHandle,
    draw_roughness: []TextureHandle,
    draw_metallic: []TextureHandle,
    draw_indices: []u32,
) {
    r := &g_renderer
    assert(len(draw_meshes) == len(draw_textures))
    assert(len(draw_meshes) == len(draw_normals))
    assert(len(draw_meshes) == len(draw_roughness))
    assert(len(draw_meshes) == len(draw_metallic))

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

    r.command_list->SetGraphicsRootConstantBufferView(
        4,
        renderer_sky_cb_address(),
    )

    sky_srv: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&sky_srv)
    sky_srv.ptr += u64(r.environment_srv_index) *
                u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(1, sky_srv)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    // Now draw scene geometry over the sky, testing against the prepass depth.
    dsv_handle := renderer_depth_dsv(read_only = true)
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, &dsv_handle)

    // Pipeline
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.hdr_pipeline_state)

    // heap + texture bind
    heaps := []^d3d12.IDescriptorHeap{ r.srv_heap }
    r.command_list->SetDescriptorHeaps(u32(len(heaps)), raw_data(heaps))

    shadow_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&shadow_gpu_handle)
    shadow_gpu_handle.ptr += u64(r.shadow_srv_index) * u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(2, shadow_gpu_handle)

    irradiance_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&irradiance_gpu_handle)
    irradiance_gpu_handle.ptr += u64(r.irradiance_srv_index) *
                                u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(6, irradiance_gpu_handle)

    prefilter_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&prefilter_gpu_handle)
    prefilter_gpu_handle.ptr += u64(r.prefilter_srv_index) *
                                u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(8, prefilter_gpu_handle)

    // Blurred ambient occlusion (ignored by the shader while disabled).
    r.command_list->SetGraphicsRootDescriptorTable(14, renderer_srv_gpu(r.ao_srv_start + 1))

    // viewport, scissor
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)

    // Geometry
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->SetGraphicsRootConstantBufferView(
        12,
        renderer_frame_cb_address(),
    )

    for draw_index in draw_indices{
        i := int(draw_index)
        assert(i >= 0 && i < len(draw_meshes))

        r.command_list->SetGraphicsRootConstantBufferView(
            0,
            renderer_object_cb_address(i),
        )

        srv_gpu_handle := renderer_texture_srv(draw_textures[i])

        r.command_list->SetGraphicsRootDescriptorTable(1, srv_gpu_handle)

        normal_gpu_handle := renderer_texture_srv(draw_normals[i])

        r.command_list->SetGraphicsRootDescriptorTable(9, normal_gpu_handle)

        roughness_gpu_handle := renderer_texture_srv(draw_roughness[i])

        r.command_list->SetGraphicsRootDescriptorTable(10, roughness_gpu_handle)

        metallic_gpu_handle := renderer_texture_srv(draw_metallic[i])

        r.command_list->SetGraphicsRootDescriptorTable(
            11, metallic_gpu_handle,
        )

        mesh_index := int(draw_meshes[i])
        assert(mesh_index > 0 && mesh_index < len(r.meshes))

        gpu_mesh := &r.meshes[mesh_index]
        r.command_list->IASetVertexBuffers(0, 1, &gpu_mesh.vertex_buffer_view)
        r.command_list->IASetIndexBuffer(&gpu_mesh.index_buffer_view)
        r.command_list->DrawIndexedInstanced(gpu_mesh.index_count, 1, 0, 0, 0)
    }

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

    r.command_list->OMSetRenderTargets(1, &rtv_handle, false, nil)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetGraphicsRootConstantBufferView(
        3,
        renderer_post_cb_address(),
    )
    r.command_list->SetPipelineState(r.post_pipeline_state)

    hdr_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&hdr_gpu_handle)
    hdr_gpu_handle.ptr += u64(r.hdr_srv_index) * u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(1, hdr_gpu_handle)

    bloom_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&bloom_gpu_handle)
    bloom_gpu_handle.ptr += u64(r.bloom_srv_start) *
                            u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(2, bloom_gpu_handle)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    renderer_render_selection(scene)
    r.command_list->OMSetRenderTargets(1, &rtv_handle, false, nil)

    debug_ui_render()

    // Presentable again.
    back_buffer_barrier.Transition.StateBefore = {.RENDER_TARGET}
    back_buffer_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT
    r.command_list->ResourceBarrier(1, &back_buffer_barrier)

    renderer_end_gpu_pass(.Post_Process)
}
