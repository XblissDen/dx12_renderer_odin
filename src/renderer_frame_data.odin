package main

import "core:math"
import alg "core:math/linalg"

CullingStats :: struct {
    scene_visible, scene_total: int,
    shadow_visible, shadow_total: int,
}

FrameDraws :: struct {
    draw_meshes: [MAX_ENTITIES]MeshHandle,
    draw_textures: [MAX_ENTITIES]TextureHandle,
    draw_count: int,
    draw_normals: [MAX_ENTITIES]TextureHandle,
    draw_roughness: [MAX_ENTITIES]TextureHandle,
    draw_metallic: [MAX_ENTITIES]TextureHandle,

    scene_indices: [MAX_ENTITIES]u32,
    scene_draw_count: int,

    shadow_indices: [MAX_ENTITIES]u32,
    shadow_draw_count: int,
}

renderer_prepare_frame :: proc(scene: ^Scene) -> (data: FrameDraws) {
    r := &g_renderer
    r.culling_stats = {}

    post := &r.post_cb_mapped_data[r.frame_slot]
    sky := &r.sky_cb_mapped_data[r.frame_slot]
    scene_cb_base := int(r.frame_slot) * MAX_ENTITIES

    post.exposure = r.post_exposure
    post.bloom_threshold = r.post_threshold
    post.bloom_strength = r.post_strength

    camera_index := camera_find_active(scene)
    assert(camera_index >= 0)

    camera := &scene.cameras[camera_index]
    camera_position := scene.transforms[camera_index].position

    forward := camera_forward(camera)
    world_up := alg.Vector3f32{0, 1, 0}
    right := alg.normalize(alg.cross(world_up, forward))
    up := alg.cross(forward, right)

    sky.forward = forward
    sky.right = right
    sky.up = up
    sky.tan_half_fov = math.tan(CAMERA_FOV_Y * 0.5)
    sky.aspect = f32(r.width) / f32(r.height)

    view := camera_view_matrix(camera, camera_position)
    proj := camera_projection(camera, f32(r.width) / f32(r.height))
    camera_frustum := frustum_from_matrix(view * proj)
    
    gpu_lights: [MAX_LIGHTS]GpuPointLight
    light_count := 0

    for i in 0..<scene.entity_count {
        if !scene.alive[i] {
            continue
        }

        if scene.has_transform[i] && scene.has_point_light[i] {
            assert(light_count < MAX_LIGHTS)

            gpu_lights[light_count] = GpuPointLight{
                position = scene.transforms[i].position,
                color = scene.point_lights[i].color,
                intensity = scene.point_lights[i].intensity,
            }
            light_count += 1
        }
    }

    sun: DirectionalLight
    sun_found := false

    for i in 0..<scene.entity_count {
        if !scene.alive[i] {
            continue
        }

        if scene.has_directional_light[i] {
            sun = scene.directional_lights[i]
            sun_found = true
            break
        }
    }

    assert(sun_found)

    sun_eye := -sun.direction * 12.0

    sun_up := alg.Vector3f32{0, 1, 0}
    if math.abs(sun.direction.y) > 0.99{
        sun_up = {0, 0, 1}
    }

    sun_view := look_at_lh(sun_eye, {0,0,0}, sun_up)
    sun_projection := orthographic_lh(-8, 8, -8, 8, 0.1, 30.0)
    sun_view_projection := sun_view * sun_projection
    shadow_frustum := frustum_from_matrix(sun_view_projection)

    for i in 0..<scene.entity_count{
        if !scene.alive[i] {
            continue
        }

        if !scene.has_transform[i] || !scene.has_mesh_renderer[i] || !scene.has_material[i]{
            continue
        }

        transform := scene.transforms[i]
        rotation := alg.matrix4_rotate_f32(transform.rotation, {0, 1, 0})
        scale := alg.matrix4_scale_f32({
            transform.scale,
            transform.scale,
            transform.scale,
        })

        model := alg.matrix4_translate_f32(transform.position) * rotation * scale
        mesh := scene.mesh_renderers[i].mesh
        bounds := bounds_to_world(g_assets.meshes[mesh].bounds, model)
        draw_index := u32(data.draw_count)

        if !r.frustum_culling_enabled ||
           frustum_intersects_bounds(camera_frustum, bounds) {
            data.scene_indices[data.scene_draw_count] = draw_index
            data.scene_draw_count += 1
        }

        // Match the existing policy: unlit marker meshes do not cast shadows.
        if !scene.materials[i].unlit {
            r.culling_stats.shadow_total += 1

            if !r.frustum_culling_enabled ||
               frustum_intersects_bounds(shadow_frustum, bounds) {
                data.shadow_indices[data.shadow_draw_count] = draw_index
                data.shadow_draw_count += 1
            }
        }

        unlit: u32 = 0
        if scene.materials[i].unlit{
            unlit = 1
        }

        use_roughness_map: u32 = 0
        if scene.materials[i].use_roughness_map {
            use_roughness_map = 1
        }

        use_metallic_map: u32 = 0
        if scene.materials[i].use_metallic_map {
            use_metallic_map = 1
        }

        r.cb_mapped_data[scene_cb_base + data.draw_count] = SceneConstants{
            model = alg.transpose(model),
            view = view,
            projection = proj,
            view_position = camera_position,
            material_tint = scene.materials[i].tint,
            light_count = u32(light_count),
            unlit = unlit,
            lights = gpu_lights,
            sun_direction = sun.direction,
            sun_color = sun.color,
            sun_intensity = sun.intensity,
            sun_view_projection = sun_view_projection,
            roughness = scene.materials[i].roughness,
            metallic = scene.materials[i].metallic,
            normal_strength = scene.materials[i].normal_strength,
            uv_scale = scene.materials[i].uv_scale,
            use_roughness_map = use_roughness_map,
            use_metallic_map = use_metallic_map,
        }

        data.draw_textures[data.draw_count] = scene.materials[i].texture
        data.draw_meshes[data.draw_count] = mesh
        data.draw_normals[data.draw_count] = g_assets.flat_normal
        data.draw_roughness[data.draw_count] = g_assets.one
        data.draw_metallic[data.draw_count] = g_assets.one

        if scene.materials[i].normal_strength > 0 {
            data.draw_normals[data.draw_count] = scene.materials[i].normal_texture
        }
        if scene.materials[i].use_roughness_map {
            data.draw_roughness[data.draw_count] =
                scene.materials[i].roughness_texture
        }
        if scene.materials[i].use_metallic_map {
            data.draw_metallic[data.draw_count] =
                scene.materials[i].metallic_texture
        }


        data.draw_count += 1
    }

    r.culling_stats.scene_total = data.draw_count
    r.culling_stats.scene_visible = data.scene_draw_count
    r.culling_stats.shadow_visible = data.shadow_draw_count

    return
}