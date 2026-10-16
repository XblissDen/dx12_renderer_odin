package main

import "core:math"
import alg "core:math/linalg"

EditorRay :: struct {
    origin, direction: alg.Vector3f32,
    near_t, far_t: f32,
}

editor_mouse_ray :: proc(
    scene: ^Scene,
    mouse_x, mouse_y: f32,
) -> (ray: EditorRay, ok: bool){
    r := &g_renderer
    width, height := f32(r.width), f32(r.height)

    if width <= 0 || height <= 0 ||
    mouse_x < 0 || mouse_x >= width ||
    mouse_y < 0 || mouse_y >= height{
        return {}, false
    }

    // Choose the same first live camera as renderer_prepare_frame.
    camera_index := camera_find_active(scene)
    if camera_index < 0 {
        return {}, false
    }

    camera := &scene.cameras[camera_index]
    forward := camera_forward(camera)

    // Match tge renderer's screen-right basis
    right := alg.normalize(alg.cross(alg.Vector3f32{0, 1, 0}, forward))
    up := alg.cross(forward, right)

    // Client coordinates have Y pointing down; camera space has Y up.
    ndc_x := 2 * mouse_x / width - 1
    ndc_y := 1 - 2 * mouse_y / height

    tan_half_fov := math.tan(CAMERA_FOV_Y * 0.5)
    aspect := width / height

    direction := alg.normalize(
        forward + right * (ndc_x * aspect * tan_half_fov) +
        up * (ndc_y * tan_half_fov),
    )

    // Clip planes measure camera-forward depth, not radial distance.
    forward_depth := alg.dot(direction, forward)

    return EditorRay{
        origin = scene.transforms[camera_index].position,
        direction = direction,
        near_t = CAMERA_NEAR_CLIP / forward_depth,
        far_t = camera_far_clip(camera) / forward_depth,
    }, true
}

editor_ray_to_local :: proc(ray: EditorRay, transform: Transform) -> EditorRay {
    model := alg.matrix4_translate_f32(transform.position) *
             alg.matrix4_rotate_f32(transform.rotation, {0, 1, 0}) *
             alg.matrix4_scale_f32({transform.scale, transform.scale, transform.scale})
    inverse := alg.matrix4_inverse_f32(model)

    origin := alg.mul(inverse, alg.Vector4f32{
        ray.origin.x, ray.origin.y, ray.origin.z, 1,
    })
    direction := alg.mul(inverse, alg.Vector4f32{
        ray.direction.x, ray.direction.y, ray.direction.z, 0,
    })

    result := ray
    result.origin = {origin.x, origin.y, origin.z}

    // Do not normalize: t must remain the distance along the world ray.
    result.direction = {direction.x, direction.y, direction.z}
    return result
}

// Moller-Trumbore: find t and the triangle's barycentric coordinates.
editor_ray_triangle :: proc(
    ray: EditorRay,
    a, b, c: alg.Vector3f32,
) -> (distance: f32, hit: bool) {
    edge1 := b - a
    edge2 := c - a
    p := alg.cross(ray.direction, edge2)
    determinant := alg.dot(edge1, p)

    // Reject backfaces and nearly parallel/degenerate triangles.
    // This matches the current backface-culled mesh pipeline.
    if determinant <= 0.0000001 {
        return 0, false
    }

    inverse_determinant := 1 / determinant
    offset := ray.origin - a

    u := alg.dot(offset, p) * inverse_determinant
    if u < 0 || u > 1 {
        return 0, false
    }

    q := alg.cross(offset, edge1)
    v := alg.dot(ray.direction, q) * inverse_determinant
    if v < 0 || u + v > 1 {
        return 0, false
    }

    distance = alg.dot(edge2, q) * inverse_determinant
    return distance, distance >= ray.near_t && distance <= ray.far_t
}

editor_pick_mesh :: proc(scene: ^Scene, ray: EditorRay) -> Entity{
    selected := Entity(-1)
    nearest_distance := ray.far_t

    for i in 0..<scene.entity_count{
        // Match the renderer's drawable-entity requirements.
        if !scene.alive[i] || !scene.has_transform[i] ||
           !scene.has_mesh_renderer[i] || !scene.has_material[i] {
            continue
        }

        transform := scene.transforms[i]
        if transform.scale <= 0 {
            continue
        }

        local_ray := editor_ray_to_local(ray, transform)
        asset := scene.mesh_renderers[i].mesh
        mesh := g_assets.meshes[asset].data

        for triangle in 0..<len(mesh.indices) / 3 {
            offset := triangle * 3

            a := alg.Vector3f32(mesh.vertices[mesh.indices[offset + 0]].position)
            b := alg.Vector3f32(mesh.vertices[mesh.indices[offset + 1]].position)
            c := alg.Vector3f32(mesh.vertices[mesh.indices[offset + 2]].position)

            distance, hit := editor_ray_triangle(local_ray, a, b, c)
            if hit && (selected == Entity(-1) || distance < nearest_distance) {
                nearest_distance = distance
                selected = Entity(i)
            }
        }
    }

    return selected
}

editor_update_picking :: proc(scene: ^Scene) {
    if g_cursor_locked || !g_debug_ui_ready {
        return
    }

    mouse_x, mouse_y: f32
    if !ui_scene_left_click(&mouse_x, &mouse_y) {
        return
    }

    ray, ok := editor_mouse_ray(scene, mouse_x, mouse_y)
    if !ok {
        return
    }

    editor_finish_edit()

    // A click on empty background clears selection.
    g_editor_selected = editor_pick_mesh(scene, ray)
}