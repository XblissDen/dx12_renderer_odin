package main

import "core:math"
import alg "core:math/linalg"

editor_selection_bounds :: proc(scene: ^Scene) -> (
    bounds: MeshBounds,
    transform: Transform,
    ok: bool,
) {
    if !scene_entity_is_alive(scene, g_editor_selected) {
        return {}, {}, false
    }

    index := int(g_editor_selected)
    if !scene.has_transform[index] || !scene.has_mesh_renderer[index] ||
       !scene.has_material[index] || scene.transforms[index].scale <= 0 {
        return {}, {}, false
    }

    bounds = g_assets.meshes[scene.mesh_renderers[index].mesh].bounds
    return bounds, scene.transforms[index], bounds.valid
}

editor_focus_selected :: proc(scene: ^Scene) {
    bounds, transform, ok := editor_selection_bounds(scene)
    camera_index := camera_find_active(scene)
    r := &g_renderer

    if !ok || camera_index < 0 || r.width == 0 || r.height == 0 {
        return
    }

    editor_finish_edit()

    local_center := (bounds.minimum + bounds.maximum) * 0.5
    model := alg.matrix4_translate_f32(transform.position) *
             alg.matrix4_rotate_f32(transform.rotation, {0, 1, 0}) *
             alg.matrix4_scale_f32({transform.scale, transform.scale, transform.scale})

    center4 := alg.mul(model, alg.Vector4f32{
        local_center.x, local_center.y, local_center.z, 1,
    })
    center := alg.Vector3f32{center4.x, center4.y, center4.z}

    // A sphere enclosing the local box also encloses every rotated version.
    radius := max(
        alg.length(bounds.maximum - bounds.minimum) * transform.scale * 0.5,
        f32(0.05),
    )

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