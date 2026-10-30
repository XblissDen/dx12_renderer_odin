package main

import "core:math"
import alg "core:math/linalg"
import "core:slice"

// Viewport helpers: icons for entities with nothing to draw, which could not
// be clicked otherwise, and debug lines (light ranges, orbits, mesh bounds).
EditorViewport :: struct {
    icons: bool,
    // Every light's range and orbit, not only the selected lights'.
    all_light_ranges: bool,
    mesh_bounds: bool,
}
g_editor_viewport := EditorViewport{icons = true}

ICON_RADIUS_PIXELS :: f32(10)
ICON_PICK_PIXELS :: f32(13)
LINE_CIRCLE_SEGMENTS :: 48

EditorIcon :: struct {
    entity: Entity,
    screen: [2]f32,
    distance: f32, // From the camera, for picking order.
}

// The camera's projection onto the window, as the gizmo uses it.
editor_viewport_view :: proc(scene: ^Scene) -> (view: GizmoView, camera_position: alg.Vector3f32, far_clip: f32, ok: bool) {
    r := &g_renderer
    camera_index := camera_find_active(scene)
    if camera_index < 0 || r.width == 0 || r.height == 0 {
        return {}, {}, 0, false
    }
    camera := &scene.cameras[camera_index]
    camera_position = scene.transforms[camera_index].position
    view.width = f32(r.width)
    view.height = f32(r.height)
    view.camera_forward = camera_forward(camera)
    view.view_projection = camera_view_matrix(camera, camera_position) *
                           camera_projection(camera, view.width / view.height)
    return view, camera_position, camera_far_clip(camera), true
}

// Entities that get an icon: placed ones (not the camera) without a drawable
// mesh, such as empty entities and lights without a marker.
editor_has_icon :: proc(scene: ^Scene, index: int) -> bool {
    if !scene.alive[index] || !scene.has_transform[index] || scene.has_camera[index] {
        return false
    }
    _, _, drawable := editor_entity_bounds(scene, Entity(index))
    return !drawable
}

// The icons in view, nearest first.
editor_icons :: proc(scene: ^Scene) -> [dynamic]EditorIcon {
    icons := make([dynamic]EditorIcon, context.temp_allocator)
    view, camera_position, far_clip, ok := editor_viewport_view(scene)
    if !ok do return icons
    for i in 0..<scene.entity_count {
        if !editor_has_icon(scene, i) do continue
        position := scene_world_position(scene, i)
        if alg.dot(position - camera_position, view.camera_forward) > far_clip do continue
        screen := gizmo_project(view, position) or_continue
        if screen.x < -ICON_PICK_PIXELS || screen.y < -ICON_PICK_PIXELS ||
           screen.x > view.width + ICON_PICK_PIXELS || screen.y > view.height + ICON_PICK_PIXELS {
            continue
        }
        append(&icons, EditorIcon{Entity(i), screen, alg.length(position - camera_position)})
    }
    slice.sort_by(icons[:], proc(a, b: EditorIcon) -> bool { return a.distance < b.distance })
    return icons
}

// The icons under the mouse, nearest first, as pick hits. They are drawn over
// the scene, so they come before every mesh hit.
editor_pick_icons :: proc(scene: ^Scene, mouse: [2]f32) -> [dynamic]EditorPickHit {
    hits := make([dynamic]EditorPickHit, context.temp_allocator)
    if !g_debug_ui_visible || !g_editor_viewport.icons do return hits
    for icon in editor_icons(scene) {
        if alg.length(mouse - icon.screen) <= ICON_PICK_PIXELS {
            append(&hits, EditorPickHit{icon.entity, icon.distance})
        }
    }
    return hits
}

// A light's color at full brightness, for its icon and lines.
editor_light_display_color :: proc(color: [3]f32, alpha: u8) -> u32 {
    peak := max(color.r, color.g, color.b)
    if peak <= 0.001 do return gizmo_color(255, 255, 255, alpha)
    c := color / peak
    return gizmo_color(u8(c.r * 255), u8(c.g * 255), u8(c.b * 255), alpha)
}

// Behind the panels (on ImGui's background list), farthest first so nearer
// icons cover farther ones. Light icons are a disc in the light's color with
// rays (a spot light's point along its beam); empty entities get a diamond.
editor_draw_icons :: proc(scene: ^Scene) {
    if !g_editor_viewport.icons do return
    view, _, _, view_ok := editor_viewport_view(scene)
    if !view_ok do return

    icons := editor_icons(scene)
    #reverse for icon in icons {
        index := int(icon.entity)
        center := icon.screen
        radius := ICON_RADIUS_PIXELS
        ui_draw_circle(center.x, center.y, radius + 2, gizmo_color(20, 20, 24, 170), 0)

        if scene.has_point_light[index] || scene.has_spot_light[index] {
            color_value := scene.point_lights[index].color if scene.has_point_light[index] else scene.spot_lights[index].color
            color := editor_light_display_color(color_value, 255)
            ui_draw_circle(center.x, center.y, radius * 0.45, color, 0)
            if scene.has_spot_light[index] {
                // Three rays fanning out along the beam's direction on screen.
                world := scene_world_matrix(scene, index)
                position := alg.Vector3f32{world[0, 3], world[1, 3], world[2, 3]}
                beam := position + spot_light_direction(world) * icon.distance * 0.1
                beam_screen, beam_ok := gizmo_project(view, beam)
                direction := beam_screen - center
                if !beam_ok || alg.length(direction) < 0.5 do direction = {0, 1}
                angle := math.atan2(direction.y, direction.x)
                for offset in ([3]f32{-0.6, 0, 0.6}) {
                    ray := [2]f32{math.cos(angle + offset), math.sin(angle + offset)}
                    a := center + ray * radius * 0.65
                    b := center + ray * radius * 1.1
                    ui_draw_line(a.x, a.y, b.x, b.y, color, 1.5)
                }
            } else {
                for ray_index in 0..<8 {
                    angle := f32(ray_index) * math.PI / 4
                    ray := [2]f32{math.cos(angle), math.sin(angle)}
                    a := center + ray * radius * 0.65
                    b := center + ray * radius
                    ui_draw_line(a.x, a.y, b.x, b.y, color, 1.5)
                }
            }
        } else {
            color := gizmo_color(225, 225, 230)
            corners := [4][2]f32{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
            for corner, c in corners {
                a := center + corner * radius * 0.75
                b := center + corners[(c + 1) % 4] * radius * 0.75
                ui_draw_line(a.x, a.y, b.x, b.y, color, 1.5)
            }
        }

        if editor_is_selected(icon.entity) {
            ring := gizmo_color(255, 166, 20) if icon.entity == g_editor_selected else gizmo_color(140, 77, 13)
            ui_draw_circle(center.x, center.y, radius + 2, ring, 2)
        }
    }
}

editor_line :: proc(lines: ^[dynamic]DebugLineVertex, a, b: alg.Vector3f32, color: u32) {
    append(lines, DebugLineVertex{a, color}, DebugLineVertex{b, color})
}

// A circle around `center` in the plane of `u` and `v` (unit and at right
// angles to each other).
editor_line_circle :: proc(lines: ^[dynamic]DebugLineVertex, center, u, v: alg.Vector3f32, radius: f32, color: u32) {
    previous := center + u * radius
    for segment in 1..=LINE_CIRCLE_SEGMENTS {
        angle := f32(segment) / LINE_CIRCLE_SEGMENTS * 2 * math.PI
        current := center + (u * math.cos(angle) + v * math.sin(angle)) * radius
        editor_line(lines, previous, current, color)
        previous = current
    }
}

// Two unit vectors at right angles to `axis` (unit) and each other, the first
// as close to `hint` as possible.
editor_line_basis :: proc(axis, hint: alg.Vector3f32) -> (u, v: alg.Vector3f32) {
    u = hint - axis * alg.dot(hint, axis)
    if alg.length(u) < 0.001 {
        other := alg.Vector3f32{0, 1, 0} if math.abs(axis.y) < 0.9 else alg.Vector3f32{1, 0, 0}
        u = other - axis * alg.dot(other, axis)
    }
    u = alg.normalize(u)
    return u, alg.cross(axis, u)
}

// A point light's range: a circle in each axis plane, plus the sphere's
// outline as the camera sees it.
editor_lines_point_range :: proc(lines: ^[dynamic]DebugLineVertex, center, camera_position: alg.Vector3f32, range: f32, color: u32) {
    x, y, z := alg.Vector3f32{1, 0, 0}, alg.Vector3f32{0, 1, 0}, alg.Vector3f32{0, 0, 1}
    editor_line_circle(lines, center, x, y, range, color)
    editor_line_circle(lines, center, y, z, range, color)
    editor_line_circle(lines, center, z, x, range, color)

    // From outside, the sphere's silhouette is the circle where the lines
    // from the eye touch it: nearer than the center, and a little smaller.
    to_center := center - camera_position
    distance := alg.length(to_center)
    if distance > range * 1.001 {
        toward := to_center / distance
        u, v := editor_line_basis(toward, y)
        offset := range * range / distance
        editor_line_circle(lines, center - toward * offset, u, v, range * math.sqrt(distance * distance - range * range) / distance, color)
    }
}

// A spot light's cone: the circle where the outer angle meets the range
// sphere, the four edges to it, and the inner angle's circle.
editor_lines_spot_cone :: proc(lines: ^[dynamic]DebugLineVertex, world: alg.Matrix4f32, light: SpotLight, color, inner_color: u32) {
    apex := alg.Vector3f32{world[0, 3], world[1, 3], world[2, 3]}
    direction := spot_light_direction(world)
    u, v := editor_line_basis(direction, {world[0, 0], world[1, 0], world[2, 0]})

    outer_center := apex + direction * light.range * math.cos(light.outer_angle)
    outer_radius := light.range * math.sin(light.outer_angle)
    editor_line_circle(lines, outer_center, u, v, outer_radius, color)
    for edge in ([4]alg.Vector3f32{u, -u, v, -v}) {
        editor_line(lines, apex, outer_center + edge * outer_radius, color)
    }
    if light.inner_angle > 0.001 && light.inner_angle < light.outer_angle - 0.001 {
        inner_center := apex + direction * light.range * math.cos(light.inner_angle)
        editor_line_circle(lines, inner_center, u, v, light.range * math.sin(light.inner_angle), inner_color)
    }
}

// A mesh's local bounding box, placed by its world matrix.
editor_lines_box :: proc(lines: ^[dynamic]DebugLineVertex, bounds: MeshBounds, world: alg.Matrix4f32, color: u32) {
    corners: [8]alg.Vector3f32
    for &corner, i in corners {
        local := alg.Vector3f32{
            bounds.maximum.x if i & 1 != 0 else bounds.minimum.x,
            bounds.maximum.y if i & 2 != 0 else bounds.minimum.y,
            bounds.maximum.z if i & 4 != 0 else bounds.minimum.z,
        }
        corner = alg.mul(world, alg.Vector4f32{local.x, local.y, local.z, 1}).xyz
    }
    // Corners differing in one bit share an edge.
    for i in 0..<8 {
        for bit in ([3]int{1, 2, 4}) {
            if i & bit == 0 do editor_line(lines, corners[i], corners[i | bit], color)
        }
    }
}

// This frame's debug lines, in world space, for renderer_render_debug_lines:
// the ranges of selected lights (or of all of them), orbits, and mesh
// bounds. None while the UI is hidden.
editor_debug_lines :: proc(scene: ^Scene) -> []DebugLineVertex {
    lines := make([dynamic]DebugLineVertex, context.temp_allocator)
    camera_index := camera_find_active(scene)
    if !g_debug_ui_visible || camera_index < 0 do return nil
    camera_position := scene.transforms[camera_index].position

    for i in 0..<scene.entity_count {
        if !scene.alive[i] || !scene.has_transform[i] do continue

        if g_editor_viewport.mesh_bounds {
            if bounds, world, ok := editor_entity_bounds(scene, Entity(i)); ok {
                editor_lines_box(&lines, bounds, world, gizmo_color(90, 200, 235, 200))
            }
        }

        selected := editor_is_selected(Entity(i))
        if !selected && !g_editor_viewport.all_light_ranges do continue
        alpha := u8(255 if selected else 120)

        if scene.has_point_light[i] {
            light := scene.point_lights[i]
            color := editor_light_display_color(light.color, alpha)
            editor_lines_point_range(&lines, scene_world_position(scene, i), camera_position, light.range, color)
            if light.orbit_enabled && light.orbit_radius > 0 {
                // The orbit is in the parent's space, like the light's position.
                parent := scene_parent_matrix(scene, i)
                orbit_color := editor_light_display_color(light.color, alpha / 2)
                previous: alg.Vector3f32
                for segment in 0..=LINE_CIRCLE_SEGMENTS {
                    angle := f32(segment) / LINE_CIRCLE_SEGMENTS * 2 * math.PI
                    local := alg.Vector3f32(light.orbit_center) +
                             {math.cos(angle) * light.orbit_radius, 0, math.sin(angle) * light.orbit_radius}
                    current := alg.mul(parent, alg.Vector4f32{local.x, local.y, local.z, 1}).xyz
                    if segment > 0 do editor_line(&lines, previous, current, orbit_color)
                    previous = current
                }
            }
        }
        if scene.has_spot_light[i] {
            light := scene.spot_lights[i]
            editor_lines_spot_cone(
                &lines, scene_world_matrix(scene, i), light,
                editor_light_display_color(light.color, alpha),
                editor_light_display_color(light.color, alpha / 2),
            )
        }
    }
    return lines[:]
}

editor_draw_viewport_controls :: proc() {
    ui_checkbox("Icons for entities without a mesh", &g_editor_viewport.icons)
    ui_checkbox("Ranges of all lights", &g_editor_viewport.all_light_ranges)
    ui_checkbox("Mesh bounds", &g_editor_viewport.mesh_bounds)
}
