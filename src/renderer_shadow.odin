package main

import "core:math"
import "core:slice"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"

// Sun shadows cover the camera view out to this distance, then fade out.
// The distance is split into cascades: each gets its own shadow map, so nearby
// receivers get small texels while distant ones still have shadows.
SHADOW_CASCADE_COUNT :: 4
DEFAULT_SHADOW_DISTANCE :: f32(40)
MIN_SHADOW_DISTANCE :: f32(2)
MAX_SHADOW_DISTANCE :: f32(200)
SHADOW_FADE_FRACTION :: f32(0.15)
// Blend of logarithmic (1) and uniform (0) split spacing.
SHADOW_SPLIT_LAMBDA :: f32(0.8)
// Each cascade blends into the next over this last fraction of its depth range.
SHADOW_CASCADE_BLEND_FRACTION :: f32(0.1)

// Bias in shadow-map texels. The 5x5 tent filter reaches 2.5 texels away, so
// the slope term must cover that much depth change on tilted receivers.
DEFAULT_SHADOW_BIAS_CONSTANT :: f32(1.0)
DEFAULT_SHADOW_BIAS_SLOPE :: f32(1.5)
MAX_SHADOW_BIAS :: f32(10)
// Receivers look up the shadow map this many texels off their surface, along
// the geometric normal, which removes most acne without a large depth bias.
SHADOW_NORMAL_OFFSET_TEXELS :: f32(1.0)

// Spot light shadows: one perspective map per slot, given each frame to the
// shadow-casting spot lights nearest the camera.
SPOT_SHADOW_COUNT :: 4
SPOT_SHADOW_MAP_SIZE :: 1024
// Point light shadows: a cube map (six 90-degree faces) per slot.
POINT_SHADOW_COUNT :: 4
POINT_SHADOW_MAP_SIZE :: 512
POINT_SHADOW_FACES :: 6
// Shadow views per frame: the sun's cascades, the spot slots, then each
// point slot's six faces.
SHADOW_VIEW_COUNT :: SHADOW_CASCADE_COUNT + SPOT_SHADOW_COUNT + POINT_SHADOW_COUNT * POINT_SHADOW_FACES
POINT_SHADOW_FIRST_VIEW :: SHADOW_CASCADE_COUNT + SPOT_SHADOW_COUNT
// Rasterizer bias for spot shadow casters (D3D units), and the receiver's
// offset along its normal in shadow-map texels at its distance from the light.
// Must match SPOT_SHADOW_NORMAL_OFFSET_TEXELS in scene.hlsl.
SPOT_SHADOW_DEPTH_BIAS :: 0
SPOT_SHADOW_SLOPE_BIAS :: f32(2.0)
SPOT_SHADOW_NORMAL_OFFSET_TEXELS :: f32(1.5)

// Between shadow passes the maps are read by the lit pass and by the
// volumetric fog's compute pass.
SHADOW_READ_STATE :: d3d12.RESOURCE_STATES{.PIXEL_SHADER_RESOURCE, .NON_PIXEL_SHADER_RESOURCE}

// The spot light's view of its cone: the cone's outer angle is the field of
// view and its range the far plane.
SpotShadow :: struct {
    entity: int,
    view_projection: alg.Matrix4f32,
    // World size of one texel per unit of distance along the cone's axis.
    texel_scale: f32,
}

// The shadow-casting spot (or point) lights, nearest to the camera first:
// shadow slots go to the first few.
renderer_shadow_light_order :: proc(scene: ^Scene, camera_position: alg.Vector3f32, spot: bool) -> []int {
    Candidate :: struct {entity: int, distance: f32}
    candidates := make([dynamic]Candidate, context.temp_allocator)
    for i in 0..<scene.entity_count {
        if !scene.alive[i] || !scene.has_transform[i] do continue
        casts := scene.has_spot_light[i] && scene.spot_lights[i].cast_shadows if spot else
                 scene.has_point_light[i] && scene.point_lights[i].cast_shadows
        if !casts do continue
        append(&candidates, Candidate{i, alg.length(scene_world_position(scene, i) - camera_position)})
    }
    slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool {return a.distance < b.distance})
    order := make([]int, len(candidates), context.temp_allocator)
    for candidate, i in candidates do order[i] = candidate.entity
    return order
}

// Gives the spot shadow slots to the shadow-casting spot lights nearest the
// camera, and records which entity got each slot (-1: unused).
renderer_select_spot_shadows :: proc(scene: ^Scene, camera_position: alg.Vector3f32) -> (shadows: [SPOT_SHADOW_COUNT]SpotShadow) {
    r := &g_renderer
    order := renderer_shadow_light_order(scene, camera_position, spot = true)
    for slot in 0..<SPOT_SHADOW_COUNT {
        shadows[slot].entity = -1
        if slot < len(order) {
            entity := order[slot]
            shadows[slot] = renderer_fit_spot_shadow(scene_world_matrix(scene, entity), scene.spot_lights[entity])
            shadows[slot].entity = entity
        }
        r.spot_shadow_entities[slot] = shadows[slot].entity
    }
    return
}

// A point light's cube map: six 90-degree views out to its range, oriented
// as D3D's cube faces (+X, -X, +Y, -Y, +Z, -Z) so the shader can sample by
// direction.
PointShadow :: struct {
    entity: int,
    face_view_projection: [POINT_SHADOW_FACES]alg.Matrix4f32,
    near: f32,
}

// World size of one cube-face texel per unit of distance along the face's
// axis (90-degree field of view).
POINT_SHADOW_TEXEL_SCALE :: f32(2.0 / POINT_SHADOW_MAP_SIZE)

renderer_select_point_shadows :: proc(scene: ^Scene, camera_position: alg.Vector3f32) -> (shadows: [POINT_SHADOW_COUNT]PointShadow) {
    r := &g_renderer
    order := renderer_shadow_light_order(scene, camera_position, spot = false)
    // look_at_lh with these targets and ups gives each face D3D's cube layout.
    directions := [POINT_SHADOW_FACES]alg.Vector3f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
    ups := [POINT_SHADOW_FACES]alg.Vector3f32{{0, 1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {0, 1, 0}, {0, 1, 0}}
    for slot in 0..<POINT_SHADOW_COUNT {
        shadows[slot].entity = -1
        if slot < len(order) {
            entity := order[slot]
            position := scene_world_position(scene, entity)
            light := scene.point_lights[entity]
            shadow := &shadows[slot]
            shadow.entity = entity
            shadow.near = max(light.range * 0.001, 0.02)
            projection := perspective_lh(math.PI / 2, 1, shadow.near, light.range)
            for face in 0..<POINT_SHADOW_FACES {
                shadow.face_view_projection[face] = look_at_lh(position, position + directions[face], ups[face]) * projection
            }
        }
        r.point_shadow_entities[slot] = shadows[slot].entity
    }
    return
}

renderer_fit_spot_shadow :: proc(world: alg.Matrix4f32, light: SpotLight) -> (shadow: SpotShadow) {
    direction := spot_light_direction(world)
    position := alg.Vector3f32{world[0, 3], world[1, 3], world[2, 3]}
    up := alg.Vector3f32{0, 1, 0}
    if math.abs(direction.y) > 0.99 do up = {0, 0, 1}
    fov := 2 * light.outer_angle
    near := max(light.range * 0.001, 0.02)
    view := look_at_lh(position, position + direction, up)
    shadow.view_projection = view * perspective_lh(fov, 1, near, light.range)
    shadow.texel_scale = 2 * math.tan(light.outer_angle) / SPOT_SHADOW_MAP_SIZE
    return
}

ShadowCascade :: struct {
    view_projection: alg.Matrix4f32,
    // View depth (along the camera's forward axis) where this cascade ends.
    split_depth: f32,
    // World size of one texel, and the depth change across one texel on a
    // receiver facing the sun, in shadow-map depth units.
    texel_world: f32,
    texel_depth: f32,
}

ShadowFit :: struct {
    cascades: [SHADOW_CASCADE_COUNT]ShadowCascade,
    fade_start, fade_end: f32,
}

// Splits the view out to the shadow distance into cascades and fits each one.
renderer_fit_shadow :: proc(
    sun_direction: alg.Vector3f32,
    camera_position, camera_forward: alg.Vector3f32,
    aspect, far_clip, distance: f32,
    casters: []WorldBounds,
) -> (fit: ShadowFit) {
    shadow_distance := clamp(distance, CAMERA_NEAR_CLIP * 2, far_clip)
    near := CAMERA_NEAR_CLIP

    slice_near := near
    for i in 0..<SHADOW_CASCADE_COUNT {
        // Practical split scheme: mostly logarithmic, which matches how
        // perspective shrinks texels with distance.
        t := f32(i + 1) / SHADOW_CASCADE_COUNT
        logarithmic := near * math.pow(shadow_distance / near, t)
        uniform := near + (shadow_distance - near) * t
        slice_far := math.lerp(uniform, logarithmic, SHADOW_SPLIT_LAMBDA)
        if i == SHADOW_CASCADE_COUNT - 1 do slice_far = shadow_distance

        fit.cascades[i] = renderer_fit_shadow_cascade(
            sun_direction, camera_position, camera_forward,
            aspect, slice_near, slice_far, casters,
        )
        slice_near = slice_far
    }

    fit.fade_start = shadow_distance * (1 - SHADOW_FADE_FRACTION)
    fit.fade_end = shadow_distance
    return
}

// Fits the sun's orthographic volume around one slice of the camera view.
// The volume is a bounding sphere of the slice: its size does not change as
// the camera turns, and its center snaps to whole shadow-map texels, so shadow
// edges stay still while the camera moves.
renderer_fit_shadow_cascade :: proc(
    sun_direction: alg.Vector3f32,
    camera_position, camera_forward: alg.Vector3f32,
    aspect, slice_near, slice_far: f32,
    casters: []WorldBounds,
) -> ShadowCascade {
    // Slice corners sit sqrt(k2) * depth from the view axis. The center depth
    // minimizing the enclosing sphere balances near and far corners.
    tan_half_fov := math.tan(CAMERA_FOV_Y * 0.5)
    k2 := tan_half_fov * tan_half_fov * (1 + aspect * aspect)
    center_depth := min((slice_near + slice_far) * 0.5 * (1 + k2), slice_far)

    far_corner := math.sqrt(
        (slice_far - center_depth) * (slice_far - center_depth) +
        slice_far * slice_far * k2,
    )
    near_corner := math.sqrt(
        (center_depth - slice_near) * (center_depth - slice_near) +
        slice_near * slice_near * k2,
    )
    // Quantize so floating-point noise never changes the texel size.
    radius := math.ceil(max(far_corner, near_corner) * 64) / 64
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

    return ShadowCascade{
        view_projection = view * projection,
        split_depth = slice_far,
        texel_world = texel,
        texel_depth = texel / (far_z - near_z),
    }
}

renderer_create_shadow_map :: proc() {
    r := &g_renderer
    r.shadow_map, r.shadow_dsv_heap = renderer_create_shadow_array(
        SHADOW_MAP_SIZE, SHADOW_CASCADE_COUNT, r.shadow_srv_index,
    )
    r.spot_shadow_map, r.spot_shadow_dsv_heap = renderer_create_shadow_array(
        SPOT_SHADOW_MAP_SIZE, SPOT_SHADOW_COUNT, r.spot_shadow_srv_index,
    )
    r.point_shadow_map, r.point_shadow_dsv_heap = renderer_create_shadow_array(
        POINT_SHADOW_MAP_SIZE, POINT_SHADOW_COUNT * POINT_SHADOW_FACES, r.point_shadow_srv_index, cube = true,
    )
}

// A square depth texture array for shadows, left in SHADOW_READ_STATE
// state: one depth view per slice, and a shader view of every slice at
// `srv_index`: an array of 2D maps, or with `cube` of cube maps (six
// slices each).
renderer_create_shadow_array :: proc(size, slices, srv_index: u32, cube := false) -> (
    texture: ^d3d12.IResource,
    dsv_heap: ^d3d12.IDescriptorHeap,
) {
    r := &g_renderer

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    shadow_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(size),
        Height = size,
        DepthOrArraySize = u16(slices),
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
        SHADOW_READ_STATE,
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&texture),
    ))

    dsv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = slices,
        Type = .DSV,
    }
    dx_check(r.device->CreateDescriptorHeap(
        &dsv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&dsv_heap),
    ))

    dsv_size := r.device->GetDescriptorHandleIncrementSize(.DSV)
    for slice in 0..<slices {
        shadow_dsv := d3d12.DEPTH_STENCIL_VIEW_DESC{
            Format = .D32_FLOAT,
            ViewDimension = .TEXTURE2DARRAY,
        }
        shadow_dsv.Texture2DArray = {
            FirstArraySlice = slice,
            ArraySize = 1,
        }
        dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
        dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)
        dsv_handle.ptr += uint(slice) * uint(dsv_size)
        r.device->CreateDepthStencilView(texture, &shadow_dsv, dsv_handle)
    }

    shadow_srv := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R32_FLOAT,
        ViewDimension = .TEXTURE2DARRAY,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    if cube {
        shadow_srv.ViewDimension = .TEXTURECUBEARRAY
        shadow_srv.TextureCubeArray = {MipLevels = 1, NumCubes = slices / 6}
    } else {
        shadow_srv.Texture2DArray = {MipLevels = 1, ArraySize = slices}
    }

    srv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv_handle)
    srv_handle.ptr += uint(srv_index) * uint(r.srv_descriptor_size)
    r.device->CreateShaderResourceView(texture, &shadow_srv, srv_handle)
    return
}

renderer_render_shadow_pass :: proc(
    draws: []Draw,
    // Casters per shadow view: cascades, then spot slots.
    view_draws: [SHADOW_VIEW_COUNT][]u32,
) {
    r := &g_renderer

    renderer_begin_gpu_pass(.Shadow)
    shadow_barrier := d3d12.RESOURCE_BARRIER {Type = .TRANSITION}
    shadow_barrier.Transition = {
        pResource = r.shadow_map,
        StateBefore = SHADOW_READ_STATE,
        StateAfter = {.DEPTH_WRITE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &shadow_barrier)

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
    // Cutouts read their albedo alpha through the material table.
    shadow_heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(shadow_heaps))
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())

    dsv_size := r.device->GetDescriptorHandleIncrementSize(.DSV)
    for cascade in 0..<SHADOW_CASCADE_COUNT {
        dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
        r.shadow_dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)
        dsv_handle.ptr += uint(cascade) * uint(dsv_size)

        r.command_list->OMSetRenderTargets(0, nil, false, &dsv_handle)
        r.command_list->ClearDepthStencilView(
            dsv_handle, {.DEPTH}, 1.0, 0, 0, nil,
        )
        // VSShadow reads this cascade's matrix from the frame constants.
        r.command_list->SetGraphicsRoot32BitConstant(u32(Root_Slot.Shadow_Cascade), u32(cascade), 0)

        renderer_draw_list(draws, view_draws[cascade], r.shadow_pipeline_states)
    }

    shadow_barrier.Transition.StateBefore = {.DEPTH_WRITE}
    shadow_barrier.Transition.StateAfter = SHADOW_READ_STATE
    r.command_list->ResourceBarrier(1, &shadow_barrier)

    // Spot lights: one slice per used slot, drawn with the bias pipelines.
    // VSShadow reads view SHADOW_CASCADE_COUNT + slot.
    shadow_barrier.Transition.pResource = r.spot_shadow_map
    shadow_barrier.Transition.StateBefore = SHADOW_READ_STATE
    shadow_barrier.Transition.StateAfter = {.DEPTH_WRITE}
    r.command_list->ResourceBarrier(1, &shadow_barrier)
    spot_viewport := d3d12.VIEWPORT{Width = SPOT_SHADOW_MAP_SIZE, Height = SPOT_SHADOW_MAP_SIZE, MaxDepth = 1}
    spot_scissor := d3d12.RECT{right = SPOT_SHADOW_MAP_SIZE, bottom = SPOT_SHADOW_MAP_SIZE}
    r.command_list->RSSetViewports(1, &spot_viewport)
    r.command_list->RSSetScissorRects(1, &spot_scissor)
    for slot in 0..<SPOT_SHADOW_COUNT {
        if r.spot_shadow_entities[slot] < 0 do continue
        dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
        r.spot_shadow_dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)
        dsv_handle.ptr += uint(slot) * uint(dsv_size)
        r.command_list->OMSetRenderTargets(0, nil, false, &dsv_handle)
        r.command_list->ClearDepthStencilView(dsv_handle, {.DEPTH}, 1.0, 0, 0, nil)
        view := SHADOW_CASCADE_COUNT + slot
        r.command_list->SetGraphicsRoot32BitConstant(u32(Root_Slot.Shadow_Cascade), u32(view), 0)
        renderer_draw_list(draws, view_draws[view], r.spot_shadow_pipeline_states)
    }
    shadow_barrier.Transition.StateBefore = {.DEPTH_WRITE}
    shadow_barrier.Transition.StateAfter = SHADOW_READ_STATE
    r.command_list->ResourceBarrier(1, &shadow_barrier)

    // Point lights: six cube faces per used slot, with the spot pipelines.
    shadow_barrier.Transition.pResource = r.point_shadow_map
    shadow_barrier.Transition.StateBefore = SHADOW_READ_STATE
    shadow_barrier.Transition.StateAfter = {.DEPTH_WRITE}
    r.command_list->ResourceBarrier(1, &shadow_barrier)
    point_viewport := d3d12.VIEWPORT{Width = POINT_SHADOW_MAP_SIZE, Height = POINT_SHADOW_MAP_SIZE, MaxDepth = 1}
    point_scissor := d3d12.RECT{right = POINT_SHADOW_MAP_SIZE, bottom = POINT_SHADOW_MAP_SIZE}
    r.command_list->RSSetViewports(1, &point_viewport)
    r.command_list->RSSetScissorRects(1, &point_scissor)
    for slot in 0..<POINT_SHADOW_COUNT {
        if r.point_shadow_entities[slot] < 0 do continue
        for face in 0..<POINT_SHADOW_FACES {
            face_index := slot * POINT_SHADOW_FACES + face
            dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
            r.point_shadow_dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)
            dsv_handle.ptr += uint(face_index) * uint(dsv_size)
            r.command_list->OMSetRenderTargets(0, nil, false, &dsv_handle)
            r.command_list->ClearDepthStencilView(dsv_handle, {.DEPTH}, 1.0, 0, 0, nil)
            view := POINT_SHADOW_FIRST_VIEW + face_index
            r.command_list->SetGraphicsRoot32BitConstant(u32(Root_Slot.Shadow_Cascade), u32(view), 0)
            renderer_draw_list(draws, view_draws[view], r.spot_shadow_pipeline_states)
        }
    }
    shadow_barrier.Transition.StateBefore = {.DEPTH_WRITE}
    shadow_barrier.Transition.StateAfter = SHADOW_READ_STATE
    r.command_list->ResourceBarrier(1, &shadow_barrier)

    renderer_end_gpu_pass(.Shadow)
}
