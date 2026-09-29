package main

import d3d12 "vendor:directx/d3d12"

renderer_create_shadow_map :: proc() {
    r := &g_renderer

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    shadow_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = SHADOW_MAP_SIZE,
        Height = SHADOW_MAP_SIZE,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .R32_TYPELESS,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_DEPTH_STENCIL},
    }

    clear_value := d3d12.CLEAR_VALUE{Format = .D32_FLOAT}
    clear_value.DepthStencil = {Depth = 1.0, Stencil = 0}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &shadow_desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.shadow_map),
    ))

    dsv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = 1,
        Type = .DSV,
    }
    dx_check(r.device->CreateDescriptorHeap(
        &dsv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.shadow_dsv_heap),
    ))

    shadow_dsv := d3d12.DEPTH_STENCIL_VIEW_DESC{
        Format = .D32_FLOAT,
        ViewDimension = .TEXTURE2D,
    }
    dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.shadow_dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)
    r.device->CreateDepthStencilView(r.shadow_map, &shadow_dsv, dsv_handle)

    shadow_srv := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R32_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    shadow_srv.Texture2D = {MipLevels = 1}

    srv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv_handle)
    srv_handle.ptr += uint(SHADOW_SRV_INDEX) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(r.shadow_map, &shadow_srv, srv_handle)
}

renderer_render_shadow_pass :: proc(draw_meshes: []Mesh_Asset) {
    r := &g_renderer

    renderer_begin_gpu_pass(.Shadow)
    shadow_barrier := d3d12.RESOURCE_BARRIER {Type = .TRANSITION}
    shadow_barrier.Transition = {
        pResource = r.shadow_map,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.DEPTH_WRITE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &shadow_barrier)

    shadow_dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.shadow_dsv_heap->GetCPUDescriptorHandleForHeapStart(&shadow_dsv_handle)

    r.command_list->OMSetRenderTargets(0, nil, false, &shadow_dsv_handle)
    r.command_list->ClearDepthStencilView(
        shadow_dsv_handle, {.DEPTH}, 1.0, 0, 0, nil,
    )

    shadow_viewport := d3d12.VIEWPORT{
        Width = SHADOW_MAP_SIZE,
        Height = SHADOW_MAP_SIZE,
        MinDepth = 0,
        MaxDepth = 1,
    }

    shadow_scissor := d3d12.RECT{
        right = SHADOW_MAP_SIZE,
        bottom = SHADOW_MAP_SIZE,
    }

    r.command_list->RSSetViewports(1, &shadow_viewport)
    r.command_list->RSSetScissorRects(1, &shadow_scissor)
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.shadow_pipeline_state)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)

    for i in 0..<len(draw_meshes) {
        // Light-marker cubes are debugging visuals, not shadow casters.
        if r.cb_mapped_data[i].unlit != 0 {
            continue
        }

        cb_offset := u64(i) * u64(size_of(SceneConstants))
        r.command_list->SetGraphicsRootConstantBufferView(
            0,
            r.constant_buffer->GetGPUVirtualAddress() + cb_offset,
        )

        mesh_index := int(draw_meshes[i])
        assert(mesh_index >= 0 && mesh_index < MESH_COUNT)
        gpu_mesh := &r.meshes[mesh_index]

        r.command_list->IASetVertexBuffers(0, 1, &gpu_mesh.vertex_buffer_view)
        r.command_list->IASetIndexBuffer(&gpu_mesh.index_buffer_view)
        r.command_list->DrawIndexedInstanced(gpu_mesh.index_count, 1, 0, 0, 0)
    }

    shadow_barrier.Transition.StateBefore = {.DEPTH_WRITE}
    shadow_barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &shadow_barrier)

    renderer_end_gpu_pass(.Shadow)
}