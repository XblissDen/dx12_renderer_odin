package main

import d3d12 "vendor:directx/d3d12"

// Temporal anti-aliasing: each frame is rendered with a sub-pixel jitter and
// blended into a history reprojected with per-pixel motion. The resolve runs
// in HDR before bloom and tone mapping, which then read its output.

// Share of the new frame per blend; the rest is accumulated history.
TAA_BLEND :: f32(0.1)

// (Re)creates the velocity target and both history buffers. Called with the
// other screen-sized targets, at startup and on resize; the history restarts.
renderer_create_taa_targets :: proc() {
    r := &g_renderer

    if r.taa_rtv_heap == nil {
        heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = 2, Type = .RTV}
        dx_check(r.device->CreateDescriptorHeap(&heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&r.taa_rtv_heap)))
        heap_desc.NumDescriptors = 1
        dx_check(r.device->CreateDescriptorHeap(&heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&r.velocity_rtv_heap)))
    }

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.width),
        Height = r.height,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }
    clear_value := d3d12.CLEAR_VALUE{Format = .R16G16B16A16_FLOAT}

    rtv_increment := r.device->GetDescriptorHandleIncrementSize(.RTV)
    for i in 0..<2 {
        dx_check(r.device->CreateCommittedResource(
            &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, &clear_value,
            d3d12.IResource_UUID, (^rawptr)(&r.taa_history[i]),
        ))
        rtv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.taa_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
        rtv.ptr += uint(i) * uint(rtv_increment)
        r.device->CreateRenderTargetView(r.taa_history[i], nil, rtv)
        renderer_write_srv(r.taa_history[i], .R16G16B16A16_FLOAT, r.taa_srv_start + u32(i))
    }

    // Motion in UV units from last frame to this one; zero where nothing drew.
    desc.Format = .R16G16_FLOAT
    clear_value.Format = .R16G16_FLOAT
    dx_check(r.device->CreateCommittedResource(
        &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, &clear_value,
        d3d12.IResource_UUID, (^rawptr)(&r.velocity_texture),
    ))
    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.velocity_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    r.device->CreateRenderTargetView(r.velocity_texture, nil, rtv)
    renderer_write_srv(r.velocity_texture, .R16G16_FLOAT, r.velocity_srv_index)

    r.taa_history_valid = false
}

renderer_release_taa_targets :: proc() {
    r := &g_renderer
    for history in r.taa_history do history->Release()
    r.velocity_texture->Release()
}

renderer_velocity_rtv :: proc() -> d3d12.CPU_DESCRIPTOR_HANDLE {
    r := &g_renderer
    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.velocity_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    return rtv
}

// Blends the new HDR frame into the history and makes the result the scene
// color for bloom and tone mapping. Without TAA, the scene color is the HDR
// target itself.
renderer_render_taa :: proc() {
    r := &g_renderer
    r.scene_color_srv_index = r.hdr_srv_index
    renderer_begin_gpu_pass(.TAA)
    if r.post_anti_aliasing != .TAA {
        // Empty timestamps: every pass's queries are resolved each frame.
        renderer_end_gpu_pass(.TAA)
        return
    }

    write := r.taa_write_index
    read := 1 - write

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.taa_history[write],
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.taa_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    rtv.ptr += uint(write) * uint(r.device->GetDescriptorHandleIncrementSize(.RTV))
    r.command_list->OMSetRenderTargets(1, &rtv, false, nil)

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.taa_resolve_pipeline_state)
    renderer_bind_cbv(.Post_Constants, renderer_post_cb_address())
    renderer_bind_srv(.Texture_T0, r.hdr_srv_index)
    renderer_bind_srv(.Texture_T1, r.taa_srv_start + u32(read))
    renderer_bind_srv(.Texture_T8, r.velocity_srv_index)
    renderer_bind_srv(.Depth, r.depth_srv_index)
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)
    renderer_end_gpu_pass(.TAA)

    r.scene_color_srv_index = r.taa_srv_start + u32(write)
    r.taa_write_index = read
    r.taa_history_valid = true
}
