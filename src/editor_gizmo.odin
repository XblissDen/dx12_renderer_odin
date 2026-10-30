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

    // Drag state, captured when a handle is pressed. The handles sit on the
    // primary selection (`entity`); the rest of the selection follows it.
    // Drags work in world space; each target converts the change into its
    // parent's space.
    entity: Entity,
    // Handle axes at the start; local axes would otherwise follow a spinning entity.
    start_axes: [3]alg.Vector3f32,
    start_param: f32,
    start_point: alg.Vector3f32,
    start_mouse_x: f32,
    // Every entity the drag moves, the primary first.
    targets: [dynamic]GizmoTarget,
}

// An entity a drag moves, as it was when the drag started.
GizmoTarget :: struct {
    entity: Entity,
    transform: Transform,
    // Position, or an orbiting light's orbit center (see editor_position_field).
    position_field: EditorField,
    position_value: [3]f32,
    world_position: alg.Vector3f32,
    // The space its transform is in: the parent's world matrix.
    parent, parent_inverse: alg.Matrix4f32,
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

// What moving an entity edits: an orbiting point light's position comes from
// its orbit, so moving one moves the orbit's center instead (the handles stay
// on the light).
editor_position_field :: proc(scene: ^Scene, index: int) -> EditorField {
    if scene.has_point_light[index] && scene.point_lights[index].orbit_enabled {
        return .Point_Orbit_Center
    }
    return .Position
}

// The fields a drag in the current mode changes on a target. Other entities
// move around the primary when rotated or scaled, so their position changes too.
gizmo_target_fields :: proc(target: GizmoTarget) -> (fields: [2]EditorField, count: int) {
    switch g_editor_gizmo.mode {
        case .Translate: return {target.position_field, {}}, 1
        case .Rotate: return {.Rotation, target.position_field}, 2
        case .Scale: return {.Scale, target.position_field}, 2
    }
    return {}, 0
}

gizmo_target_before :: proc(target: GizmoTarget, field: EditorField) -> [3]f32 {
    #partial switch field {
        case .Rotation: return target.transform.rotation
        case .Scale: return target.transform.scale
    }
    return target.position_value
}

// Moves a target so its entity ends up at world `position` (an orbiting
// light's orbit center moves by as much).
gizmo_move_target :: proc(scene: ^Scene, target: GizmoTarget, position: alg.Vector3f32) {
    offset := position - target.world_position
    local := alg.mul(target.parent_inverse, alg.Vector4f32{offset.x, offset.y, offset.z, 0})
    editor_apply_value(scene, target.entity, target.position_field, alg.Vector3f32(target.position_value) + local.xyz)
}

// Turns a target about its own origin by the world rotation `turn`.
gizmo_turn_target :: proc(scene: ^Scene, target: GizmoTarget, turn: alg.Matrix4f32) {
    // The turn as seen in the parent's space: still a pure rotation unless an
    // ancestor is scaled unevenly, when only its nearest rotation is kept.
    rotation := target.parent_inverse * turn * target.parent * transform_rotation_matrix(target.transform.rotation)
    editor_apply_value(scene, target.entity, .Rotation, transform_from_matrix(rotation).rotation)
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

    world := scene_world_matrix(scene, index)
    view.center = {world[0, 3], world[1, 3], world[2, 3]}

    // Keep a constant on-screen size regardless of distance.
    depth := alg.dot(view.center - camera_position, view.camera_forward)
    if depth <= CAMERA_NEAR_CLIP {
        return {}, false
    }
    view.size = depth * math.tan(CAMERA_FOV_Y * 0.5) * 2 * GIZMO_SIZE_PIXELS / view.height

    view.axes = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
    // Local axes include the ancestors' rotation.
    if g_editor_gizmo.mode == .Scale || g_editor_gizmo.space == .Local {
        for i in 0..<3 {
            view.axes[i] = alg.normalize(alg.Vector3f32{world[0, i], world[1, i], world[2, i]})
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
    gizmo.start_axes = view.axes

    clear(&gizmo.targets)
    append(&gizmo.targets, gizmo_target(scene, index))
    for selected, other in g_editor_selection {
        if !selected || other == index do continue
        // The sun's transform does nothing (and its scale is zero).
        if !scene.has_transform[other] || scene.has_camera[other] || scene.has_directional_light[other] do continue
        if gizmo_moved_by_ancestor(scene, other, index) do continue
        append(&gizmo.targets, gizmo_target(scene, other))
    }
}

// Whether a selected entity already moves with another target, or moving it
// would move the primary again: it is the primary's ancestor, or it has a
// selected ancestor that is the primary or moves itself (one that is not the
// primary's ancestor).
gizmo_moved_by_ancestor :: proc(scene: ^Scene, index, primary: int) -> bool {
    if scene_is_ancestor(scene, index, primary) do return true
    current := index
    for _ in 0..<MAX_ENTITIES {
        parent := scene_parent(scene, current) or_break
        if editor_is_selected(Entity(parent)) && (parent == primary || !scene_is_ancestor(scene, parent, primary)) {
            return true
        }
        current = parent
    }
    return false
}

gizmo_target :: proc(scene: ^Scene, index: int) -> GizmoTarget {
    field := editor_position_field(scene, index)
    parent := scene_parent_matrix(scene, index)
    return {
        entity = Entity(index),
        transform = scene.transforms[index],
        position_field = field,
        position_value = editor_value(scene, index, field),
        world_position = scene_world_position(scene, index),
        parent = parent,
        parent_inverse = alg.matrix4_inverse_f32(parent),
    }
}

editor_gizmo_drag :: proc(scene: ^Scene, view: GizmoView, mouse: SceneMouse) {
    gizmo := &g_editor_gizmo
    ray, ray_ok := editor_mouse_ray(scene, mouse.x, mouse.y)
    if !ray_ok {
        return
    }

    start := gizmo.targets[0]
    pivot := start.world_position
    axis_index := int(gizmo.active) - int(GizmoHandle.X)
    snap := gizmo.snap != key_down(win32.VK_CONTROL)
    // The primary's change in world space, which the whole selection follows.
    delta: alg.Vector3f32
    turn := alg.MATRIX4F32_IDENTITY
    scale := start.transform.scale

    // Snapping counts steps from where the drag started (increments, not a
    // grid), so the same steps work in world and local space.
    switch {
        case gizmo.active == .Center && gizmo.mode == .Translate:
            hit, ok := gizmo_plane_hit(ray, pivot, view.camera_forward)
            if !ok do return
            delta = hit - gizmo.start_point
            if snap {
                // Whole steps along each of the handle axes.
                snapped: alg.Vector3f32
                for axis in gizmo.start_axes {
                    snapped += axis * gizmo_snap(alg.dot(delta, axis), gizmo.snap_distance)
                }
                delta = snapped
            }

        case gizmo.active == .Center && gizmo.mode == .Scale:
            factor := math.exp((mouse.x - gizmo.start_mouse_x) * GIZMO_UNIFORM_SCALE_RATE)
            if snap {
                // Proportional steps, e.g. 0.1 = 10% of the starting size.
                factor = max(1 + gizmo_snap(factor - 1, gizmo.snap_scale), gizmo.snap_scale)
            }
            scale *= factor

        case gizmo.mode == .Rotate:
            axis := gizmo.start_axes[axis_index]
            hit, ok := gizmo_plane_hit(ray, pivot, axis)
            if !ok do return
            current := hit - pivot
            angle := math.atan2(
                alg.dot(axis, alg.cross(gizmo.start_point, current)),
                alg.dot(gizmo.start_point, current),
            )
            if snap do angle = gizmo_snap(angle, math.to_radians(gizmo.snap_angle_degrees))
            turn = alg.matrix4_rotate_f32(angle, axis)

        case gizmo.mode == .Translate:
            axis := gizmo.start_axes[axis_index]
            s, ok := gizmo_axis_param(ray, pivot, axis)
            if !ok do return
            distance := s - gizmo.start_param
            if snap do distance = gizmo_snap(distance, gizmo.snap_distance)
            delta = axis * distance

        case:
            // Scale along one local axis by how far the handle moved along it.
            axis := gizmo.start_axes[axis_index]
            s, ok := gizmo_axis_param(ray, pivot, axis)
            if !ok || math.abs(gizmo.start_param) < 0.000001 do return
            scale[axis_index] *= s / gizmo.start_param
            if snap {
                change := gizmo_snap(scale[axis_index] - start.transform.scale[axis_index], gizmo.snap_scale)
                scale[axis_index] = start.transform.scale[axis_index] + change
            }
    }

    // Every target moves by the same amount, or turns and scales around the
    // primary (its position is the pivot), each also turning or scaling
    // about its own origin.
    factor := scale / start.transform.scale
    for target in gizmo.targets {
        offset := target.world_position - pivot
        switch gizmo.mode {
            case .Translate:
                gizmo_move_target(scene, target, target.world_position + delta)
            case .Rotate:
                gizmo_turn_target(scene, target, turn)
                turned := alg.mul(turn, alg.Vector4f32{offset.x, offset.y, offset.z, 0})
                gizmo_move_target(scene, target, pivot + turned.xyz)
            case .Scale:
                // Along the primary's local axes; each entity scales its own
                // local axes by the same factors.
                target_scale := scale if target.entity == gizmo.entity else target.transform.scale * factor
                editor_apply_value(scene, target.entity, .Scale, target_scale)
                scaled := pivot
                for axis, i in gizmo.start_axes {
                    scaled += axis * alg.dot(offset, axis) * factor[i]
                }
                gizmo_move_target(scene, target, scaled)
        }
    }
}

editor_gizmo_end :: proc(scene: ^Scene, cancel: bool) {
    gizmo := &g_editor_gizmo
    if gizmo.active == .None {
        return
    }

    // One undo step for the whole selection.
    edits := make([dynamic]EditorFieldEdit, context.temp_allocator)
    for target in gizmo.targets {
        fields, count := gizmo_target_fields(target)
        for field in fields[:count] {
            before := gizmo_target_before(target, field)
            if cancel {
                editor_apply_value(scene, target.entity, field, before)
            } else if editor_field_exists(scene, int(target.entity), field) {
                append(&edits, EditorFieldEdit{
                    entity = target.entity,
                    field = field,
                    before = before,
                    after = editor_value(scene, int(target.entity), field),
                })
            }
        }
    }
    editor_push_field_edits(edits[:], gizmo.entity)
    gizmo.active = .None
}

// Runs inside the ImGui frame, before scene picking, so a click on a handle
// starts a drag instead of changing the selection.
editor_update_gizmo :: proc(scene: ^Scene) {
    gizmo := &g_editor_gizmo
    gizmo.hovered = .None

    index, has_target := editor_gizmo_target(scene)
    if !has_target || int(gizmo.entity) != index {
        // The selection changed or vanished underneath a drag: what it did
        // so far still becomes an undo step, for the entities still there.
        editor_gizmo_end(scene, false)
    }
    if g_cursor_locked {
        editor_gizmo_end(scene, false)
        return
    }
    if !has_target {
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
