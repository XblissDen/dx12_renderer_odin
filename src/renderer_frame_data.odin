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

    shadow_indices: [SHADOW_CASCADE_COUNT][MAX_ENTITIES]u32,
    shadow_draw_count: [SHADOW_CASCADE_COUNT]int,
}

renderer_prepare_frame :: proc(scene: ^Scene) -> (data: FrameDraws) {
    r := &g_renderer
    r.culling_stats = {}

    post := &r.post_cb_mapped_data[r.frame_slot]
    sky := &r.sky_cb_mapped_data[r.frame_slot]
    object_cb_base := int(r.frame_slot) * MAX_ENTITIES
    environment_sin := math.sin(math.to_radians(r.environment_settings.rotation_degrees))
    environment_cos := math.cos(math.to_radians(r.environment_settings.rotation_degrees))

    post.exposure = r.post_exposure
    post.bloom_threshold = r.post_threshold
    post.bloom_strength = r.post_strength
    post.tone_mapper = r.post_tone_mapper

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
    sky.background_brightness = r.environment_settings.background_brightness
    sky.environment_sin = environment_sin
    sky.environment_cos = environment_cos
    sky.background_color = r.environment_settings.background_color
    sky.background_mode = r.environment_settings.background_mode

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

    // With HDRI lighting, the panorama's sun (removed from the IBL maps) lights
    // the scene in place of the scene sun's own values.
    if hdri_sun, ok := renderer_hdri_sun(); ok {
        sun = hdri_sun
    }

    // The shadow volume depends on caster bounds, so gather every draw first
    // and cull once the volume is known.
    draw_bounds: [MAX_ENTITIES]WorldBounds
    casts_shadow: [MAX_ENTITIES]bool
    caster_bounds: [MAX_ENTITIES]WorldBounds
    caster_count := 0

    for i in 0..<scene.entity_count{
        if !scene.alive[i] {
            continue
        }

        if !scene.has_transform[i] || !scene.has_mesh_renderer[i] || !scene.has_material[i]{
            continue
        }

        model := transform_matrix(scene.transforms[i])
        mesh := scene.mesh_renderers[i].mesh
        bounds := bounds_to_world(g_assets.meshes[mesh].bounds, model)
        draw_bounds[data.draw_count] = bounds

        // Match the existing policy: unlit marker meshes do not cast shadows.
        if !scene.materials[i].unlit {
            casts_shadow[data.draw_count] = true
            caster_bounds[caster_count] = bounds
            caster_count += 1
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

        r.object_cb_mapped_data[object_cb_base + data.draw_count] = ObjectConstants{
            model = alg.transpose(model),
            // transpose(inverse_transpose(M)) is inverse(M).
            normal_matrix = alg.matrix4_inverse_f32(model),
            material_tint = scene.materials[i].tint,
            uv_scale = scene.materials[i].uv_scale,
            roughness = scene.materials[i].roughness,
            metallic = scene.materials[i].metallic,
            normal_strength = scene.materials[i].normal_strength,
            unlit = unlit,
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

    shadow := renderer_fit_shadow(
        sun.direction,
        camera_position,
        forward,
        f32(r.width) / f32(r.height),
        camera_far_clip(camera),
        r.shadow_distance,
        caster_bounds[:caster_count],
    )
    cascade_frustums: [SHADOW_CASCADE_COUNT]Frustum
    cascade_view_projection: [SHADOW_CASCADE_COUNT]alg.Matrix4f32
    cascade_split_depth, cascade_texel_world, cascade_texel_depth: [SHADOW_CASCADE_COUNT]f32
    for cascade, i in shadow.cascades {
        cascade_frustums[i] = frustum_from_matrix(cascade.view_projection)
        cascade_view_projection[i] = cascade.view_projection
        cascade_split_depth[i] = cascade.split_depth
        cascade_texel_world[i] = cascade.texel_world
        cascade_texel_depth[i] = cascade.texel_depth
    }

    r.frame_cb_mapped_data[r.frame_slot] = FrameConstants{
        view = view,
        projection = proj,
        cascade_view_projection = cascade_view_projection,
        view_position = camera_position,
        light_count = u32(light_count),
        sun_direction = sun.direction,
        sun_intensity = sun.intensity,
        sun_color = sun.color,
        environment_intensity = r.environment_settings.intensity,
        environment_sin = environment_sin,
        environment_cos = environment_cos,
        ambient_intensity = r.environment_settings.ambient_intensity,
        ambient_mode = r.environment_settings.ambient_mode,
        ambient_color = r.environment_settings.ambient_color,
        shadow_bias_constant = r.shadow_bias_constant,
        shadow_bias_slope = r.shadow_bias_slope,
        shadow_fade_start = shadow.fade_start,
        shadow_fade_end = shadow.fade_end,
        shadow_show_cascades = u32(r.shadow_show_cascades),
        cascade_split_depth = cascade_split_depth,
        cascade_texel_world = cascade_texel_world,
        cascade_texel_depth = cascade_texel_depth,
        ao_radius = r.ao_radius,
        ao_intensity = r.ao_intensity,
        ao_enabled = u32(r.ao_enabled),
        ao_show = u32(r.ao_enabled && r.ao_show),
        lights = gpu_lights,
    }

    for draw_index in 0..<data.draw_count {
        bounds := draw_bounds[draw_index]

        if !r.frustum_culling_enabled ||
           frustum_intersects_bounds(camera_frustum, bounds) {
            data.scene_indices[data.scene_draw_count] = u32(draw_index)
            data.scene_draw_count += 1
        }

        if casts_shadow[draw_index] {
            r.culling_stats.shadow_total += 1

            for cascade in 0..<SHADOW_CASCADE_COUNT {
                if !r.frustum_culling_enabled ||
                   frustum_intersects_bounds(cascade_frustums[cascade], bounds) {
                    count := &data.shadow_draw_count[cascade]
                    data.shadow_indices[cascade][count^] = u32(draw_index)
                    count^ += 1
                }
            }
        }
    }

    r.culling_stats.scene_total = data.draw_count
    r.culling_stats.scene_visible = data.scene_draw_count
    for count in data.shadow_draw_count {
        r.culling_stats.shadow_visible += count
    }

    return
}
