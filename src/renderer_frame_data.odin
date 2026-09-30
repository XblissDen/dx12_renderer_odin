package main

import "core:math"
import alg "core:math/linalg"

FrameDraws :: struct {
    draw_meshes: [MAX_ENTITIES]Mesh_Asset,
    draw_textures: [MAX_ENTITIES]Texture_Asset,
    draw_count: int,
    draw_normals: [MAX_ENTITIES]Texture_Asset,
}

renderer_prepare_frame :: proc(scene: ^Scene) -> (data: FrameDraws) {
    r := &g_renderer

    r.post_cb_mapped_data.exposure = r.post_exposure
    r.post_cb_mapped_data.bloom_threshold = r.post_threshold
    r.post_cb_mapped_data.bloom_strength = r.post_strength

    camera_index := -1

    for i in 0..<scene.entity_count{
        if scene.has_transform[i] && scene.has_camera[i]{
            camera_index = i
            break
        }
    }

    assert(camera_index >= 0)

    camera := &scene.cameras[camera_index]
    camera_position := scene.transforms[camera_index].position

    forward := camera_forward(camera)
    world_up := alg.Vector3f32{0, 1, 0}
    right := alg.normalize(alg.cross(world_up, forward))
    up := alg.cross(forward, right)

    r.sky_cb_mapped_data.forward = forward
    r.sky_cb_mapped_data.right = right
    r.sky_cb_mapped_data.up = up
    r.sky_cb_mapped_data.tan_half_fov = math.tan(
        alg.to_radians(f32(45)) * 0.5,
    )
    r.sky_cb_mapped_data.aspect = f32(r.width) / f32(r.height)

    view := camera_view_matrix(camera, camera_position)

    proj := perspective_lh(
        alg.to_radians(f32(45)),
        f32(r.width) / f32(r.height),
        0.1,
        100.0,
    )

    gpu_lights: [MAX_LIGHTS]GpuPointLight
    light_count := 0

    for i in 0..<scene.entity_count {
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
        if scene.has_directional_light[i] {
            sun = scene.directional_lights[i]
            sun_found = true
            break
        }
    }

    assert(sun_found)

    sun_eye := -sun.direction * 12.0
    sun_view := look_at_lh(sun_eye, {0,0,0}, {0, 1, 0})
    sun_projection := orthographic_lh(-8, 8, -8, 8, 0.1, 30.0)
    sun_view_projection := sun_view * sun_projection

    for i in 0..<scene.entity_count{
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
        unlit: u32 = 0
        if scene.materials[i].unlit{
            unlit = 1
        }

        r.cb_mapped_data[data.draw_count] = SceneConstants{
            model = alg.transpose(alg.matrix4_translate_f32(transform.position) * rotation * scale),
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
        }

        data.draw_textures[data.draw_count] = scene.materials[i].texture
        data.draw_meshes[data.draw_count] = scene.mesh_renderers[i].mesh
        data.draw_normals[data.draw_count] = .Stone_Normal

        if scene.materials[i].normal_strength > 0 {
            data.draw_normals[data.draw_count] = scene.materials[i].normal_texture
        }


        data.draw_count += 1
    }

    return
}