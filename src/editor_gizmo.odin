package main

import "core:math"
import alg "core:math/linalg"
import win32 "core:sys/windows"

// Viewport handles for the selected entity. Move and rotate use world or
// local axes (`space`); scale always uses the entity's local axes, because
// scale is applied before rotation (scaling along world axes would shear).
GizmoMode :: enum {Translate, Rotate, Scale}
GizmoHandle :: enum {None, X, Y, Z, Center}
GizmoSpace :: enum {World, Local}

GIZMO_SIZE_PIXELS :: f32(110)
GIZMO_PICK_PIXELS :: f32(8)
GIZMO_CENTER_PIXELS :: f32(7)
GIZMO_RING_SEGMENTS :: 64
// Uniform scale changes by e (about 2.7x) per 100 pixels of horizontal drag.
GIZMO_UNIFORM_SCALE_RATE :: f32(0.01)

EditorGizmo :: struct {
    mode: GizmoMode,
    space: GizmoSpace,
    hovered: GizmoHandle,
    active: GizmoHandle,

    // Snapping: drags move, rotate and scale in whole steps. Holding Ctrl
    // during a drag inverts `snap`.
    snap: bool,
    snap_distance: f32,      // World units.
    snap_angle_degrees: f32,
    snap_scale: f32,         // Added to (or, for uniform scale, multiplied into) the scale.

    // Drag state, captured when a handle is pressed.
    entity: Entity,
    field: EditorField,
    before: [3]f32,
    start_transform: Transform,
    start_rotation: alg.Matrix4f32,
    // Handle axes at the start; local axes would otherwise follow a spinning entity.
    start_axes: [3]alg.Vector3f32,
    start_param: f32,
    start_point: alg.Vector3f32,
    start_mouse_x: f32,
}

g_editor_gizmo := EditorGizmo{
    snap_distance = 0.25,
    snap_angle_degrees = 15,
    snap_scale = 0.1,
}

// Rounds `value` to a whole number of steps; unchanged when step is not positive.
gizmo_snap :: proc(value, step: f32) -> f32 {
    return math.round(value / step) * step if step > 0 else value
}

// Per-frame projection of the gizmo into the viewport.
GizmoView :: struct {
    view_projection: alg.Matrix4f32,
    width, height: f32,
    camera_forward: alg.Vector3f32,
    center: alg.Vector3f32,
    size: f32,
    axes: [3]alg.Vector3f32,
}

gizmo_color :: proc(r, g, b: u8, a: u8 = 255) -> u32 {
    // ImGui's IM_COL32 byte order.
    return u32(a) << 24 | u32(b) << 16 | u32(g) << 8 | u32(r)
}

gizmo_handle_color :: proc(handle: GizmoHandle) -> u32 {
    if handle == g_editor_gizmo.active ||
       (g_editor_gizmo.active == .None && handle == g_editor_gizmo.hovered) {
        return gizmo_color(255, 210, 60)
    }
    switch handle {
        case .X: return gizmo_color(230, 70, 70)
        case .Y: return gizmo_color(90, 200, 80)
        case .Z: return gizmo_color(70, 120, 240)
        case .Center, .None:
    }
    return gizmo_color(220, 220, 220)
}

gizmo_field :: proc(mode: GizmoMode) -> EditorField {
    switch mode {
        case .Translate: return .Position
        case .Rotate: return .Rotation
        case .Scale: return .Scale
    }
    return .Position
}

// Inverse of transform_rotation_matrix: Euler angles for R = Ry * Rx * Rz.
transform_rotation_from_matrix :: proc(m: alg.Matrix4f32) -> alg.Vector3f32 {
    sin_x := clamp(-m[1, 2], -1, 1)
    x := math.asin(sin_x)
    if math.abs(sin_x) < 0.9999 {
        return {x, math.atan2(m[0, 2], m[2, 2]), math.atan2(m[1, 0], m[1, 1])}
    }
    // Gimbal lock: yaw and roll share an axis, so fold everything into yaw.
    return {x, math.atan2(-m[2, 0], m[0, 0]), 0}
}

editor_gizmo_target :: proc(scene: ^Scene) -> (index: int, ok: bool) {
    if !scene_entity_is_alive(scene, g_editor_selected) {
        return -1, false
    }
    index = int(g_editor_selected)
    if !scene.has_transform[index] || scene.has_camera[index] {
        return -1, false
    }
    return index, true
}

// An orbiting point light's position is driven by its orbit, not the gizmo.
editor_gizmo_blocked :: proc(scene: ^Scene, index: int) -> bool {
    return g_editor_gizmo.mode == .Translate &&
           scene.has_point_light[index] &&
           scene.point_lights[index].orbit_enabled
}

gizmo_project :: proc(view: GizmoView, point: alg.Vector3f32) -> (screen: [2]f32, ok: bool) {
    // Row-vector convention: clip coordinates are dot products with columns.
    m := view.view_projection
    clip: [4]f32
    for j in 0..<4 {
        clip[j] = point.x * m[0, j] + point.y * m[1, j] + point.z * m[2, j] + m[3, j]
    }
    if clip[3] <= CAMERA_NEAR_CLIP * 0.5 {
        return {}, false
    }
    ndc_x := clip[0] / clip[3]
    ndc_y := clip[1] / clip[3]
    return {(ndc_x * 0.5 + 0.5) * view.width, (0.5 - ndc_y * 0.5) * view.height}, true
}

gizmo_segment_distance :: proc(point, a, b: [2]f32) -> f32 {
    ab := b - a
    length_squared := ab.x * ab.x + ab.y * ab.y
    t: f32 = 0
    if length_squared > 0 {
        ap := point - a
        t = clamp((ap.x * ab.x + ap.y * ab.y) / length_squared, 0, 1)
    }
    d := point - (a + ab * t)
    return math.sqrt(d.x * d.x + d.y * d.y)
}

gizmo_ring_point :: proc(view: GizmoView, axis: int, angle: f32) -> alg.Vector3f32 {
    u := view.axes[(axis + 1) % 3]
    v := view.axes[(axis + 2) % 3]
    return view.center + (u * math.cos(angle) + v * math.sin(angle)) * view.size * 0.9
}

editor_gizmo_view :: proc(scene: ^Scene, index: int) -> (view: GizmoView, ok: bool) {
    r := &g_renderer
    camera_index := camera_find_active(scene)
    if camera_index < 0 || r.width == 0 || r.height == 0 {
        return {}, false
    }

    camera := &scene.cameras[camera_index]
    camera_position := scene.transforms[camera_index].position
    aspect := f32(r.width) / f32(r.height)

    view.width = f32(r.width)
    view.height = f32(r.height)
    view.camera_forward = camera_forward(camera)
    view.view_projection = camera_view_matrix(camera, camera_position) *
                           camera_projection(camera, aspect)

    transform := scene.transforms[index]
    view.center = transform.position

    // Keep a constant on-screen size regardless of distance.
    depth := alg.dot(view.center - camera_position, view.camera_forward)
    if depth <= CAMERA_NEAR_CLIP {
        return {}, false
    }
    view.size = depth * math.tan(CAMERA_FOV_Y * 0.5) * 2 * GIZMO_SIZE_PIXELS / view.height

    view.axes = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
    if g_editor_gizmo.mode == .Scale || g_editor_gizmo.space == .Local {
        rotation := transform_rotation_matrix(transform.rotation)
        for i in 0..<3 {
            view.axes[i] = alg.normalize(alg.Vector3f32{rotation[0, i], rotation[1, i], rotation[2, i]})
        }
    }
    return view, true
}

editor_gizmo_hit :: proc(view: GizmoView, mouse: [2]f32) -> GizmoHandle {
    center, center_ok := gizmo_project(view, view.center)
    if !center_ok {
        return .None
    }

    if g_editor_gizmo.mode != .Rotate {
        d := mouse - center
        if math.abs(d.x) <= GIZMO_CENTER_PIXELS && math.abs(d.y) <= GIZMO_CENTER_PIXELS {
            return .Center
        }
    }

    best := GizmoHandle.None
    best_distance := GIZMO_PICK_PIXELS
    for axis in 0..<3 {
        distance := max(f32)
        if g_editor_gizmo.mode == .Rotate {
            previous, previous_ok := gizmo_project(view, gizmo_ring_point(view, axis, 0))
            for segment in 1..=GIZMO_RING_SEGMENTS {
                angle := f32(segment) / GIZMO_RING_SEGMENTS * 2 * math.PI
                current, current_ok := gizmo_project(view, gizmo_ring_point(view, axis, angle))
                if previous_ok && current_ok {
                    distance = min(distance, gizmo_segment_distance(mouse, previous, current))
                }
                previous, previous_ok = current, current_ok
            }
        } else {
            tip, tip_ok := gizmo_project(view, view.center + view.axes[axis] * view.size)
            if !tip_ok || gizmo_axis_hidden(center, tip) {
                continue
            }
            distance = gizmo_segment_distance(mouse, center, tip)
        }

        if distance < best_distance {
            best_distance = distance
            best = GizmoHandle(int(GizmoHandle.X) + axis)
        }
    }
    return best
}

// An axis pointing almost straight at the camera cannot be dragged usefully.
gizmo_axis_hidden :: proc(center, tip: [2]f32) -> bool {
    d := tip - center
    return d.x * d.x + d.y * d.y < 12 * 12
}

editor_gizmo_draw :: proc(view: GizmoView) {
    center, center_ok := gizmo_project(view, view.center)
    if !center_ok {
        return
    }

    for axis in 0..<3 {
        handle := GizmoHandle(int(GizmoHandle.X) + axis)
        color := gizmo_handle_color(handle)

        if g_editor_gizmo.mode == .Rotate {
            previous, previous_ok := gizmo_project(view, gizmo_ring_point(view, axis, 0))
            for segment in 1..=GIZMO_RING_SEGMENTS {
                angle := f32(segment) / GIZMO_RING_SEGMENTS * 2 * math.PI
                current, current_ok := gizmo_project(view, gizmo_ring_point(view, axis, angle))
                if previous_ok && current_ok {
                    ui_draw_line(previous.x, previous.y, current.x, current.y, color, 2.5)
                }
                previous, previous_ok = current, current_ok
            }
            continue
        }

        tip, tip_ok := gizmo_project(view, view.center + view.axes[axis] * view.size)
        if !tip_ok || gizmo_axis_hidden(center, tip) {
            continue
        }
        ui_draw_line(center.x, center.y, tip.x, tip.y, color, 3)

        direction := alg.normalize(tip - center)
        side := [2]f32{-direction.y, direction.x}
        if g_editor_gizmo.mode == .Translate {
            point := tip + direction * 12
            left := tip + side * 6
            right := tip - side * 6
            ui_draw_triangle(point.x, point.y, left.x, left.y, right.x, right.y, color)
        } else {
            ui_draw_rect(tip.x - 5, tip.y - 5, tip.x + 5, tip.y + 5, color)
        }
    }

    if g_editor_gizmo.mode != .Rotate {
        color := gizmo_handle_color(.Center)
        ui_draw_rect(
            center.x - GIZMO_CENTER_PIXELS, center.y - GIZMO_CENTER_PIXELS,
            center.x + GIZMO_CENTER_PIXELS, center.y + GIZMO_CENTER_PIXELS,
            color,
        )
    }
}

// Closest-approach parameter along the line center + s * axis to the ray.
gizmo_axis_param :: proc(ray: EditorRay, center, axis: alg.Vector3f32) -> (s: f32, ok: bool) {
    b := alg.dot(axis, ray.direction)
    denominator := 1 - b * b
    if denominator < 0.0001 {
        return 0, false
    }
    w := center - ray.origin
    return (b * alg.dot(ray.direction, w) - alg.dot(axis, w)) / denominator, true
}

gizmo_plane_hit :: proc(ray: EditorRay, point, normal: alg.Vector3f32) -> (hit: alg.Vector3f32, ok: bool) {
    denominator := alg.dot(ray.direction, normal)
    if math.abs(denominator) < 0.0001 {
        return {}, false
    }
    t := alg.dot(point - ray.origin, normal) / denominator
    if t <= 0 {
        return {}, false
    }
    return ray.origin + ray.direction * t, true
}

editor_gizmo_begin :: proc(scene: ^Scene, index: int, view: GizmoView, handle: GizmoHandle, mouse: SceneMouse) {
    ray, ray_ok := editor_mouse_ray(scene, mouse.x, mouse.y)
    if !ray_ok {
        return
    }

    gizmo := &g_editor_gizmo
    transform := scene.transforms[index]
    axis_index := int(handle) - int(GizmoHandle.X)

    switch {
        case handle == .Center && gizmo.mode == .Translate:
            hit, ok := gizmo_plane_hit(ray, view.center, view.camera_forward)
            if !ok do return
            gizmo.start_point = hit
        case handle == .Center && gizmo.mode == .Scale:
            gizmo.start_mouse_x = mouse.x
        case gizmo.mode == .Rotate:
            hit, ok := gizmo_plane_hit(ray, view.center, view.axes[axis_index])
            if !ok do return
            gizmo.start_point = hit - view.center
        case:
            // The view's axes: local for scale and in local space, else world.
            s, ok := gizmo_axis_param(ray, view.center, view.axes[axis_index])
            if !ok do return
            gizmo.start_param = s
    }

    editor_finish_edit()
    gizmo.active = handle
    gizmo.entity = Entity(index)
    gizmo.field = gizmo_field(gizmo.mode)
    gizmo.before = editor_value(scene, index, gizmo.field)
    gizmo.start_transform = transform
    gizmo.start_rotation = transform_rotation_matrix(transform.rotation)
    gizmo.start_axes = view.axes
}

editor_gizmo_drag :: proc(scene: ^Scene, view: GizmoView, mouse: SceneMouse) {
    gizmo := &g_editor_gizmo
    ray, ray_ok := editor_mouse_ray(scene, mouse.x, mouse.y)
    if !ray_ok {
        return
    }

    start := gizmo.start_transform
    axis_index := int(gizmo.active) - int(GizmoHandle.X)
    snap := gizmo.snap != key_down(win32.VK_CONTROL)
    value: [3]f32

    // Snapping counts steps from where the drag started (increments, not a
    // grid), so the same steps work in world and local space.
    switch {
        case gizmo.active == .Center && gizmo.mode == .Translate:
            hit, ok := gizmo_plane_hit(ray, start.position, view.camera_forward)
            if !ok do return
            delta := hit - gizmo.start_point
            if snap {
                // Whole steps along each of the handle axes.
                snapped: alg.Vector3f32
                for axis in gizmo.start_axes {
                    snapped += axis * gizmo_snap(alg.dot(delta, axis), gizmo.snap_distance)
                }
                delta = snapped
            }
            value = start.position + delta

        case gizmo.active == .Center && gizmo.mode == .Scale:
            factor := math.exp((mouse.x - gizmo.start_mouse_x) * GIZMO_UNIFORM_SCALE_RATE)
            if snap {
                // Proportional steps, e.g. 0.1 = 10% of the starting size.
                factor = max(1 + gizmo_snap(factor - 1, gizmo.snap_scale), gizmo.snap_scale)
            }
            value = start.scale * factor

        case gizmo.mode == .Rotate:
            axis := gizmo.start_axes[axis_index]
            hit, ok := gizmo_plane_hit(ray, start.position, axis)
            if !ok do return
            current := hit - start.position
            angle := math.atan2(
                alg.dot(axis, alg.cross(gizmo.start_point, current)),
                alg.dot(gizmo.start_point, current),
            )
            if snap do angle = gizmo_snap(angle, math.to_radians(gizmo.snap_angle_degrees))
            // Rotating about a local axis (R applied to e_i) equals R * rotate(e_i).
            rotation := alg.matrix4_rotate_f32(angle, axis) * gizmo.start_rotation
            value = transform_rotation_from_matrix(rotation)

        case gizmo.mode == .Translate:
            axis := gizmo.start_axes[axis_index]
            s, ok := gizmo_axis_param(ray, start.position, axis)
            if !ok do return
            distance := s - gizmo.start_param
            if snap do distance = gizmo_snap(distance, gizmo.snap_distance)
            value = start.position + axis * distance

        case:
            // Scale along one local axis by how far the handle moved along it.
            axis := gizmo.start_axes[axis_index]
            s, ok := gizmo_axis_param(ray, start.position, axis)
            if !ok || math.abs(gizmo.start_param) < 0.000001 do return
            value = start.scale
            value[axis_index] *= s / gizmo.start_param
            if snap {
                change := gizmo_snap(value[axis_index] - start.scale[axis_index], gizmo.snap_scale)
                value[axis_index] = start.scale[axis_index] + change
            }
    }

    editor_apply_value(scene, gizmo.entity, gizmo.field, value)
}

editor_gizmo_end :: proc(scene: ^Scene, cancel: bool) {
    gizmo := &g_editor_gizmo
    if gizmo.active == .None {
        return
    }

    index := int(gizmo.entity)
    if cancel {
        editor_apply_value(scene, gizmo.entity, gizmo.field, gizmo.before)
    } else if editor_field_exists(scene, index, gizmo.field) {
        editor_push_command(EditorCommand{
            kind = .Edit_Field,
            entity = gizmo.entity,
            field = gizmo.field,
            before = gizmo.before,
            after = editor_value(scene, index, gizmo.field),
        })
    }
    gizmo.active = .None
}

// Runs inside the ImGui frame, before scene picking, so a click on a handle
// starts a drag instead of changing the selection.
editor_update_gizmo :: proc(scene: ^Scene) {
    gizmo := &g_editor_gizmo
    gizmo.hovered = .None

    index, has_target := editor_gizmo_target(scene)
    if !has_target || int(gizmo.entity) != index {
        // The selection changed or vanished underneath an active drag.
        gizmo.active = .None
    }
    if g_cursor_locked {
        editor_gizmo_end(scene, false)
        return
    }
    if !has_target || editor_gizmo_blocked(scene, index) {
        return
    }

    view, view_ok := editor_gizmo_view(scene, index)
    if !view_ok {
        editor_gizmo_end(scene, false)
        return
    }

    mouse: SceneMouse
    ui_scene_mouse(&mouse)

    if gizmo.active != .None {
        if mouse.cancel {
            editor_gizmo_end(scene, true)
        } else if mouse.down {
            editor_gizmo_drag(scene, view, mouse)
        } else {
            editor_gizmo_end(scene, false)
        }
    } else if !mouse.over_ui {
        gizmo.hovered = editor_gizmo_hit(view, {mouse.x, mouse.y})
        if mouse.clicked && gizmo.hovered != .None {
            editor_gizmo_begin(scene, index, view, gizmo.hovered, mouse)
        }
    }

    editor_gizmo_draw(view)
}

// Whether the gizmo owns the mouse this frame, so scene picking stays out.
editor_gizmo_has_mouse :: proc() -> bool {
    return g_editor_gizmo.active != .None || g_editor_gizmo.hovered != .None
}

editor_draw_gizmo_controls :: proc() {
    gizmo := &g_editor_gizmo
    labels := [GizmoMode]cstring{.Translate = "Move (W)", .Rotate = "Rotate (E)", .Scale = "Scale (R)"}
    for mode in GizmoMode {
        if mode != .Translate do ui_same_line()
        if ui_radio_button(labels[mode], gizmo.mode == mode) && gizmo.active == .None {
            gizmo.mode = mode
        }
    }

    // Scale always uses local axes, so the space choice does not apply to it.
    ui_begin_disabled(gizmo.mode == .Scale || gizmo.active != .None)
    space_labels := [GizmoSpace]cstring{.World = "World", .Local = "Local (Q)"}
    for space in GizmoSpace {
        if space != .World do ui_same_line()
        if ui_radio_button(space_labels[space], gizmo.space == space) do gizmo.space = space
    }
    ui_end_disabled()

    ui_checkbox("Snap (hold Ctrl to toggle)", &gizmo.snap)
    ui_drag_float("Move step", &gizmo.snap_distance, 0.01, 0.01, 100)
    ui_drag_float("Rotate step (degrees)", &gizmo.snap_angle_degrees, 0.5, 1, 180)
    ui_drag_float("Scale step", &gizmo.snap_scale, 0.01, 0.01, 10)
    debug_ui_text("Drag handles in the viewport; right-click cancels.")
}
