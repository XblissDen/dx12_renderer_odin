package main

import "core:math"
import alg "core:math/linalg"

// An entity's local mesh bounds and world matrix, for the selection outline
// and focusing; not ok for entities without a drawable mesh.
editor_entity_bounds :: proc(scene: ^Scene, entity: Entity) -> (
    bounds: MeshBounds,
    world: alg.Matrix4f32,
    ok: bool,
) {
    if !scene_entity_is_alive(scene, entity) {
        return {}, {}, false
    }

    index := int(entity)
    if !scene.has_transform[index] || !scene.has_mesh_renderer[index] ||
       !scene.has_material[index] ||
       !transform_scale_valid(scene.transforms[index].scale) {
        return {}, {}, false
    }

    bounds = g_assets.meshes[scene.mesh_renderers[index].mesh].bounds
    return bounds, scene_world_matrix(scene, index), bounds.valid
}

// A sphere around every selected entity with a mesh, and their descendants
// (a selected group frames what it holds).
editor_selection_sphere :: proc(scene: ^Scene) -> (center: alg.Vector3f32, radius: f32, ok: bool) {
    // A sphere per entity: around its local box, scaled by the largest axis,
    // so it also encloses every rotated and non-uniformly scaled version.
    spheres := make([dynamic][4]f32, context.temp_allocator)
    box_min := alg.Vector3f32(max(f32))
    box_max := alg.Vector3f32(-max(f32))
    for index in editor_selected_subtrees(scene) {
        bounds, world := editor_entity_bounds(scene, Entity(index)) or_continue

        local_center := (bounds.minimum + bounds.maximum) * 0.5
        center4 := alg.mul(world, alg.Vector4f32{
            local_center.x, local_center.y, local_center.z, 1,
        })
        sphere_center := alg.Vector3f32{center4.x, center4.y, center4.z}
        // The longest world axis, including the ancestors' scale.
        largest_scale: f32
        for axis in 0..<3 {
            largest_scale = max(largest_scale, alg.length(alg.Vector3f32{world[0, axis], world[1, axis], world[2, axis]}))
        }
        sphere_radius := alg.length(bounds.maximum - bounds.minimum) * largest_scale * 0.5

        append(&spheres, [4]f32{sphere_center.x, sphere_center.y, sphere_center.z, sphere_radius})
        box_min = alg.min(box_min, sphere_center - sphere_radius)
        box_max = alg.max(box_max, sphere_center + sphere_radius)
    }
    if len(spheres) == 0 {
        return {}, 0, false
    }

    // Centered on the box around all of them; not the smallest such sphere,
    // but close for a few objects.
    center = (box_min + box_max) * 0.5
    for sphere in spheres {
        radius = max(radius, alg.length(sphere.xyz - center) + sphere.w)
    }
    return center, max(radius, 0.05), true
}

// The box, in the space of `box`'s parent, around every mesh of the other
// selected entities and their descendants: each mesh's local bounds through
// its world matrix and back into that space. Not ok when none has a mesh.
editor_fit_box_bounds :: proc(scene: ^Scene, box: int) -> (minimum, maximum: alg.Vector3f32, ok: bool) {
    to_space := alg.matrix4_inverse_f32(scene_parent_matrix(scene, box))
    minimum = alg.Vector3f32(max(f32))
    maximum = alg.Vector3f32(-max(f32))
    for index in editor_selected_subtrees(scene) {
        if index == box do continue
        bounds, world := editor_entity_bounds(scene, Entity(index)) or_continue
        for corner in 0..<8 {
            local := alg.Vector3f32{
                bounds.maximum.x if corner & 1 != 0 else bounds.minimum.x,
                bounds.maximum.y if corner & 2 != 0 else bounds.minimum.y,
                bounds.maximum.z if corner & 4 != 0 else bounds.minimum.z,
            }
            point := alg.mul(to_space * world, alg.Vector4f32{local.x, local.y, local.z, 1}).xyz
            minimum = alg.min(minimum, point)
            maximum = alg.max(maximum, point)
        }
        ok = true
    }
    return
}

// Fits a reflection probe's or irradiance volume's box around the other
// selected models, unrotated and a little larger than them, as one undo step.
// Returns whether there was anything to fit to.
editor_fit_box_to_selection :: proc(scene: ^Scene, box: int) -> bool {
    editor_finish_edit()
    minimum, maximum := editor_fit_box_bounds(scene, box) or_return
    margin :: f32(0.1)
    fields := [3]EditorField{.Position, .Rotation, .Scale}
    before: [3][3]f32
    for field, i in fields do before[i] = editor_value(scene, box, field)
    editor_apply_value(scene, Entity(box), .Position, (minimum + maximum) * 0.5)
    editor_apply_value(scene, Entity(box), .Rotation, {0, 0, 0})
    editor_apply_value(scene, Entity(box), .Scale, maximum - minimum + 2 * margin)
    edits: [3]EditorFieldEdit
    for field, i in fields do edits[i] = {Entity(box), field, before[i], editor_value(scene, box, field)}
    editor_push_field_edits(edits[:], Entity(box))
    return true
}

// The Inspector's fit button for a probe or volume `index` (the primary
// selection), disabled until other models are selected too.
editor_draw_fit_box_button :: proc(scene: ^Scene, index: int) {
    _, _, can_fit := editor_fit_box_bounds(scene, index)
    ui_begin_disabled(!can_fit)
    if ui_button("Fit box to selected models") do editor_fit_box_to_selection(scene, index)
    ui_end_disabled()
    if !can_fit {
        debug_ui_text("To fit it, select the models, then")
        debug_ui_text("Ctrl+click this entity last.")
    }
}

editor_focus_selected :: proc(scene: ^Scene) {
    center, radius, ok := editor_selection_sphere(scene)
    camera_index := camera_find_active(scene)
    r := &g_renderer

    if !ok || camera_index < 0 || r.width == 0 || r.height == 0 {
        return
    }

    editor_finish_edit()

    aspect := f32(r.width) / f32(r.height)
    vertical_half_fov := CAMERA_FOV_Y * 0.5
    horizontal_half_fov := math.atan(math.tan(vertical_half_fov) * aspect)
    limiting_half_fov := min(vertical_half_fov, horizontal_half_fov)

    // Tangent from the eye to a sphere:
    // sin(half_fov) = radius / distance.
    distance := max(
        radius / math.sin(limiting_half_fov) * 1.15,
        radius + CAMERA_NEAR_CLIP * 2,
    )

    camera := &scene.cameras[camera_index]
    scene.transforms[camera_index].position =
        center - camera_forward(camera) * distance

    camera.far_clip = max(camera_far_clip(camera), distance + radius * 2)
}
