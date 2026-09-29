package main

import d3d12 "vendor:directx/d3d12"

renderer_render_scene_pass :: proc(
    draw_meshes: []Mesh_Asset,
    draw_textures: []Texture_Asset,
) {
    r := &g_renderer
    assert(len(draw_meshes) == len(draw_textures))

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
        r.sky_constant_buffer->GetGPUVirtualAddress(),
    )

    sky_srv: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&sky_srv)
    sky_srv.ptr += u64(ENVIRONMENT_SRV_INDEX) *
                u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(1, sky_srv)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    // Now draw scene geometry over the sky, with depth enabled.
    dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)
    r.command_list->OMSetRenderTargets(1, &hdr_rtv, false, &dsv_handle)
    r.command_list->ClearDepthStencilView(
        dsv_handle, {.DEPTH}, 1.0, 0, 0, nil,
    )

    // Pipeline
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.hdr_pipeline_state)

    // heap + texture bind
    heaps := []^d3d12.IDescriptorHeap{ r.srv_heap }
    r.command_list->SetDescriptorHeaps(u32(len(heaps)), raw_data(heaps))

    shadow_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&shadow_gpu_handle)
    shadow_gpu_handle.ptr += u64(SHADOW_SRV_INDEX) * u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(2, shadow_gpu_handle)

    irradiance_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&irradiance_gpu_handle)
    irradiance_gpu_handle.ptr += u64(IRRADIANCE_SRV_INDEX) *
                                u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(6, irradiance_gpu_handle)

    prefilter_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&prefilter_gpu_handle)
    prefilter_gpu_handle.ptr += u64(PREFILTER_SRV_INDEX) *
                                u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(8, prefilter_gpu_handle)

    // viewport, scissor
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)

    // Geometry
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    
    //r.command_list->DrawInstanced(3, 1, 0, 0)
    for i in 0..<len(draw_meshes){
        cb_offset := u64(i) * u64(size_of(SceneConstants))

        r.command_list->SetGraphicsRootConstantBufferView(
            0,
            r.constant_buffer->GetGPUVirtualAddress() + cb_offset,
        )

        texture_index := int(draw_textures[i])
        assert(texture_index >= 0 && texture_index < TEXTURE_COUNT)

        srv_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
        r.srv_heap->GetGPUDescriptorHandleForHeapStart(&srv_gpu_handle)
        srv_gpu_handle.ptr += u64(texture_index) * u64(r.srv_descriptor_size)

        r.command_list->SetGraphicsRootDescriptorTable(1, srv_gpu_handle)

        mesh_index := int(draw_meshes[i])
        assert(mesh_index >= 0 && mesh_index < MESH_COUNT)

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

renderer_render_post_process :: proc() {
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
        r.post_constant_buffer->GetGPUVirtualAddress(),
    )
    r.command_list->SetPipelineState(r.post_pipeline_state)

    hdr_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&hdr_gpu_handle)
    hdr_gpu_handle.ptr += u64(HDR_SRV_INDEX) * u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(1, hdr_gpu_handle)

    bloom_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&bloom_gpu_handle)
    bloom_gpu_handle.ptr += u64(BLOOM_SRV_START) *
                            u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(2, bloom_gpu_handle)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    // Presentable again.
    back_buffer_barrier.Transition.StateBefore = {.RENDER_TARGET}
    back_buffer_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT
    r.command_list->ResourceBarrier(1, &back_buffer_barrier)

    renderer_end_gpu_pass(.Post_Process)
}