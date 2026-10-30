package main

import "core:math"
import "core:slice"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"

CullingStats :: struct {
    scene_visible, scene_total: int,
    shadow_visible, shadow_total: int,
    // Draw calls after batching: the camera's (prepass and lit pass each
    // make these) and all shadow views' together.
    scene_calls, shadow_calls: int,
    // More submesh draws than MAX_DRAWS this frame; the rest were skipped.
    draws_dropped: bool,
}

// Draws per frame: one per (entity, submesh). Sizes the object buffer and
// the material-table rings.
MAX_DRAWS :: 4096
// Instance-list entries per frame: each view lists each draw at most once,
// and the views are the camera's opaque and blended lists plus every shadow
// view.
MAX_INSTANCES :: (SHADOW_VIEW_COUNT + 2) * MAX_DRAWS

// How a draw's material changes its pipelines (one per variant in each mesh
// pass): cutouts discard pixels in the depth-only passes, and double-sided
// materials draw without back-face culling. Blended draws use the cutout
// variants in the shadow pass.
Draw_Variant :: enum u8 {Opaque, Masked, Double_Sided, Masked_Double_Sided}

// One submesh of one entity, with the material of its slot.
Draw :: struct {
    mesh: MeshHandle,
    first_index, index_count: u32,
    // Albedo, normal, roughness, metallic, emissive and occlusion textures.
    material_table: d3d12.GPU_DESCRIPTOR_HANDLE,
    variant: Draw_Variant,
    // Alpha-blended: drawn in the transparent pass instead of the prepass and
    // lit pass.
    blended: bool,
    bounds: WorldBounds,
    casts_shadow: bool,
}

// One draw call: `instance_count` instances of `draw`'s submesh, with its
// material table and pipeline variant. Instance i draws the object at entry
// first_instance + i of this frame's instance list.
DrawBatch :: struct {
    draw: u32,
    first_instance, instance_count: u32,
}

// Rebuilt every frame; lives in the renderer (too large for the stack).
FrameDraws :: struct {
    draws: [MAX_DRAWS]Draw,
    draw_count: int,

    // Visible opaque and cutout draws.
    scene_indices: [MAX_DRAWS]u32,
    scene_draw_count: int,

    // Visible blended draws, farthest first.
    transparent_indices: [MAX_DRAWS]u32,
    transparent_draw_count: int,

    // Casters per shadow view: the sun's cascades, then the spot shadow slots.
    shadow_indices: [SHADOW_VIEW_COUNT][MAX_DRAWS]u32,
    shadow_draw_count: [SHADOW_VIEW_COUNT]int,

    caster_bounds: [MAX_DRAWS]WorldBounds,
    caster_count: int,

    // The draw calls for those lists (in the frame's temp allocator), and
    // how much of this frame's instance list they use.
    scene_batches, transparent_batches: []DrawBatch,
    shadow_batches: [SHADOW_VIEW_COUNT][]DrawBatch,
    instance_count: int,
}

// Turns a view's visible draws into draw calls, appending their instance
// lists to this frame's. With `merge`, draws of the same submesh range,
// material table and variant become one call; the calls are sorted by
// variant, then material, so pipelines and tables change rarely. Without
// it, every draw is its own call in the given order (blended draws, sorted
// back to front).
renderer_batch_draws :: proc(data: ^FrameDraws, indices: []u32, merge: bool) -> []DrawBatch {
    Batch_Key :: struct {
        variant: Draw_Variant,
        table: u64,
        mesh: MeshHandle,
        first_index, index_count: u32,
        draw: u32,
    }
    same_batch :: proc(a, b: Batch_Key) -> bool {
        return a.variant == b.variant && a.table == b.table && a.mesh == b.mesh &&
               a.first_index == b.first_index && a.index_count == b.index_count
    }

    keys := make([]Batch_Key, len(indices), context.temp_allocator)
    for draw_index, i in indices {
        draw := &data.draws[draw_index]
        keys[i] = {draw.variant, draw.material_table.ptr, draw.mesh, draw.first_index, draw.index_count, draw_index}
    }
    if merge {
        slice.sort_by(keys, proc(a, b: Batch_Key) -> bool {
            if a.variant != b.variant do return a.variant < b.variant
            if a.table != b.table do return a.table < b.table
            if a.mesh != b.mesh do return a.mesh < b.mesh
            if a.first_index != b.first_index do return a.first_index < b.first_index
            if a.index_count != b.index_count do return a.index_count < b.index_count
            return a.draw < b.draw
        })
    }

    r := &g_renderer
    instances := r.instance_mapped[int(r.frame_slot) * MAX_INSTANCES:]
    batches := make([dynamic]DrawBatch, 0, len(keys), context.temp_allocator)
    for key, i in keys {
        if !merge || i == 0 || !same_batch(key, keys[i - 1]) {
            append(&batches, DrawBatch{draw = key.draw, first_instance = u32(data.instance_count)})
        }
        assert(data.instance_count < MAX_INSTANCES)
        instances[data.instance_count] = key.draw
        data.instance_count += 1
        batches[len(batches) - 1].instance_count += 1
    }
    return batches[:]
}

renderer_prepare_frame :: proc(scene: ^Scene) -> ^FrameDraws {
    r := &g_renderer
    r.culling_stats = {}
    data := &r.frame_draws
    data.draw_count = 0
    data.scene_draw_count = 0
    data.transparent_draw_count = 0
    data.shadow_draw_count = {}
    data.caster_count = 0
    data.instance_count = 0

    post := &r.post_cb_mapped_data[r.frame_slot]
    sky := &r.sky_cb_mapped_data[r.frame_slot]
    objects := r.object_mapped[int(r.frame_slot) * MAX_DRAWS:]
    // One material table per distinct set of textures: draws can share a
    // batch only if they share a table.
    material_tables := make(map[[MATERIAL_TEXTURE_COUNT]TextureHandle]d3d12.GPU_DESCRIPTOR_HANDLE, context.temp_allocator)
    environment_sin := math.sin(math.to_radians(r.environment_settings.rotation_degrees))
    environment_cos := math.cos(math.to_radians(r.environment_settings.rotation_degrees))

    // With auto-exposure, the compensation multiplies the GPU-side exposure.
    post.auto_exposure = u32(r.auto_exposure.enabled)
    post.exposure = math.pow(f32(2), r.auto_exposure.compensation) if r.auto_exposure.enabled else r.post_exposure
    post.bloom_threshold = r.post_threshold
    // Bloom mip 0 holds the sum of every level; average them so the strength
    // does not depend on how many levels the window allows.
    post.bloom_strength = r.post_strength / f32(max(r.bloom_mip_count, 1))
    post.tone_mapper = r.post_tone_mapper
    post.texel_size = {1 / f32(r.width), 1 / f32(r.height)}
    // History from a frame without TAA (or before a resize) is stale.
    if r.post_anti_aliasing != .TAA do r.taa_history_valid = false
    post.taa_history_valid = u32(r.taa_history_valid)
    post.taa_blend = TAA_BLEND

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
    view_projection := view * proj
    camera_frustum := frustum_from_matrix(view_projection)

    // TAA renders each frame from a slightly different sub-pixel position, so
    // the history accumulates several samples per pixel. Culling and motion
    // vectors use the unjittered matrices.
    r.frame_counter += 1
    rendered_proj := proj
    if r.post_anti_aliasing == .TAA {
        jitter := taa_jitter(r.frame_counter)
        // Row-vector projection: clip.w = view z, so row 2 offsets NDC directly.
        rendered_proj[2, 0] += jitter.x * 2 / f32(r.width)
        rendered_proj[2, 1] -= jitter.y * 2 / f32(r.height)
    }
    previous_view_projection := r.previous_view_projection
    if r.frame_counter == 1 do previous_view_projection = view_projection

    // The sky is infinitely far away, so only camera rotation moves it on
    // screen. With the translation removed from both frames' cameras, a sky
    // pixel's far-plane position maps to where that direction was last frame.
    sky_view := view
    sky_view[3, 0], sky_view[3, 1], sky_view[3, 2] = 0, 0, 0
    sky_view_projection := sky_view * proj
    previous_sky_view_projection := r.previous_sky_view_projection
    if r.frame_counter == 1 do previous_sky_view_projection = sky_view_projection
    post.sky_reprojection = alg.matrix4_inverse_f32(sky_view_projection) * previous_sky_view_projection
    r.previous_sky_view_projection = sky_view_projection
    post.sharpness = r.post_sharpness

    // Spot shadow slots first: the lights below say which slot they use.
    spot_shadows := renderer_select_spot_shadows(scene, camera_position)
    spot_shadow_view_projection: [SPOT_SHADOW_COUNT]alg.Matrix4f32
    spot_shadow_frustums: [SPOT_SHADOW_COUNT]Frustum
    point_shadows := renderer_select_point_shadows(scene, camera_position)
    point_shadow_face_view_projection: [POINT_SHADOW_COUNT * POINT_SHADOW_FACES]alg.Matrix4f32
    point_shadow_frustums: [POINT_SHADOW_COUNT * POINT_SHADOW_FACES]Frustum
    for shadow, slot in point_shadows {
        if shadow.entity < 0 do continue
        for face in 0..<POINT_SHADOW_FACES {
            index := slot * POINT_SHADOW_FACES + face
            point_shadow_face_view_projection[index] = shadow.face_view_projection[face]
            point_shadow_frustums[index] = frustum_from_matrix(shadow.face_view_projection[face])
        }
    }
    for shadow, slot in spot_shadows {
        if shadow.entity < 0 do continue
        spot_shadow_view_projection[slot] = shadow.view_projection
        spot_shadow_frustums[slot] = frustum_from_matrix(shadow.view_projection)
    }

    // Point and spot lights whose range reaches the view, straight into this
    // frame's light buffer (write-combined memory: each written once, whole).
    frame_lights := renderer_frame_lights()
    light_count := 0
    r.scene_light_count = 0

    for i in 0..<scene.entity_count {
        if !scene.alive[i] || !scene.has_transform[i] {
            continue
        }
        if !scene.has_point_light[i] && !scene.has_spot_light[i] {
            continue
        }
        r.scene_light_count += 1

        light: GpuLight
        world := scene_world_matrix(scene, i)
        world_position := alg.Vector3f32{world[0, 3], world[1, 3], world[2, 3]}
        if scene.has_point_light[i] {
            point := scene.point_lights[i]
            light = GpuLight{
                position = world_position,
                range = point.range,
                radiance = point.color * point.intensity,
                spot_offset = 1,
                shadow_index = -1,
            }
            for shadow, slot in point_shadows {
                if shadow.entity != i do continue
                light.shadow_index = i32(slot)
                light.shadow_texel_scale = POINT_SHADOW_TEXEL_SCALE
                light.shadow_near = shadow.near
            }
        } else {
            spot := scene.spot_lights[i]
            // Full brightness inside the inner cone, none outside the outer.
            cos_inner := math.cos(spot.inner_angle)
            cos_outer := math.cos(spot.outer_angle)
            scale := 1 / max(cos_inner - cos_outer, 0.0001)
            light = GpuLight{
                position = world_position,
                range = spot.range,
                radiance = spot.color * spot.intensity,
                direction = spot_light_direction(world),
                spot_scale = scale,
                spot_offset = -cos_outer * scale,
                shadow_index = -1,
            }
            for shadow, slot in spot_shadows {
                if shadow.entity != i do continue
                light.shadow_index = i32(slot)
                light.shadow_texel_scale = shadow.texel_scale
            }
        }

        // The range sphere's box against the camera frustum.
        range_bounds := WorldBounds{
            center = light.position,
            half_axes = {{light.range, 0, 0}, {0, light.range, 0}, {0, 0, light.range}},
            valid = true,
        }
        if r.frustum_culling_enabled && !frustum_intersects_bounds(camera_frustum, range_bounds) {
            continue
        }
        assert(light_count < MAX_LIGHTS)
        frame_lights[light_count] = light
        light_count += 1
    }
    r.visible_light_count = light_count

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
    entities: for i in 0..<scene.entity_count{
        if !scene.alive[i] {
            continue
        }

        if !scene.has_transform[i] || !scene.has_mesh_renderer[i] || !scene.has_material[i]{
            continue
        }

        model := scene_world_matrix(scene, i)
        // A slot not recorded last frame (new, reused, or just shown) has no motion.
        previous_model := model
        // Frames count from 1, so 0 means never recorded.
        if r.previous_model_frame[i] != 0 && r.previous_model_frame[i] == r.frame_counter - 1 {
            previous_model = r.previous_models[i]
        }
        r.previous_models[i] = model
        r.previous_model_frame[i] = r.frame_counter
        normal_matrix := alg.matrix4_inverse_f32(model)

        mesh := scene.mesh_renderers[i].mesh
        for submesh in g_assets.meshes[mesh].data.submeshes {
            if data.draw_count == MAX_DRAWS {
                r.culling_stats.draws_dropped = true
                break entities
            }
            material := scene_material(scene, i, int(submesh.material_slot))
            draw := &data.draws[data.draw_count]
            // Unused maps get neutral textures: flat normal, white elsewhere.
            textures := [MATERIAL_TEXTURE_COUNT]TextureHandle{
                material.texture, g_assets.flat_normal, g_assets.one, g_assets.one, g_assets.white, g_assets.one,
            }
            if material.normal_strength > 0 do textures[1] = material.normal_texture
            if material.use_roughness_map do textures[2] = material.roughness_texture
            if material.use_metallic_map do textures[3] = material.metallic_texture
            if material.use_emissive_map do textures[4] = material.emissive_texture
            if material.use_occlusion_map do textures[5] = material.occlusion_texture

            // Blended surfaces cast shadows where they are mostly opaque.
            cutout := material.alpha_mask || material.alpha_blend
            opacity := 1 - material.transparency
            alpha_cutoff := material.alpha_cutoff
            if material.alpha_blend {
                // Coverage is texture alpha times opacity; test texture alpha
                // against 0.5 / opacity for coverage 0.5.
                alpha_cutoff = clamp(0.5 / opacity, 0, 1) if opacity > 0 else 1
            }

            material_table, table_found := material_tables[textures]
            if !table_found {
                material_table = renderer_material_table(len(material_tables), textures)
                material_tables[textures] = material_table
            }

            draw^ = Draw{
                mesh = mesh,
                first_index = submesh.first_index,
                index_count = submesh.index_count,
                // The depth-only passes bind it too, for cutouts.
                material_table = material_table,
                variant = Draw_Variant(int(cutout) + 2 * int(material.double_sided)),
                blended = material.alpha_blend,
                bounds = bounds_to_world(submesh.bounds, model),
                // Unlit marker meshes do not cast shadows.
                casts_shadow = !material.unlit,
            }

            if draw.casts_shadow {
                data.caster_bounds[data.caster_count] = draw.bounds
                data.caster_count += 1
            }

            objects[data.draw_count] = ObjectData{
                model = alg.transpose(model),
                previous_model = alg.transpose(previous_model),
                // transpose(inverse_transpose(M)) is inverse(M).
                normal_matrix = normal_matrix,
                material_tint = material.tint,
                uv_scale = material.uv_scale,
                roughness = material.roughness,
                metallic = material.metallic,
                normal_strength = material.normal_strength,
                unlit = u32(material.unlit),
                use_roughness_map = u32(material.use_roughness_map),
                use_metallic_map = u32(material.use_metallic_map),
                use_occlusion_map = u32(material.use_occlusion_map),
                occlusion_strength = material.occlusion_strength,
                emissive = material.emissive * material.emissive_strength,
                alpha_cutoff = alpha_cutoff,
                opacity = opacity,
            }
            data.draw_count += 1
        }
    }

    shadow := renderer_fit_shadow(
        sun.direction,
        camera_position,
        forward,
        f32(r.width) / f32(r.height),
        camera_far_clip(camera),
        r.shadow_distance,
        data.caster_bounds[:data.caster_count],
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

    // Sky light reaching the fog: the panorama's average radiance, or the
    // ambient color, the same light the IBL gives surfaces.
    fog_ambient := r.environment_settings.ambient_color * r.environment_settings.ambient_intensity
    if r.environment_settings.ambient_mode == .HDRI {
        fog_ambient = r.environment_average_radiance * r.environment_settings.intensity
    }
    fog_ambient *= r.fog.ambient
    cluster_depth_scale, cluster_depth_bias := light_cluster_depth_params(CAMERA_NEAR_CLIP, camera_far_clip(camera))
    r.frame_cb_mapped_data[r.frame_slot] = FrameConstants{
        view = view,
        projection = rendered_proj,
        view_projection = view_projection,
        previous_view_projection = previous_view_projection,
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
        ssr_max_distance = r.ssr_max_distance,
        ssr_thickness = r.ssr_thickness,
        ssr_max_roughness = r.ssr_max_roughness,
        ssr_enabled = u32(renderer_ssr_active()),
        ssr_stochastic = u32(r.post_anti_aliasing == .TAA),
        ssr_frame = u32(r.frame_counter),
        cluster_screen_size = {f32(r.width), f32(r.height)},
        cluster_depth_scale = cluster_depth_scale,
        cluster_depth_bias = cluster_depth_bias,
        light_show_clusters = u32(r.light_show_clusters),
        fog_albedo = r.fog.color,
        fog_density = r.fog.density,
        fog_ambient = fog_ambient,
        fog_height = r.fog.height,
        fog_height_falloff = r.fog.height_falloff,
        fog_anisotropy = r.fog.anisotropy,
        fog_max_distance = r.fog.distance,
        // Last frame's volume maps onto this one only at the same distance.
        fog_history_valid = u32(r.fog_history_ready && r.fog_history_distance == r.fog.distance),
        fog_frame = u32(r.frame_counter),
        spot_shadow_view_projection = spot_shadow_view_projection,
        point_shadow_face_view_projection = point_shadow_face_view_projection,
    }

    // Blended draws with their distance from the camera, for sorting.
    Transparent_Draw :: struct {index: u32, distance: f32}
    transparent := make([dynamic]Transparent_Draw, context.temp_allocator)

    for draw_index in 0..<data.draw_count {
        bounds := data.draws[draw_index].bounds

        if !r.frustum_culling_enabled ||
           frustum_intersects_bounds(camera_frustum, bounds) {
            if data.draws[draw_index].blended {
                append(&transparent, Transparent_Draw{u32(draw_index), alg.length(bounds.center - camera_position)})
            } else {
                data.scene_indices[data.scene_draw_count] = u32(draw_index)
                data.scene_draw_count += 1
            }
        }

        if data.draws[draw_index].casts_shadow {
            r.culling_stats.shadow_total += 1

            for cascade in 0..<SHADOW_CASCADE_COUNT {
                if !r.frustum_culling_enabled ||
                   frustum_intersects_bounds(cascade_frustums[cascade], bounds) {
                    count := &data.shadow_draw_count[cascade]
                    data.shadow_indices[cascade][count^] = u32(draw_index)
                    count^ += 1
                }
            }
            for shadow, slot in spot_shadows {
                if shadow.entity < 0 do continue
                if r.frustum_culling_enabled && !frustum_intersects_bounds(spot_shadow_frustums[slot], bounds) do continue
                view := SHADOW_CASCADE_COUNT + slot
                data.shadow_indices[view][data.shadow_draw_count[view]] = u32(draw_index)
                data.shadow_draw_count[view] += 1
            }
            for shadow, slot in point_shadows {
                if shadow.entity < 0 do continue
                for face in 0..<POINT_SHADOW_FACES {
                    index := slot * POINT_SHADOW_FACES + face
                    if r.frustum_culling_enabled && !frustum_intersects_bounds(point_shadow_frustums[index], bounds) do continue
                    view := POINT_SHADOW_FIRST_VIEW + index
                    data.shadow_indices[view][data.shadow_draw_count[view]] = u32(draw_index)
                    data.shadow_draw_count[view] += 1
                }
            }
        }
    }

    // Back to front, so nearer surfaces blend over farther ones. Sorting by
    // submesh center is approximate: interpenetrating or large surfaces can
    // still blend in the wrong order.
    slice.sort_by(transparent[:], proc(a, b: Transparent_Draw) -> bool {return a.distance > b.distance})
    for draw, i in transparent do data.transparent_indices[i] = draw.index
    data.transparent_draw_count = len(transparent)

    r.previous_view_projection = view_projection

    data.scene_batches = renderer_batch_draws(data, data.scene_indices[:data.scene_draw_count], merge = true)
    data.transparent_batches = renderer_batch_draws(data, data.transparent_indices[:data.transparent_draw_count], merge = false)
    for view in 0..<SHADOW_VIEW_COUNT {
        data.shadow_batches[view] = renderer_batch_draws(data, data.shadow_indices[view][:data.shadow_draw_count[view]], merge = true)
        r.culling_stats.shadow_calls += len(data.shadow_batches[view])
    }

    r.culling_stats.scene_total = data.draw_count
    r.culling_stats.scene_visible = data.scene_draw_count + data.transparent_draw_count
    r.culling_stats.scene_calls = len(data.scene_batches) + len(data.transparent_batches)
    for count in data.shadow_draw_count {
        r.culling_stats.shadow_visible += count
    }

    return data
}

TAA_JITTER_SAMPLES :: 8

// Sub-pixel offset in pixels, in [-0.5, 0.5), from the Halton (2, 3) sequence:
// eight well-spread positions that repeat.
taa_jitter :: proc(frame: u64) -> [2]f32 {
    halton :: proc(index: u64, base: u64) -> f32 {
        result: f32 = 0
        fraction: f32 = 1
        i := index
        for i > 0 {
            fraction /= f32(base)
            result += fraction * f32(i % base)
            i /= base
        }
        return result
    }
    index := frame % TAA_JITTER_SAMPLES + 1
    return {halton(index, 2) - 0.5, halton(index, 3) - 0.5}
}
