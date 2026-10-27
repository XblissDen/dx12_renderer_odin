package main

import "core:fmt"
import "core:time"
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
    hdr_srv.ptr += uint(r.hdr_srv_index) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(r.hdr_texture, &hdr_srv_desc, hdr_srv)

    // The tone-mapped frame, in the back buffer's format, for FXAA to read.
    if r.ldr_rtv_heap == nil {
        rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = 1, Type = .RTV}
        dx_check(r.device->CreateDescriptorHeap(
            &rtv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.ldr_rtv_heap),
        ))
    }

    ldr_desc := hdr_desc
    ldr_desc.Format = .R8G8B8A8_UNORM
    ldr_clear := d3d12.CLEAR_VALUE{Format = .R8G8B8A8_UNORM}
    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &ldr_desc,
        {.PIXEL_SHADER_RESOURCE},
        &ldr_clear,
        d3d12.IResource_UUID,
        (^rawptr)(&r.ldr_texture),
    ))

    ldr_rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.ldr_rtv_heap->GetCPUDescriptorHandleForHeapStart(&ldr_rtv)
    r.device->CreateRenderTargetView(r.ldr_texture, nil, ldr_rtv)
    renderer_write_srv(r.ldr_texture, .R8G8B8A8_UNORM, r.ldr_srv_index)
}

// The bloom mip chain: one texture, level 0 at half resolution. Rebuilt on
// resize.
renderer_create_bloom_targets :: proc() {
    r := &g_renderer

    if r.bloom_rtv_heap == nil {
        rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
            NumDescriptors = BLOOM_MIP_COUNT,
            Type = .RTV,
        }
        dx_check(r.device->CreateDescriptorHeap(
            &rtv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.bloom_rtv_heap),
        ))
    }

    width, height := max(1, r.width / 2), max(1, r.height / 2)
    // A tiny window cannot hold every level.
    r.bloom_mip_count = min(BLOOM_MIP_COUNT, texture_mip_count(width, height))

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(width),
        Height = height,
        DepthOrArraySize = 1,
        MipLevels = u16(r.bloom_mip_count),
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }

    clear_value := d3d12.CLEAR_VALUE{
        Format = .R16G16B16A16_FLOAT,
    }
    clear_value.Color = {0, 0, 0, 1}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.bloom_texture),
    ))

    rtv_increment := r.device->GetDescriptorHandleIncrementSize(.RTV)
    for mip in 0..<r.bloom_mip_count {
        rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC{Format = .R16G16B16A16_FLOAT, ViewDimension = .TEXTURE2D}
        rtv_desc.Texture2D = {MipSlice = mip}
        rtv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.bloom_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
        rtv.ptr += uint(mip) * uint(rtv_increment)
        r.device->CreateRenderTargetView(r.bloom_texture, &rtv_desc, rtv)

        // One level per view: each pass reads exactly one.
        srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
            Format = .R16G16B16A16_FLOAT,
            ViewDimension = .TEXTURE2D,
            Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        }
        srv_desc.Texture2D = {MostDetailedMip = mip, MipLevels = 1}
        srv: d3d12.CPU_DESCRIPTOR_HANDLE
        r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv)
        srv.ptr += uint(r.bloom_srv_start + mip) * uint(r.srv_descriptor_size)
        r.device->CreateShaderResourceView(r.bloom_texture, &srv_desc, srv)
    }
}

// Draws bloom level `target_mip` from the view at `source_srv_index`.
renderer_bloom_pass :: proc(
    target_mip: u32,
    source_srv_index: u32,
    pso: ^d3d12.IPipelineState,
) {
    r := &g_renderer
    assert(target_mip < r.bloom_mip_count)

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.bloom_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = target_mip,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.bloom_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    rtv.ptr += uint(target_mip) * uint(r.device->GetDescriptorHandleIncrementSize(.RTV))

    width := max(1, r.width / 2) >> target_mip
    height := max(1, r.height / 2) >> target_mip
    viewport := d3d12.VIEWPORT{Width = f32(max(1, width)), Height = f32(max(1, height)), MaxDepth = 1}
    scissor := d3d12.RECT{right = i32(max(1, width)), bottom = i32(max(1, height))}

    r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    renderer_bind_cbv(.Post_Constants, renderer_post_cb_address())
    renderer_bind_buffer_srv(.Exposure_Buffer, r.exposure_buffer->GetGPUVirtualAddress())
    r.command_list->SetPipelineState(pso)
    renderer_bind_srv(.Texture_T0, source_srv_index)

    r.command_list->RSSetViewports(1, &viewport)
    r.command_list->RSSetScissorRects(1, &scissor)
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
        "DX12 | FPS %.0f Frame %.1f ms | GPU shadow %.2f scene %.2f bloom %.2f post %.2f ms | E %s T %.1f B %.1f [1-6]",
        r.fps,
        r.frame_ms,
        r.gpu_pass_ms[0],
        r.gpu_pass_ms[1],
        bloom_ms,
        r.gpu_pass_ms[5],
        // Auto: the compensation, which keys 1/2 adjust.
        fmt.tprintf("auto%+.2f", r.auto_exposure.compensation) if r.auto_exposure.enabled else fmt.tprintf("%.1f", r.post_exposure),
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
    // With auto-exposure, keys 1/2 adjust its compensation in quarter stops.
    if r.auto_exposure.enabled {
        r.auto_exposure.compensation = clamp(r.auto_exposure.compensation + f32(exposure_steps) * 0.25, -5, 5)
    } else {
        r.post_exposure = clamp(r.post_exposure + f32(exposure_steps) * 0.1, 0.1, 5.0)
    }
    r.post_threshold = clamp(r.post_threshold + f32(threshold_steps) * 0.1, 0.1, 5.0)
    r.post_strength = clamp(r.post_strength + f32(bloom_steps) * 0.1, 0.0, 2.0)

    renderer_update_post_title()
}

// Prefilter into level 0, downsample to the smallest level, then upsample
// back, adding each level into the next larger one. Tone mapping reads level 0.
renderer_render_bloom :: proc() {
    r := &g_renderer
    levels := r.bloom_mip_count

    renderer_begin_gpu_pass(.Bloom_Prefilter)
    renderer_bloom_pass(0, r.scene_color_srv_index, r.bloom_pipeline_states[0])
    renderer_end_gpu_pass(.Bloom_Prefilter)

    renderer_begin_gpu_pass(.Bloom_Downsample)
    for mip in 1..<levels {
        renderer_bloom_pass(mip, r.bloom_srv_start + mip - 1, r.bloom_pipeline_states[1])
    }
    renderer_end_gpu_pass(.Bloom_Downsample)

    renderer_begin_gpu_pass(.Bloom_Upsample)
    for mip := levels - 1; mip > 0; mip -= 1 {
        renderer_bloom_pass(mip - 1, r.bloom_srv_start + mip, r.bloom_pipeline_states[2])
    }
    renderer_end_gpu_pass(.Bloom_Upsample)
}

// Auto-exposure settings, saved with the scene. Exposure is 2^EV: +1 EV
// doubles the brightness.
AutoExposureSettings :: struct {
    enabled: bool,
    // Added to the automatic exposure, in EV.
    compensation: f32,
    // Limits of the automatic exposure, in EV.
    min_ev, max_ev: f32,
    // Adaptation rates per second: toward more exposure (a darker view) and
    // toward less (a brighter one). Eyes adapt to light faster than to dark.
    adapt_dark, adapt_bright: f32,
}

DEFAULT_AUTO_EXPOSURE :: AutoExposureSettings{
    enabled = true,
    min_ev = -6,
    max_ev = 6,
    adapt_dark = 1,
    adapt_bright = 3,
}

auto_exposure_settings_valid :: proc(s: AutoExposureSettings) -> bool {
    return s.compensation >= -10 && s.compensation <= 10 &&
           s.min_ev >= -16 && s.max_ev <= 16 && s.min_ev <= s.max_ev &&
           s.adapt_dark > 0 && s.adapt_dark <= 50 &&
           s.adapt_bright > 0 && s.adapt_bright <= 50
}

// Root constants of auto_exposure.hlsl (b0); the same layout.
ExposureConstants :: struct {
    image_size: [2]u32,
    min_log2_luminance, log2_luminance_range: f32,
    low_percentile, high_percentile: f32,
    delta_time: f32,
    adapt_dark, adapt_bright: f32,
    min_ev, max_ev: f32,
    reset: u32,
}

// Histogram range in log2 luminance: from deep shadow (2^-12) to well past
// a sunlit sky (2^14), about a tenth of a stop per bin.
EXPOSURE_MIN_LOG2_LUMINANCE :: -12
EXPOSURE_LOG2_LUMINANCE_RANGE :: 26
// The pixels the average uses: the darkest half and the brightest 5% are left
// out, so dark corners and small highlights (the sun) do not steer exposure.
EXPOSURE_LOW_PERCENTILE :: 0.5
EXPOSURE_HIGH_PERCENTILE :: 0.95
EXPOSURE_BIN_COUNT :: 256

Exposure_Root_Slot :: enum u32 {Constants, Scene, Histogram, Exposure}

renderer_create_auto_exposure :: proc() {
    r := &g_renderer

    // Compute root signature: constants (b0), the scene color (t0), and the
    // two buffers as root UAVs (u0, u1).
    scene_range := d3d12.DESCRIPTOR_RANGE{RangeType = .SRV, NumDescriptors = 1}
    params: [Exposure_Root_Slot]d3d12.ROOT_PARAMETER
    params[.Constants].ParameterType = ._32BIT_CONSTANTS
    params[.Constants].Constants = {Num32BitValues = size_of(ExposureConstants) / 4}
    params[.Scene].ParameterType = .DESCRIPTOR_TABLE
    params[.Scene].DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &scene_range}
    params[.Histogram].ParameterType = .UAV
    params[.Histogram].Descriptor = {ShaderRegister = 0}
    params[.Exposure].ParameterType = .UAV
    params[.Exposure].Descriptor = {ShaderRegister = 1}
    rs_desc := d3d12.ROOT_SIGNATURE_DESC{NumParameters = len(params), pParameters = &params[Exposure_Root_Slot(0)]}
    signature, errors: ^d3d12.IBlob
    hr := d3d12.SerializeRootSignature(&rs_desc, ._1, &signature, &errors)
    if errors != nil {
        fmt.println("Exposure root signature:", cstring(errors->GetBufferPointer()))
        errors->Release()
    }
    dx_check(hr)
    defer signature->Release()
    dx_check(r.device->CreateRootSignature(
        0, signature->GetBufferPointer(), signature->GetBufferSize(),
        d3d12.IRootSignature_UUID, (^rawptr)(&r.exposure_root_signature),
    ))

    buffer :: proc(size: u64, heap_type: d3d12.HEAP_TYPE, flags: d3d12.RESOURCE_FLAGS, state: d3d12.RESOURCE_STATES) -> (resource: ^d3d12.IResource) {
        heap := d3d12.HEAP_PROPERTIES{Type = heap_type}
        desc := d3d12.RESOURCE_DESC{
            Dimension = .BUFFER, Width = size, Height = 1, DepthOrArraySize = 1,
            MipLevels = 1, SampleDesc = {Count = 1}, Layout = .ROW_MAJOR, Flags = flags,
        }
        dx_check(g_renderer.device->CreateCommittedResource(&heap, {}, &desc, state, nil, d3d12.IResource_UUID, (^rawptr)(&resource)))
        return
    }
    // Committed buffers start zeroed: an empty histogram, and EV 0.
    r.exposure_histogram = buffer(EXPOSURE_BIN_COUNT * 4, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    r.exposure_buffer = buffer(8, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    r.exposure_readback = buffer(FRAME_COUNT * 8, .READBACK, {}, {.COPY_DEST})

    // Between frames the histogram stays a UAV and the exposure a pixel-shader
    // resource (bloom and tone mapping read it).
    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))
    barriers := [2]d3d12.RESOURCE_BARRIER{{Type = .TRANSITION}, {Type = .TRANSITION}}
    barriers[0].Transition = {
        pResource = r.exposure_histogram, StateBefore = d3d12.RESOURCE_STATE_COMMON,
        StateAfter = {.UNORDERED_ACCESS}, Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    barriers[1].Transition = {
        pResource = r.exposure_buffer, StateBefore = d3d12.RESOURCE_STATE_COMMON,
        StateAfter = {.PIXEL_SHADER_RESOURCE}, Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(1, raw_data(lists))
    renderer_wait_for_gpu()

    r.auto_exposure_reset = true
}

// The histogram and adaptation pipelines; rebuilt by shader hot-reload.
renderer_create_exposure_pipelines :: proc() {
    r := &g_renderer
    entries := [2]cstring{"CSHistogram", "CSAdapt"}
    pipelines := [2]^^d3d12.IPipelineState{&r.exposure_histogram_pipeline, &r.exposure_adapt_pipeline}
    for entry, i in entries {
        cs := renderer_compile_shader("shaders/auto_exposure.hlsl", entry, "cs_5_1")
        defer cs->Release()
        if renderer_skip_pipeline() do continue
        desc := d3d12.COMPUTE_PIPELINE_STATE_DESC{pRootSignature = r.exposure_root_signature, CS = shader_bytecode(cs)}
        renderer_check_pipeline(r.device->CreateComputePipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(pipelines[i])))
    }
}

// The pipelines are released with the others (renderer_pipeline_slots).
renderer_release_auto_exposure :: proc() {
    r := &g_renderer
    r.exposure_root_signature->Release()
    r.exposure_histogram->Release()
    r.exposure_buffer->Release()
    r.exposure_readback->Release()
}

// Measures the scene color and updates the exposure bloom and tone mapping
// read. Runs after TAA, before bloom.
renderer_render_auto_exposure :: proc() {
    r := &g_renderer
    now := time.tick_now()
    // Long pauses (a breakpoint, a dragged window) adapt as if a moment passed.
    delta_time := min(f32(time.duration_seconds(time.tick_diff(r.auto_exposure_tick, now))), 0.25)
    r.auto_exposure_tick = now

    renderer_begin_gpu_pass(.Auto_Exposure)
    defer renderer_end_gpu_pass(.Auto_Exposure)
    if !r.auto_exposure.enabled {
        // Turning it back on starts from the measured exposure.
        r.auto_exposure_reset = true
        return
    }

    barriers := [2]d3d12.RESOURCE_BARRIER{{Type = .TRANSITION}, {Type = .TRANSITION}}
    barriers[0].Transition = {
        pResource = r.scene_color, StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.PIXEL_SHADER_RESOURCE, .NON_PIXEL_SHADER_RESOURCE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    barriers[1].Transition = {
        pResource = r.exposure_buffer, StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.UNORDERED_ACCESS}, Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])

    settings := r.auto_exposure
    constants := ExposureConstants{
        image_size = {r.width, r.height},
        min_log2_luminance = EXPOSURE_MIN_LOG2_LUMINANCE,
        log2_luminance_range = EXPOSURE_LOG2_LUMINANCE_RANGE,
        low_percentile = EXPOSURE_LOW_PERCENTILE,
        high_percentile = EXPOSURE_HIGH_PERCENTILE,
        delta_time = delta_time,
        adapt_dark = settings.adapt_dark,
        adapt_bright = settings.adapt_bright,
        min_ev = settings.min_ev,
        max_ev = settings.max_ev,
        reset = u32(r.auto_exposure_reset),
    }
    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetComputeRootSignature(r.exposure_root_signature)
    r.command_list->SetComputeRoot32BitConstants(u32(Exposure_Root_Slot.Constants), size_of(constants) / 4, &constants, 0)
    r.command_list->SetComputeRootDescriptorTable(u32(Exposure_Root_Slot.Scene), renderer_srv_gpu(r.scene_color_srv_index))
    r.command_list->SetComputeRootUnorderedAccessView(u32(Exposure_Root_Slot.Histogram), r.exposure_histogram->GetGPUVirtualAddress())
    r.command_list->SetComputeRootUnorderedAccessView(u32(Exposure_Root_Slot.Exposure), r.exposure_buffer->GetGPUVirtualAddress())

    r.command_list->SetPipelineState(r.exposure_histogram_pipeline)
    r.command_list->Dispatch((r.width + 15) / 16, (r.height + 15) / 16, 1)
    histogram_done := d3d12.RESOURCE_BARRIER{Type = .UAV}
    histogram_done.UAV = {pResource = r.exposure_histogram}
    r.command_list->ResourceBarrier(1, &histogram_done)
    r.command_list->SetPipelineState(r.exposure_adapt_pipeline)
    r.command_list->Dispatch(1, 1, 1)

    // A copy for the panel, then back to being read by bloom and tone mapping.
    barriers[0].Transition.StateBefore = {.PIXEL_SHADER_RESOURCE, .NON_PIXEL_SHADER_RESOURCE}
    barriers[0].Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    barriers[1].Transition.StateBefore = {.UNORDERED_ACCESS}
    barriers[1].Transition.StateAfter = {.COPY_SOURCE}
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
    r.command_list->CopyBufferRegion(r.exposure_readback, u64(r.frame_slot) * 8, r.exposure_buffer, 0, 8)
    barriers[1].Transition.StateBefore = {.COPY_SOURCE}
    barriers[1].Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barriers[1])

    r.auto_exposure_reset = false
}

// The exposure that frame `slot` computed, once the GPU has finished it.
renderer_read_auto_exposure :: proc(slot: u32) {
    r := &g_renderer
    if !r.auto_exposure.enabled do return
    read_range := d3d12.RANGE{Begin = uint(slot) * 8, End = uint(slot) * 8 + 8}
    mapped: rawptr
    dx_check(r.exposure_readback->Map(0, &read_range, &mapped))
    // Map returns the buffer's start; the EV is the second float.
    r.auto_exposure_ev = ([^]f32)(mapped)[slot * 2 + 1]
    written_range := d3d12.RANGE{}
    r.exposure_readback->Unmap(0, &written_range)
}
