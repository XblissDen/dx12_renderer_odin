package main

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// Screen-space ambient occlusion: a depth prepass, an occlusion pass that
// samples the depth around each pixel, and a depth-aware blur. The lit pass
// then darkens only ambient (sky) light with the result.
AO_TARGET_COUNT :: 2 // [0] raw, [1] blurred
DEFAULT_AO_RADIUS :: f32(1.0)
DEFAULT_AO_INTENSITY :: f32(2.0)
MIN_AO_RADIUS :: f32(0.05)
MAX_AO_RADIUS :: f32(4)
MAX_AO_INTENSITY :: f32(4)

// (Re)creates the occlusion targets and the depth SRV. Called after the depth
// buffer is (re)created, at startup and on resize.
renderer_create_ssao_targets :: proc() {
    r := &g_renderer

    if r.ao_rtv_heap == nil {
        rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
            NumDescriptors = AO_TARGET_COUNT,
            Type = .RTV,
        }
        dx_check(r.device->CreateDescriptorHeap(
            &rtv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.ao_rtv_heap),
        ))
    }

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.width),
        Height = r.height,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .R8_UNORM,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }
    clear_value := d3d12.CLEAR_VALUE{Format = .R8_UNORM}
    clear_value.Color = {1, 1, 1, 1}

    rtv_increment := r.device->GetDescriptorHandleIncrementSize(.RTV)
    for i in 0..<AO_TARGET_COUNT {
        dx_check(r.device->CreateCommittedResource(
            &heap_props,
            {},
            &desc,
            {.PIXEL_SHADER_RESOURCE},
            &clear_value,
            d3d12.IResource_UUID,
            (^rawptr)(&r.ao_targets[i]),
        ))

        rtv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.ao_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
        rtv.ptr += uint(i) * uint(rtv_increment)
        r.device->CreateRenderTargetView(r.ao_targets[i], nil, rtv)

        renderer_write_srv(r.ao_targets[i], .R8_UNORM, r.ao_srv_start + u32(i))
    }

    renderer_write_srv(r.depth_buffer, .R32_FLOAT, r.depth_srv_index)
}

renderer_write_srv :: proc(resource: ^d3d12.IResource, format: dxgi.FORMAT, index: u32) {
    r := &g_renderer
    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = format,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = 1}

    srv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
    srv.ptr += uint(index) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(resource, &srv_desc, srv)
}

renderer_srv_gpu :: proc(index: u32) -> d3d12.GPU_DESCRIPTOR_HANDLE {
    r := &g_renderer
    handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&handle)
    handle.ptr += u64(index) * u64(r.srv_descriptor_size)
    return handle
}

renderer_render_depth_prepass :: proc(draw_meshes: []MeshHandle, draw_indices: []u32) {
    r := &g_renderer

    renderer_begin_gpu_pass(.Depth_Prepass)
    // Motion vectors for TAA come out of the same draw; zero where nothing draws.
    velocity_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    velocity_barrier.Transition = {
        pResource = r.velocity_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &velocity_barrier)

    dsv := renderer_depth_dsv(read_only = false)
    velocity_rtv := renderer_velocity_rtv()
    r.command_list->OMSetRenderTargets(1, &velocity_rtv, false, &dsv)
    r.command_list->ClearDepthStencilView(dsv, {.DEPTH}, 1.0, 0, 0, nil)
    zero := [4]f32{}
    r.command_list->ClearRenderTargetView(velocity_rtv, &zero, 0, nil)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.depth_prepass_pipeline_state)
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->SetGraphicsRootConstantBufferView(12, renderer_frame_cb_address())

    for draw_index in draw_indices {
        i := int(draw_index)
        assert(i >= 0 && i < len(draw_meshes))
        r.command_list->SetGraphicsRootConstantBufferView(0, renderer_object_cb_address(i))

        mesh_index := int(draw_meshes[i])
        assert(mesh_index > 0 && mesh_index < len(r.meshes))
        gpu_mesh := &r.meshes[mesh_index]
        r.command_list->IASetVertexBuffers(0, 1, &gpu_mesh.vertex_buffer_view)
        r.command_list->IASetIndexBuffer(&gpu_mesh.index_buffer_view)
        r.command_list->DrawIndexedInstanced(gpu_mesh.index_count, 1, 0, 0, 0)
    }

    // Read-only from here to the end of the frame: SSAO samples it and the
    // lit and selection passes test against it.
    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.depth_buffer,
        StateBefore = {.DEPTH_WRITE},
        StateAfter = {.DEPTH_READ, .PIXEL_SHADER_RESOURCE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    velocity_barrier.Transition.StateBefore = {.RENDER_TARGET}
    velocity_barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &velocity_barrier)
    renderer_end_gpu_pass(.Depth_Prepass)
}

renderer_render_ssao :: proc() {
    r := &g_renderer

    renderer_begin_gpu_pass(.SSAO)
    if r.ao_enabled {
        heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
        r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
        r.command_list->SetGraphicsRootSignature(r.root_signature)
        r.command_list->RSSetViewports(1, &r.viewport)
        r.command_list->RSSetScissorRects(1, &r.scissor_rect)
        r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
        r.command_list->SetGraphicsRootConstantBufferView(12, renderer_frame_cb_address())
        r.command_list->SetGraphicsRootDescriptorTable(15, renderer_srv_gpu(r.depth_srv_index))

        // Raw occlusion, then the blur reads it (t8) and writes the final map.
        renderer_ssao_fullscreen(0, r.ssao_pipeline_state)
        r.command_list->SetGraphicsRootDescriptorTable(14, renderer_srv_gpu(r.ao_srv_start))
        renderer_ssao_fullscreen(1, r.ssao_blur_pipeline_state)
    }
    renderer_end_gpu_pass(.SSAO)
}

renderer_ssao_fullscreen :: proc(target_index: int, pso: ^d3d12.IPipelineState) {
    r := &g_renderer
    target := r.ao_targets[target_index]

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = target,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.ao_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    rtv.ptr += uint(target_index) * uint(r.device->GetDescriptorHandleIncrementSize(.RTV))
    r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
    r.command_list->SetPipelineState(pso)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)
}
