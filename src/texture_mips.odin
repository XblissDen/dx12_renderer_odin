package main

import "core:math"
import d3d12 "vendor:directx/d3d12"

// The next mip level of an HDR panorama (RGBA floats), built on the CPU at
// half the size. Panoramas are linear radiance, so latitude rows are weighted
// by their solid angle: each level keeps the sphere's energy, including for
// odd sizes.
texture_next_environment_mip :: proc(
    source: []f32,
    width, height: u32,
    allocator := context.allocator,
) -> (result: []f32, next_width, next_height: u32) {
    next_width = max(u32(1), width / 2)
    next_height = max(u32(1), height / 2)
    result = make([]f32, int(next_width) * int(next_height) * 4, allocator)

    for y in 0..<next_height {
        y0 := f64(y) * f64(height) / f64(next_height)
        y1 := f64(y + 1) * f64(height) / f64(next_height)
        first_y, end_y := u32(y0), min(u32(math.ceil(y1)), height)
        // Halving a dimension overlaps at most three source rows.
        row_weights: [3]f32
        for sy in first_y..<end_y {
            theta0 := max(y0, f64(sy)) * math.PI / f64(height)
            theta1 := min(y1, f64(sy + 1)) * math.PI / f64(height)
            row_weights[sy - first_y] = f32(math.cos(theta0) - math.cos(theta1))
        }

        for x in 0..<next_width {
            x0 := f64(x) * f64(width) / f64(next_width)
            x1 := f64(x + 1) * f64(width) / f64(next_width)
            first_x, end_x := u32(x0), min(u32(math.ceil(x1)), width)
            sum: [4]f32
            total_weight: f32
            for sy in first_y..<end_y {
                for sx in first_x..<end_x {
                    overlap := min(x1, f64(sx + 1)) - max(x0, f64(sx))
                    weight := f32(overlap) * row_weights[sy - first_y]
                    index := int((sy * width + sx) * 4)
                    for channel in 0..<4 do sum[channel] += source[index + channel] * weight
                    total_weight += weight
                }
            }
            index := int((y * next_width + x) * 4)
            for channel in 0..<4 do result[index + channel] = sum[channel] / total_weight
        }
    }
    return
}

// How texture_mips.hlsl averages texels; values match its MIP_* defines.
Texture_Mip_Mode :: enum u32 {Data, Srgb, Normal}

// Enough levels for textures up to 32768 pixels on a side.
TEXTURE_MAX_MIPS :: 16

// Levels in a full mip chain: each half the size of the last (rounded down,
// at least 1) down to 1x1.
texture_mip_count :: proc(width, height: u32) -> u32 {
    count: u32 = 1
    for w, h := width, height; w > 1 || h > 1; count += 1 {
        w, h = max(1, w / 2), max(1, h / 2)
    }
    return count
}

// Scratch views for building one texture's mips: a source SRV and a target
// RTV per level after the first.
renderer_create_mip_resources :: proc() {
    r := &g_renderer
    r.mip_srv_start = renderer_alloc_srv(TEXTURE_MAX_MIPS - 1)
    heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = TEXTURE_MAX_MIPS - 1, Type = .RTV}
    dx_check(r.device->CreateDescriptorHeap(&heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&r.mip_rtv_heap)))
}

// Records commands that render levels 1 and up of `texture` from level 0,
// each from the level above it (texture_mips.hlsl), viewing the typeless
// R8G8B8A8 texture as UNORM. Level 0 must be in PIXEL_SHADER_RESOURCE state
// and the others in COPY_DEST; all end in PIXEL_SHADER_RESOURCE. The next
// texture reuses the scratch views, so the caller must execute and wait for
// these commands first.
renderer_record_texture_mips :: proc(
    texture: ^d3d12.IResource,
    width, height, mip_count: u32,
    mode: Texture_Mip_Mode,
) {
    r := &g_renderer
    assert(mip_count <= TEXTURE_MAX_MIPS)
    if mip_count <= 1 do return

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.mip_pipeline)
    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->SetGraphicsRoot32BitConstant(u32(Root_Slot.Mip_Constants), u32(mode), 0)

    srv_start, rtv_start: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv_start)
    r.mip_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_start)
    rtv_size := r.device->GetDescriptorHandleIncrementSize(.RTV)

    for mip in 1..<mip_count {
        slot := mip - 1
        srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
            Format = .R8G8B8A8_UNORM,
            ViewDimension = .TEXTURE2D,
            Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        }
        srv_desc.Texture2D = {MostDetailedMip = mip - 1, MipLevels = 1}
        srv := srv_start
        srv.ptr += uint(r.mip_srv_start + slot) * uint(r.srv_descriptor_size)
        r.device->CreateShaderResourceView(texture, &srv_desc, srv)

        rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC{Format = .R8G8B8A8_UNORM, ViewDimension = .TEXTURE2D}
        rtv_desc.Texture2D = {MipSlice = mip}
        rtv := rtv_start
        rtv.ptr += uint(slot) * uint(rtv_size)
        r.device->CreateRenderTargetView(texture, &rtv_desc, rtv)

        barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
        barrier.Transition = {
            pResource = texture,
            StateBefore = {.COPY_DEST},
            StateAfter = {.RENDER_TARGET},
            Subresource = mip,
        }
        r.command_list->ResourceBarrier(1, &barrier)

        mip_width, mip_height := max(1, width >> mip), max(1, height >> mip)
        viewport := d3d12.VIEWPORT{Width = f32(mip_width), Height = f32(mip_height), MaxDepth = 1}
        scissor := d3d12.RECT{right = i32(mip_width), bottom = i32(mip_height)}
        r.command_list->RSSetViewports(1, &viewport)
        r.command_list->RSSetScissorRects(1, &scissor)
        r.command_list->OMSetRenderTargets(1, &rtv, false, nil)
        renderer_bind_srv(.Texture_T0, r.mip_srv_start + slot)
        r.command_list->DrawInstanced(3, 1, 0, 0)

        // The next level reads this one.
        barrier.Transition.StateBefore = {.RENDER_TARGET}
        barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
        r.command_list->ResourceBarrier(1, &barrier)
    }
}
