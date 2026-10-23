package main

import "core:math"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"

// Sun shadows cover the camera view out to this distance, then fade out.
DEFAULT_SHADOW_DISTANCE :: f32(20)
MIN_SHADOW_DISTANCE :: f32(2)
MAX_SHADOW_DISTANCE :: f32(200)
SHADOW_FADE_FRACTION :: f32(0.15)

// Bias in shadow-map texels. 3x3 PCF samples one texel away, so the slope
// term must cover at least that much depth change on tilted receivers.
DEFAULT_SHADOW_BIAS_CONSTANT :: f32(1.0)
DEFAULT_SHADOW_BIAS_SLOPE :: f32(1.5)
MAX_SHADOW_BIAS :: f32(10)

ShadowFit :: struct {
    view_projection: alg.Matrix4f32,
    // Shadow-map depth change across one texel on a receiver facing the sun.
    texel_depth: f32,
    fade_start, fade_end: f32,
}

// Fits the sun's orthographic volume around the camera view up to `distance`.
// The volume is a bounding sphere of that view slice: its size does not change
// as the camera turns, and its center snaps to whole shadow-map texels, so
// shadow edges stay still while the camera moves.
renderer_fit_shadow :: proc(
    sun_direction: alg.Vector3f32,
    camera_position, camera_forward: alg.Vector3f32,
    aspect, far_clip, distance: f32,
    casters: []WorldBounds,
) -> ShadowFit {
    shadow_distance := clamp(distance, CAMERA_NEAR_CLIP * 2, far_clip)

    // Slice corners sit sqrt(k2) * depth from the view axis. The center depth
    // minimizing the enclosing sphere balances near and far corners.
    tan_half_fov := math.tan(CAMERA_FOV_Y * 0.5)
    k2 := tan_half_fov * tan_half_fov * (1 + aspect * aspect)
    near := CAMERA_NEAR_CLIP
    center_depth := min((near + shadow_distance) * 0.5 * (1 + k2), shadow_distance)

    far_corner := math.sqrt(
        (shadow_distance - center_depth) * (shadow_distance - center_depth) +
        shadow_distance * shadow_distance * k2,
    )
    near_corner := math.sqrt(
        (center_depth - near) * (center_depth - near) + near * near * k2,
    )
    // Quantize so floating-point noise never changes the texel size.
    radius := math.ceil(max(far_corner, near_corner) * 16) / 16
    center := camera_position + camera_forward * center_depth

    // Same basis look_at_lh builds for an eye at the origin facing the sun's rays.
    sun_up := alg.Vector3f32{0, 1, 0}
    if math.abs(sun_direction.y) > 0.99 {
        sun_up = {0, 0, 1}
    }
    light_z := alg.normalize(sun_direction)
    light_x := alg.normalize(alg.cross(sun_up, light_z))
    light_y := alg.cross(light_z, light_x)

    texel := 2 * radius / SHADOW_MAP_SIZE
    center_x := math.floor(alg.dot(light_x, center) / texel) * texel
    center_y := math.floor(alg.dot(light_y, center) / texel) * texel
    center_z := alg.dot(light_z, center)

    // Receivers end at the sphere. Casters between it and the sun can still
    // shadow it, so pull the near plane back to include them.
    near_z := center_z - radius
    far_z := center_z + radius
    for bounds in casters {
        if !bounds.valid {
            continue
        }

        extent: [3]f32
        axes := [3]alg.Vector3f32{light_x, light_y, light_z}
        for axis, i in axes {
            for half_axis in bounds.half_axes {
                extent[i] += math.abs(alg.dot(axis, half_axis))
            }
        }

        offset_x := alg.dot(light_x, bounds.center) - center_x
        offset_y := alg.dot(light_y, bounds.center) - center_y
        if math.abs(offset_x) > radius + extent[0] ||
           math.abs(offset_y) > radius + extent[1] {
            continue
        }
        near_z = min(near_z, alg.dot(light_z, bounds.center) - extent[2])
    }
    near_z -= texel

    view := look_at_lh({0, 0, 0}, light_z, sun_up)
    projection := orthographic_lh(
        center_x - radius, center_x + radius,
        center_y - radius, center_y + radius,
        near_z, far_z,
    )

    return ShadowFit{
        view_projection = view * projection,
        texel_depth = texel / (far_z - near_z),
        fade_start = shadow_distance * (1 - SHADOW_FADE_FRACTION),
        fade_end = shadow_distance,
    }
}

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
    srv_handle.ptr += uint(r.shadow_srv_index) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(r.shadow_map, &shadow_srv, srv_handle)
}

renderer_render_shadow_pass :: proc(draw_meshes: []MeshHandle, draw_indices: []u32) {
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
    r.command_list->SetGraphicsRootConstantBufferView(
        12,
        renderer_frame_cb_address(),
    )

    for draw_index in draw_indices {
        i := int(draw_index)
        assert(i >= 0 && i < len(draw_meshes))

        r.command_list->SetGraphicsRootConstantBufferView(
            0,
            renderer_object_cb_address(i),
        )

        mesh_index := int(draw_meshes[i])
        assert(mesh_index > 0 && mesh_index < len(r.meshes))
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
