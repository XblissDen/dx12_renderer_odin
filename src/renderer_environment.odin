package main

import c "core:c"
import "base:runtime"
import "core:math"
import "core:strings"
import d3d12 "vendor:directx/d3d12"
import stbi "vendor:stb/image"

EnvironmentSettings :: struct {
    asset: EnvironmentHandle,
    intensity: f32,
    rotation_degrees: f32,
    background_brightness: f32,
}

renderer_default_environment_settings :: proc() -> EnvironmentSettings {
    return {asset = g_assets.default_environment, intensity = 1, background_brightness = 1}
}

renderer_environment_settings_valid :: proc(settings: EnvironmentSettings) -> bool {
    return assets_environment_valid(settings.asset) &&
           settings.intensity >= 0 && settings.intensity <= 32 &&
           settings.background_brightness >= 0 && settings.background_brightness <= 32 &&
           !math.is_nan(settings.rotation_degrees) && !math.is_inf(settings.rotation_degrees)
}

renderer_set_environment :: proc(settings: EnvironmentSettings) -> string {
    r := &g_renderer
    if !renderer_environment_settings_valid(settings) do return "Invalid environment settings."
    if r.irradiance_texture == nil || r.prefilter_texture == nil do return "Environment maps are not initialized."
    if r.environment_texture == nil || r.environment_settings.asset != settings.asset {
        error := renderer_load_environment(g_assets.environments[settings.asset].desc.path)
        if error != "" do return error
        renderer_generate_irradiance()
        renderer_generate_prefiltered_environment()
    }
    r.environment_settings = settings
    return ""
}

renderer_process_environment_change :: proc() {
    r := &g_renderer
    if r.environment_pending == 0 do return
    settings := r.environment_settings
    settings.asset = r.environment_pending
    r.environment_pending = 0
    r.environment_status = renderer_set_environment(settings)
}

renderer_load_environment :: proc(path: string) -> (message: string) {
    r := &g_renderer

    width, height, channels: c.int
    pixels := stbi.loadf(
        strings.clone_to_cstring(path, context.temp_allocator) or_else panic("Environment path allocation failed"),
        &width, &height, &channels,
        4, // Request RGBA floats.
    )
    if pixels == nil {
        return "Could not decode the environment HDR file."
    }
    defer stbi.image_free(rawptr(pixels))
    if width <= 0 || height <= 0 do return "The environment HDR has invalid dimensions."

    mips := make([dynamic][]f32)
    append(&mips, pixels[:int(width) * int(height) * 4])
    defer {
        for mip in mips[1:] do delete(mip)
        delete(mips)
    }
    mip_width, mip_height := u32(width), u32(height)
    for mip_width > 1 || mip_height > 1 {
        next, next_width, next_height := texture_next_environment_mip(
            mips[len(mips) - 1], mip_width, mip_height,
        )
        append(&mips, next)
        mip_width, mip_height = next_width, next_height
    }

    renderer_wait_for_gpu()
    candidate: ^d3d12.IResource
    defer if message != "" && candidate != nil do candidate->Release()

    texture_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(width),
        Height = u32(height),
        DepthOrArraySize = 1,
        MipLevels = u16(len(mips)),
        // Keep the sun's full radiance while filtering, including values above
        // half-float range. The convolved lighting maps remain RGBA16F.
        Format = .R32G32B32A32_FLOAT,
        SampleDesc = {Count = 1},
    }
    default_heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}

    hr := r.device->CreateCommittedResource(
        &default_heap,
        {},
        &texture_desc,
        {.COPY_DEST},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&candidate),
    )
    if hr < 0 do return "Could not allocate the environment texture."

    layouts := make([]d3d12.PLACED_SUBRESOURCE_FOOTPRINT, len(mips))
    row_counts := make([]u32, len(mips))
    row_sizes := make([]u64, len(mips))
    defer delete(layouts)
    defer delete(row_counts)
    defer delete(row_sizes)
    upload_size: u64
    r.device->GetCopyableFootprints(
        &texture_desc, 0, u32(len(mips)), 0,
        raw_data(layouts), raw_data(row_counts), raw_data(row_sizes), &upload_size,
    )

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
    hr = r.device->CreateCommittedResource(
        &upload_heap,
        {},
        &upload_desc,
        d3d12.RESOURCE_STATE_GENERIC_READ,
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&upload_buffer),
    )
    if hr < 0 do return "Could not allocate the environment upload buffer."
    defer upload_buffer->Release()

    mapped: rawptr
    hr = upload_buffer->Map(0, nil, &mapped)
    if hr < 0 do return "Could not map the environment upload buffer."

    for mip in 0..<len(mips) {
        layout := layouts[mip]
        for y in 0..<int(row_counts[mip]) {
            destination := uintptr(mapped) + uintptr(layout.Offset) +
                uintptr(u64(y) * u64(layout.Footprint.RowPitch))
            source := uintptr(raw_data(mips[mip])) + uintptr(u64(y) * row_sizes[mip])
            runtime.mem_copy(rawptr(destination), rawptr(source), int(row_sizes[mip]))
        }
    }
    upload_buffer->Unmap(0, nil)

    hr = r.command_allocators[0]->Reset()
    if hr < 0 do return "Could not reset the environment upload allocator."
    hr = r.command_list->Reset(r.command_allocators[0], nil)
    if hr < 0 do return "Could not reset the environment upload command list."

    for mip in 0..<len(mips) {
        source := d3d12.TEXTURE_COPY_LOCATION{
            pResource = upload_buffer,
            Type = .PLACED_FOOTPRINT,
            PlacedFootprint = layouts[mip],
        }
        destination := d3d12.TEXTURE_COPY_LOCATION{
            pResource = candidate,
            Type = .SUBRESOURCE_INDEX,
            SubresourceIndex = u32(mip),
        }
        r.command_list->CopyTextureRegion(&destination, 0, 0, 0, &source, nil)
    }

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = candidate,
        StateBefore = {.COPY_DEST},
        StateAfter = {.PIXEL_SHADER_RESOURCE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    hr = r.command_list->Close()
    if hr < 0 do return "Could not close the environment upload command list."
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R32G32B32A32_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = u32(len(mips))}

    srv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
    srv.ptr += uint(r.environment_srv_index) *
               uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(
        candidate, &srv_desc, srv,
    )
    if r.environment_texture != nil do r.environment_texture->Release()
    r.environment_texture = candidate
    return ""
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
    srv.ptr += uint(r.irradiance_srv_index) *
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
    environment_srv.ptr += u64(r.environment_srv_index) *
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
    srv.ptr += uint(r.prefilter_srv_index) * uint(r.srv_descriptor_size)
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
    environment_srv.ptr += u64(r.environment_srv_index) *
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
