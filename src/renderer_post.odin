package main

import "core:fmt"
import win32 "core:sys/windows"
import d3d12 "vendor:directx/d3d12"

renderer_create_hdr_target :: proc() {
    r := &g_renderer

    if r.hdr_rtv_heap == nil {
        rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
            NumDescriptors = 1,
            Type = .RTV,
        }
        dx_check(r.device->CreateDescriptorHeap(
            &rtv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.hdr_rtv_heap),
        ))
    }

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    hdr_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.width),
        Height = r.height,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }

    clear_value := d3d12.CLEAR_VALUE{
        Format = .R16G16B16A16_FLOAT,
    }
    clear_value.Color = {0.1, 0.1, 0.2, 1.0}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &hdr_desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.hdr_texture),
    ))

    hdr_rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.hdr_rtv_heap->GetCPUDescriptorHandleForHeapStart(&hdr_rtv)
    r.device->CreateRenderTargetView(r.hdr_texture, nil, hdr_rtv)

    hdr_srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R16G16B16A16_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    hdr_srv_desc.Texture2D = {MipLevels = 1}

    hdr_srv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&hdr_srv)
    hdr_srv.ptr += uint(HDR_SRV_INDEX) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(r.hdr_texture, &hdr_srv_desc, hdr_srv)
}

renderer_create_bloom_targets :: proc() {
    r := &g_renderer

    if r.bloom_rtv_heap == nil {
        rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
            NumDescriptors = BLOOM_TARGET_COUNT,
            Type = .RTV,
        }
        dx_check(r.device->CreateDescriptorHeap(
            &rtv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.bloom_rtv_heap),
        ))
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

    clear_value := d3d12.CLEAR_VALUE{
        Format = .R16G16B16A16_FLOAT,
    }
    clear_value.Color = {0, 0, 0, 1}

    rtv_increment := r.device->GetDescriptorHandleIncrementSize(.RTV)

    for i in 0..<BLOOM_TARGET_COUNT {
        dx_check(r.device->CreateCommittedResource(
            &heap_props,
            {},
            &desc,
            {.PIXEL_SHADER_RESOURCE},
            &clear_value,
            d3d12.IResource_UUID,
            (^rawptr)(&r.bloom_targets[i]),
        ))

        rtv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.bloom_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
        rtv.ptr += uint(i) * uint(rtv_increment)
        r.device->CreateRenderTargetView(r.bloom_targets[i], nil, rtv)

        srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
            Format = .R16G16B16A16_FLOAT,
            ViewDimension = .TEXTURE2D,
            Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        }
        srv_desc.Texture2D = {MipLevels = 1}

        srv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
        srv.ptr += uint(BLOOM_SRV_START + i) *
                   uint(r.srv_descriptor_size)
        r.device->CreateShaderResourceView(r.bloom_targets[i], &srv_desc, srv)
    }
}

renderer_bloom_pass :: proc(
    target_index: int,
    source_srv_index: int,
    pso: ^d3d12.IPipelineState,
) {
    r := &g_renderer
    assert(target_index >= 0 && target_index < BLOOM_TARGET_COUNT)

    target := r.bloom_targets[target_index]

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = target,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.bloom_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    rtv_increment := r.device->GetDescriptorHandleIncrementSize(.RTV)
    rtv.ptr += uint(target_index) * uint(rtv_increment)

    r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetGraphicsRootConstantBufferView(
        3,
        r.post_constant_buffer->GetGPUVirtualAddress(),
    )
    r.command_list->SetPipelineState(pso)

    source: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&source)
    source.ptr += u64(source_srv_index) * u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(1, source)

    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)
}

renderer_update_post_title :: proc() {
    r := &g_renderer

    bloom_ms := r.gpu_pass_ms[2] +
                r.gpu_pass_ms[3] +
                r.gpu_pass_ms[4]

    title := fmt.tprintf(
        "DX12 | FPS %.0f Frame %.1f ms | GPU shadow %.2f scene %.2f bloom %.2f post %.2f ms | E %.1f T %.1f B %.1f [1-6]",
        r.fps,
        r.frame_ms,
        r.gpu_pass_ms[0],
        r.gpu_pass_ms[1],
        bloom_ms,
        r.gpu_pass_ms[5],
        r.post_exposure,
        r.post_threshold,
        r.post_strength,
    )
    win32.SetWindowTextW(g_hwnd, win32.utf8_to_wstring(title))
}

renderer_apply_post_steps :: proc(
    exposure_steps, threshold_steps, bloom_steps: i32,
) {
    if exposure_steps == 0 && threshold_steps == 0 && bloom_steps == 0 {
        return
    }

    r := &g_renderer
    r.post_exposure = clamp(r.post_exposure + f32(exposure_steps) * 0.1, 0.1, 5.0)
    r.post_threshold = clamp(r.post_threshold + f32(threshold_steps) * 0.1, 0.1, 5.0)
    r.post_strength = clamp(r.post_strength + f32(bloom_steps) * 0.1, 0.0, 2.0)

    renderer_update_post_title()
}

renderer_render_bloom :: proc() {
    r := &g_renderer

    renderer_begin_gpu_pass(.Bloom_Extract)
    // HDR -> bright areas in bloom target 0.
    renderer_bloom_pass(
        0, HDR_SRV_INDEX, r.bloom_pipeline_states[0],
    )
    renderer_end_gpu_pass(.Bloom_Extract)

    // Target 0 -> horizontal blur in target 1.
    renderer_begin_gpu_pass(.Bloom_Horizontal)
    renderer_bloom_pass(
        1, BLOOM_SRV_START, r.bloom_pipeline_states[1],
    )
    renderer_end_gpu_pass(.Bloom_Horizontal)

    // Target 1 -> vertical blur back in target 0.
    renderer_begin_gpu_pass(.Bloom_Vertical)
    renderer_bloom_pass(
        0, BLOOM_SRV_START + 1, r.bloom_pipeline_states[2],
    )
    renderer_end_gpu_pass(.Bloom_Vertical)
}