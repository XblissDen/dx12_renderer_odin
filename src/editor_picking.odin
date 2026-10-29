package main

import "core:math"
import alg "core:math/linalg"
import win32 "core:sys/windows"

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
    inverse := alg.matrix4_inverse_f32(transform_matrix(transform))

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

// Moller-Trumbore: find t and the triangle's barycentric coordinates (the
// hit is a + u (b - a) + v (c - a)).
editor_ray_triangle :: proc(
    ray: EditorRay,
    a, b, c: alg.Vector3f32,
    two_sided: bool,
) -> (distance, u, v: f32, hit: bool) {
    edge1 := b - a
    edge2 := c - a
    p := alg.cross(ray.direction, edge2)
    determinant := alg.dot(edge1, p)

    // Reject nearly parallel/degenerate triangles, and back faces unless the
    // material is double-sided, as the renderer culls them.
    if (two_sided ? math.abs(determinant) : determinant) <= 0.0000001 {
        return 0, 0, 0, false
    }

    inverse_determinant := 1 / determinant
    offset := ray.origin - a

    u = alg.dot(offset, p) * inverse_determinant
    if u < 0 || u > 1 {
        return 0, 0, 0, false
    }

    q := alg.cross(offset, edge1)
    v = alg.dot(ray.direction, q) * inverse_determinant
    if v < 0 || u + v > 1 {
        return 0, 0, 0, false
    }

    distance = alg.dot(edge2, q) * inverse_determinant
    return distance, u, v, distance >= ray.near_t && distance <= ray.far_t
}

// Whether a cutout material is solid at a texture coordinate: the nearest
// full-size albedo texel's alpha against the cutoff, wrapping like the
// material sampler. The shader's test is filtered and mip-adjusted, so edges
// can differ by a texel. Blended surfaces (glass) stay pickable everywhere.
editor_cutout_solid :: proc(material: ^Material, texcoord: [2]f32) -> bool {
    if !material.alpha_mask || material.alpha_blend || !assets_texture_valid(material.texture) {
        return true
    }
    alpha := g_assets.textures[material.texture].alpha
    if alpha.values == nil do return true // Fully opaque image.
    uv := texcoord * material.uv_scale
    uv -= {math.floor(uv.x), math.floor(uv.y)}
    x := min(int(uv.x * f32(alpha.width)), int(alpha.width) - 1)
    y := min(int(uv.y * f32(alpha.height)), int(alpha.height) - 1)
    return f32(alpha.values[y * int(alpha.width) + x]) / 255 >= material.alpha_cutoff
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
        if !transform_scale_valid(transform.scale) {
            continue
        }

        local_ray := editor_ray_to_local(ray, transform)
        asset := scene.mesh_renderers[i].mesh
        mesh := g_assets.meshes[asset].data

        // Per submesh: each has its own material's sidedness and cutout.
        for submesh in mesh.submeshes {
            material := scene_material(scene, i, int(submesh.material_slot))
            first := int(submesh.first_index)
            for offset := first; offset < first + int(submesh.index_count); offset += 3 {
                va := mesh.vertices[mesh.indices[offset + 0]]
                vb := mesh.vertices[mesh.indices[offset + 1]]
                vc := mesh.vertices[mesh.indices[offset + 2]]

                distance, u, v, hit := editor_ray_triangle(
                    local_ray, va.position, vb.position, vc.position, material.double_sided,
                )
                if !hit || (selected != Entity(-1) && distance >= nearest_distance) {
                    continue
                }
                texcoord := va.texcoord * (1 - u - v) + vb.texcoord * u + vc.texcoord * v
                if !editor_cutout_solid(material, texcoord) do continue

                nearest_distance = distance
                selected = Entity(i)
            }
        }
    }

    return selected
}

editor_update_picking :: proc(scene: ^Scene) {
    if g_cursor_locked || !g_debug_ui_ready || editor_gizmo_has_mouse() {
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

    // Ctrl+click adds or removes, Shift+click adds; a plain click selects
    // only what was hit, and on empty background clears the selection.
    picked := editor_pick_mesh(scene, ray)
    if key_down(win32.VK_CONTROL) {
        if picked >= 0 do editor_toggle_selection(picked)
    } else if key_down(win32.VK_SHIFT) {
        if picked >= 0 do editor_add_to_selection(picked)
    } else {
        editor_select(picked)
    }
}