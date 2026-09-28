package main

import c "core:c"
import "core:fmt"
import d3d12 "vendor:directx/d3d12"
import stbi "vendor:stb/image"

renderer_load_environment :: proc() {
    r := &g_renderer

    width, height, channels: c.int
    pixels := stbi.loadf(
        "textures/environment_4k_2.hdr",
        &width, &height, &channels,
        4, // Request RGBA floats.
    )
    if pixels == nil {
        fmt.panicf("Failed to load environment HDR: %s",
            stbi.failure_reason())
    }
    defer stbi.image_free(rawptr(pixels))

    texture_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(width),
        Height = u32(height),
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
    }
    default_heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}

    dx_check(r.device->CreateCommittedResource(
        &default_heap,
        {},
        &texture_desc,
        {.COPY_DEST},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.environment_texture),
    ))

    // RGBA16F = 8 bytes per pixel; texture-copy rows require 256-byte alignment.
    row_pitch := (u64(width) * 8 + 255) & ~u64(255)
    upload_size := row_pitch * u64(height)

    upload_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = upload_size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }
    upload_heap := d3d12.HEAP_PROPERTIES{Type = .UPLOAD}

    upload_buffer: ^d3d12.IResource
    dx_check(r.device->CreateCommittedResource(
        &upload_heap,
        {},
        &upload_desc,
        {.VERTEX_AND_CONSTANT_BUFFER},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&upload_buffer),
    ))
    defer upload_buffer->Release()

    mapped: rawptr
    dx_check(upload_buffer->Map(0, nil, &mapped))

    for y in 0..<int(height) {
        row_address := uintptr(mapped) + uintptr(u64(y) * row_pitch)
        dst_row := ([^]f16)(rawptr(row_address))

        for x in 0..<int(width) {
            for channel in 0..<4 {
                pixel_index := (y * int(width) + x) * 4 + channel
                dst_row[x * 4 + channel] = f16(
                    clamp(pixels[pixel_index], 0.0, 65504.0)
                )
            }
        }
    }
    upload_buffer->Unmap(0, nil)

    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))

    source := d3d12.TEXTURE_COPY_LOCATION{
        pResource = upload_buffer,
        Type = .PLACED_FOOTPRINT,
    }
    source.PlacedFootprint = {
        Footprint = {
            Format = .R16G16B16A16_FLOAT,
            Width = u32(width),
            Height = u32(height),
            Depth = 1,
            RowPitch = u32(row_pitch),
        },
    }

    destination := d3d12.TEXTURE_COPY_LOCATION{
        pResource = r.environment_texture,
        Type = .SUBRESOURCE_INDEX,
        SubresourceIndex = 0,
    }

    r.command_list->CopyTextureRegion(
        &destination, 0, 0, 0, &source, nil,
    )

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.environment_texture,
        StateBefore = {.COPY_DEST},
        StateAfter = {.PIXEL_SHADER_RESOURCE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R16G16B16A16_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = 1}

    srv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
    srv.ptr += uint(ENVIRONMENT_SRV_INDEX) *
               uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(
        r.environment_texture, &srv_desc, srv,
    )
}

renderer_create_irradiance_map :: proc() {
    r := &g_renderer

    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = 1,
        Type = .RTV,
    }
    dx_check(r.device->CreateDescriptorHeap(
        &rtv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.irradiance_rtv_heap),
    ))

    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = IRRADIANCE_WIDTH,
        Height = IRRADIANCE_HEIGHT,
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
    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.irradiance_texture),
    ))

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.irradiance_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    r.device->CreateRenderTargetView(r.irradiance_texture, nil, rtv)

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R16G16B16A16_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = 1}

    srv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
    srv.ptr += uint(IRRADIANCE_SRV_INDEX) *
               uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(r.irradiance_texture, &srv_desc, srv)
}

renderer_generate_irradiance :: proc() {
    r := &g_renderer

    // The environment upload has completed before this procedure runs.
    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.irradiance_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.irradiance_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    r.command_list->OMSetRenderTargets(1, &rtv, false, nil)

    viewport := d3d12.VIEWPORT{
        Width = IRRADIANCE_WIDTH,
        Height = IRRADIANCE_HEIGHT,
        MinDepth = 0,
        MaxDepth = 1,
    }
    scissor := d3d12.RECT{
        right = IRRADIANCE_WIDTH,
        bottom = IRRADIANCE_HEIGHT,
    }
    r.command_list->RSSetViewports(1, &viewport)
    r.command_list->RSSetScissorRects(1, &scissor)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.irradiance_pipeline_state)

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))

    environment_srv: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&environment_srv)
    environment_srv.ptr += u64(ENVIRONMENT_SRV_INDEX) *
                           u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(5, environment_srv)

    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)

    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()
}

// create the mipmapped texture
renderer_create_prefiltered_environment :: proc() {
    r := &g_renderer

    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = PREFILTER_MIP_COUNT,
        Type = .RTV,
    }
    dx_check(r.device->CreateDescriptorHeap(
        &rtv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.prefilter_rtv_heap),
    ))

    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = PREFILTER_WIDTH,
        Height = PREFILTER_HEIGHT,
        DepthOrArraySize = 1,
        MipLevels = PREFILTER_MIP_COUNT,
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }

    clear_value := d3d12.CLEAR_VALUE{
        Format = .R16G16B16A16_FLOAT,
    }
    clear_value.Color = {0, 0, 0, 1}
    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.prefilter_texture),
    ))

    rtv_increment := r.device->GetDescriptorHandleIncrementSize(.RTV)
    for mip in 0..<PREFILTER_MIP_COUNT {
        rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC{
            Format = .R16G16B16A16_FLOAT,
            ViewDimension = .TEXTURE2D,
        }
        rtv_desc.Texture2D = {MipSlice = u32(mip)}

        rtv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.prefilter_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
        rtv.ptr += uint(mip) * uint(rtv_increment)
        r.device->CreateRenderTargetView(r.prefilter_texture, &rtv_desc, rtv)
    }

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R16G16B16A16_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = PREFILTER_MIP_COUNT}

    srv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
    srv.ptr += uint(PREFILTER_SRV_INDEX) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(r.prefilter_texture, &srv_desc, srv)

    // One 256-byte constant-buffer slot for each mip's roughness.
    cb_heap := d3d12.HEAP_PROPERTIES{Type = .UPLOAD}
    cb_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = u64(size_of(PrefilterConstants) * PREFILTER_MIP_COUNT),
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }

    dx_check(r.device->CreateCommittedResource(
        &cb_heap,
        {},
        &cb_desc,
        {.VERTEX_AND_CONSTANT_BUFFER},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.prefilter_constant_buffer),
    ))

    read_range := d3d12.RANGE{Begin = 0, End = 0}
    dx_check(r.prefilter_constant_buffer->Map(
        0, &read_range, (^rawptr)(&r.prefilter_cb_mapped_data),
    ))

    for mip in 0..<PREFILTER_MIP_COUNT {
        r.prefilter_cb_mapped_data[mip].roughness =
            f32(mip) / f32(PREFILTER_MIP_COUNT - 1)
    }
}

//render each mip at startup
renderer_generate_prefiltered_environment :: proc() {
    r := &g_renderer

    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.prefilter_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.prefilter_pipeline_state)

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))

    environment_srv: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&environment_srv)
    environment_srv.ptr += u64(ENVIRONMENT_SRV_INDEX) *
                           u64(r.srv_descriptor_size)
    r.command_list->SetGraphicsRootDescriptorTable(5, environment_srv)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)

    rtv_increment := r.device->GetDescriptorHandleIncrementSize(.RTV)

    for mip in 0..<PREFILTER_MIP_COUNT {
        mip_width := u32(PREFILTER_WIDTH) >> u32(mip)
        mip_height := u32(PREFILTER_HEIGHT) >> u32(mip)

        rtv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.prefilter_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
        rtv.ptr += uint(mip) * uint(rtv_increment)
        r.command_list->OMSetRenderTargets(1, &rtv, false, nil)

        viewport := d3d12.VIEWPORT{
            Width = f32(mip_width),
            Height = f32(mip_height),
            MinDepth = 0,
            MaxDepth = 1,
        }
        scissor := d3d12.RECT{
            right = i32(mip_width),
            bottom = i32(mip_height),
        }
        r.command_list->RSSetViewports(1, &viewport)
        r.command_list->RSSetScissorRects(1, &scissor)

        cb_offset := u64(mip) * u64(size_of(PrefilterConstants))
        r.command_list->SetGraphicsRootConstantBufferView(
            7,
            r.prefilter_constant_buffer->GetGPUVirtualAddress() + cb_offset,
        )

        r.command_list->DrawInstanced(3, 1, 0, 0)
    }

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)

    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()
}