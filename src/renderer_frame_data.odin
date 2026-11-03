package main

// The CPU's part of each frame: one Draw per entity submesh with its object
// data, the frame constants and visible lights, and every view's draws grouped
// into indirect calls. Then the GPU cull passes (cull.hlsl) that decide how
// many instances each call draws. docs/frame.md walks through it.

import "core:math"
import "core:slice"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"

CullingStats :: struct {
    // Submesh draws, and those casting shadows.
    scene_total, shadow_total: int,
    // From the cull pass, read back a few frames late.
    gpu: CullCounters,
    // More submesh draws than MAX_DRAWS, or calls than MAX_DRAW_CALLS, this
    // frame; the rest were skipped.
    draws_dropped: bool,
    // The camera's opaque meshlets this frame (in its frustum or not), and
    // their triangles.
    scene_meshlets, scene_meshlet_triangles: int,
}

// The cull pass's counters, at the start of the indirect call buffer: draws
// the camera sees and the calls they went into (early and late together;
// prepass and lit pass each make these), the same over all shadow views,
// then the camera's draws in its frustum but hidden behind others, and the
// camera's meshlets drawn and their triangles.
CullCounters :: struct {
    scene_visible, scene_calls: u32,
    shadow_visible, shadow_calls: u32,
    scene_occluded: u32,
    scene_meshlets, scene_meshlet_triangles: u32,
}

// Draws per frame: one per (entity, submesh). Sizes the object buffer.
MAX_DRAWS :: 4096
// Instance-list entries per frame: each view lists each draw at most once,
// and the views are the camera's early, late and blended lists plus every
// shadow view and probe capture face (the camera's three hold at most two of
// each draw). The cull entries fit in the same count.
MAX_INSTANCES :: (SHADOW_VIEW_COUNT + PROBE_FACES + 2) * MAX_DRAWS
// Levels of the depth pyramid for occlusion culling: up to 8192 texels.
HIZ_MAX_MIPS :: 14
// Indirect draw calls per frame; a view whose calls do not fit is skipped.
MAX_DRAW_CALLS :: 32768
// Meshlet culling (the camera's opaque draws; other views cull whole draws): cull
// entries for meshlets, the compacted index buffer the visible meshlets'
// triangles are copied into (32 MB), and the visibility flags the camera's
// meshlets keep across frames. Draws that do not fit are culled whole.
MAX_MESHLET_ENTRIES :: 1 << 18
MESHLET_INDEX_CAPACITY :: 1 << 23
MAX_MESHLET_FLAGS :: 1 << 20
MAX_CULL_ENTRIES :: MAX_INSTANCES + MAX_MESHLET_ENTRIES
#assert(MAX_INSTANCES == 163840) // cull.hlsl's MESHLET_ENTRY_BASE.

// Views the cull pass tests against: the camera, every shadow view, then the
// six faces of a reflection probe capture. Must match cull.hlsl.
CULL_VIEW_COUNT :: 1 + SHADOW_VIEW_COUNT + PROBE_FACES
#assert(CULL_VIEW_COUNT == 39)
// The counters' space before the calls in the indirect call buffer.
CULL_HEADER_SIZE :: 64
// One frame slot of the indirect call upload buffer: header, then calls.
INDIRECT_SLOT_SIZE :: CULL_HEADER_SIZE + MAX_DRAW_CALLS * size_of(IndirectDraw)

// One draw call as ExecuteIndirect reads it (the command signature in
// renderer_create_culling; offsets in cull.hlsl): the mesh's buffers, the
// root constant with the call's first instance-list entry, and the indexed
// draw, whose instance count the cull pass fills in.
IndirectDraw :: struct {
    vertex_buffer: d3d12.VERTEX_BUFFER_VIEW,
    index_buffer: d3d12.INDEX_BUFFER_VIEW,
    first_instance: u32,
    args: d3d12.DRAW_INDEXED_ARGUMENTS,
}
#assert(size_of(IndirectDraw) == 56)
#assert(offset_of(IndirectDraw, first_instance) == 32)
#assert(offset_of(IndirectDraw, args) + offset_of(d3d12.DRAW_INDEXED_ARGUMENTS, InstanceCount) == 40)

// A draw that a view may draw: the cull pass tests its bounds against the
// view and, if visible, adds it to the call. In the meshlet entries (after
// MAX_INSTANCES of them), one meshlet of a draw instead: if visible, its
// triangles join the call, and `flag` is its slot in the camera's meshlet
// visibility flags.
CullEntry :: struct {
    draw, command, view: u32,
    meshlet, flag: u32,
}

// A draw's world-space box, for the cull pass (WorldBounds without `valid`),
// and for its meshlets, the draw's world matrix: its rows (mesh space to
// world), its largest axis scale (for the spheres), and whether normal cones
// apply (a uniform scale and back faces culled).
CullBounds :: struct {
    center: [3]f32,
    half_axes: [3][3]f32,
    model_rows: [3][4]f32,
    max_scale: f32,
    cone_ok: u32,
    _pad: [2]f32,
}
#assert(size_of(CullBounds) == 112)

// One meshlet for the cull pass (renderer_rebuild_meshlets): its mesh-space
// sphere and normal cone (Meshlet), its triangles in the mesh's index
// buffer, and that buffer's SRV slot.
GpuMeshlet :: struct {
    center: [3]f32,
    radius: f32,
    cone_axis: [3]f32,
    cone_cutoff: f32,
    first_index, index_count: u32,
    index_buffer: u32,
    _pad: u32,
}
#assert(size_of(GpuMeshlet) == 48)

// Per frame slot, read by the cull pass; laid out like cull.hlsl's cbuffer.
CullConstants :: struct #align(256) {
    view_planes: [CULL_VIEW_COUNT][6][4]f32,
    // The camera's unjittered view-projection, for the depth pyramid test.
    view_projection: alg.Matrix4f32,
    hiz_size: [2]f32,
    hiz_mip_count: u32,
    occlusion_enabled: u32,
    entry_count: u32,
    culling_enabled: u32,
    // Entries come as the camera's opaque draws, its blended ones, then the
    // shadow views'.
    opaque_entry_count, camera_entry_count: u32,
    // The camera's late calls are copies of its early ones, this many
    // commands on.
    late_command_offset: u32,
    // The meshlet entries, the camera's first, from entry MAX_INSTANCES on.
    meshlet_entry_count, camera_meshlet_entry_count: u32,
    _pad: u32,
    // Where the camera looks from, for meshlets' normal cones (w unused).
    camera_position: [4]f32,
}
#assert(offset_of(CullConstants, view_projection) == 3744)
#assert(offset_of(CullConstants, late_command_offset) == 3840)
#assert(offset_of(CullConstants, camera_position) == 3856)

// How a draw's material changes its pipelines (one per variant in each mesh
// pass): cutouts discard pixels in the depth-only passes, and double-sided
// materials draw without back-face culling. Blended draws use the cutout
// variants in the shadow pass.
Draw_Variant :: enum u8 {Opaque, Masked, Double_Sided, Masked_Double_Sided}

// One submesh of one entity, with the material of its slot.
Draw :: struct {
    mesh: MeshHandle,
    first_index, index_count: u32,
    variant: Draw_Variant,
    // Alpha-blended: drawn in the transparent pass instead of the prepass and
    // lit pass.
    blended: bool,
    bounds: WorldBounds,
    casts_shadow: bool,
    // What a cutout's shadow depends on besides its placement, for the
    // shadow atlas's change test.
    alpha_texture: TextureHandle,
    alpha_cutoff: f32,
    // Its submesh's meshlets in the meshlet buffer (none: culled whole), and
    // its first slot in the camera's meshlet visibility flags.
    first_meshlet, meshlet_count: u32,
    meshlet_flag: u32,
}

// One draw call: indirect call `command`, drawing instances of `draw`'s
// submesh with its pipeline variant. The cull pass decides how many (none,
// if every draw it could hold is out of view). A view's calls are
// consecutive commands.
DrawBatch :: struct {
    draw: u32,
    command: u32,
    // A meshlet call's region in the compacted index buffer, or -1.
    meshlet_region: i32,
}

// A kind of view's candidate draws grouped into calls: call i takes
// draws[starts[i]:starts[i + 1]]. Every shadow view shares one.
DrawLayout :: struct {
    draws: []u32,
    starts: []u32,
}

// Rebuilt every frame; lives in the renderer (too large for the stack).
FrameDraws :: struct {
    draws: [MAX_DRAWS]Draw,
    draw_count: int,

    caster_bounds: [MAX_DRAWS]WorldBounds,
    caster_count: int,

    // The draw calls of the camera's opaque and blended draws and of each
    // shadow view (in the frame's temp allocator): every draw the view
    // might see, culled on the GPU. Shadow views without a light have none.
    // The camera's opaque draws have two sets of calls: early ones for what
    // it saw last frame, and late ones (the same calls, with their own
    // instances) for what the depth pyramid shows it now sees as well.
    scene_batches, late_scene_batches, transparent_batches: []DrawBatch,
    shadow_batches: [SHADOW_VIEW_COUNT][]DrawBatch,
    // The opaque draws of each probe capture face; none unless a probe is
    // captured this frame.
    probe_batches: [PROBE_FACES][]DrawBatch,
    // How much of this frame's instance list, cull entries and indirect
    // calls those use, and of the compacted index buffer and meshlet entries.
    instance_count, entry_count, command_count: int,
    meshlet_index_count, meshlet_entry_count: int,
    // The camera's meshlet entries come first; the late cull runs over these.
    camera_meshlet_entry_count: int,
    // The camera's entries come first; the late cull runs over just these.
    camera_entry_count: int,
}

// Groups candidate draws into calls. With `merge`, draws of the same submesh
// range and variant become one call, whatever their materials (textures are
// bindless); the calls are sorted by variant, so pipelines change rarely.
// Draws with meshlets stay calls of their own, since each draws only its
// visible meshlets. Without `merge`, every draw is its own call in the given
// order (blended draws, sorted back to front).
renderer_batch_draws :: proc(data: ^FrameDraws, indices: []u32, merge: bool) -> DrawLayout {
    Batch_Key :: struct {
        variant: Draw_Variant,
        mesh: MeshHandle,
        first_index, index_count: u32,
        draw: u32,
        meshlets: bool,
    }
    same_batch :: proc(a, b: Batch_Key) -> bool {
        return !a.meshlets && !b.meshlets && a.variant == b.variant && a.mesh == b.mesh &&
               a.first_index == b.first_index && a.index_count == b.index_count
    }

    keys := make([]Batch_Key, len(indices), context.temp_allocator)
    for draw_index, i in indices {
        draw := &data.draws[draw_index]
        keys[i] = {draw.variant, draw.mesh, draw.first_index, draw.index_count, draw_index, draw.meshlet_count > 0}
    }
    if merge {
        slice.sort_by(keys, proc(a, b: Batch_Key) -> bool {
            if a.variant != b.variant do return a.variant < b.variant
            if a.mesh != b.mesh do return a.mesh < b.mesh
            if a.first_index != b.first_index do return a.first_index < b.first_index
            if a.index_count != b.index_count do return a.index_count < b.index_count
            return a.draw < b.draw
        })
    }

    layout := DrawLayout{draws = make([]u32, len(keys), context.temp_allocator)}
    starts := make([dynamic]u32, 0, len(keys) + 1, context.temp_allocator)
    for key, i in keys {
        if !merge || i == 0 || !same_batch(key, keys[i - 1]) do append(&starts, u32(i))
        layout.draws[i] = key.draw
    }
    append(&starts, u32(len(keys)))
    layout.starts = starts[:]
    return layout
}

// Gives `view` (0: the camera; 1 + n: shadow view n) its own copy of a
// layout's calls: one indirect call each, with room in the instance list for
// all its draws, and a cull entry per draw (unless `with_entries` is off: the
// camera's late calls, which the early calls' entries fill). Returns nothing,
// and marks draws as dropped, if the calls do not fit this frame.
//
// With `meshlets` (the camera's opaque draws), a draw with meshlets gets a
// call over its own region of the compacted index buffer (as large as its
// index range), which the cull pass fills with its visible meshlets'
// triangles, and a cull entry per meshlet. Draws that would overflow the
// region or entry budgets are culled whole. The late calls (`early`: the
// calls they copy) share their early call's region: the cull pass puts the
// late meshlets after the early ones.
renderer_add_view_batches :: proc(data: ^FrameDraws, layout: DrawLayout, view: u32, with_entries := true, meshlets := false, early: []DrawBatch = nil) -> []DrawBatch {
    r := &g_renderer
    call_count := len(layout.starts) - 1
    if call_count <= 0 do return nil
    if data.command_count + call_count > MAX_DRAW_CALLS {
        r.culling_stats.draws_dropped = true
        return nil
    }
    commands := renderer_frame_indirect_draws()
    entries := r.cull_entry_mapped[int(r.frame_slot) * MAX_CULL_ENTRIES:]
    batches := make([]DrawBatch, call_count, context.temp_allocator)
    for call in 0..<call_count {
        first, end := layout.starts[call], layout.starts[call + 1]
        draw := &data.draws[layout.draws[first]]
        command := u32(data.command_count)
        mesh := &r.meshes[draw.mesh]
        region := i32(-1)
        if early != nil {
            region = early[call].meshlet_region
        } else if meshlets && draw.meshlet_count > 0 &&
                  data.meshlet_index_count + int(draw.index_count) <= MESHLET_INDEX_CAPACITY &&
                  data.meshlet_entry_count + int(draw.meshlet_count) <= MAX_MESHLET_ENTRIES {
            region = i32(data.meshlet_index_count)
            data.meshlet_index_count += int(draw.index_count)
        }
        if region >= 0 {
            // One draw; the cull pass adds each visible meshlet's indices
            // (and sets a late call's start, after the early ones).
            commands[command] = IndirectDraw{
                vertex_buffer = mesh.vertex_buffer_view,
                index_buffer = r.meshlet_index_view,
                first_instance = u32(data.instance_count) + first,
                args = {InstanceCount = 1, StartIndexLocation = u32(region)},
            }
            draw_index := layout.draws[first]
            if with_entries do for m in 0..<draw.meshlet_count {
                entries[MAX_INSTANCES + data.meshlet_entry_count] = {draw_index, command, view, draw.first_meshlet + m, draw.meshlet_flag + m}
                data.meshlet_entry_count += 1
            }
            if view == 0 && with_entries {
                r.culling_stats.scene_meshlets += int(draw.meshlet_count)
                r.culling_stats.scene_meshlet_triangles += int(draw.index_count / 3)
            }
        } else {
            commands[command] = IndirectDraw{
                vertex_buffer = mesh.vertex_buffer_view,
                index_buffer = mesh.index_buffer_view,
                first_instance = u32(data.instance_count) + first,
                args = {IndexCountPerInstance = draw.index_count, StartIndexLocation = draw.first_index},
            }
            if with_entries do for draw_index in layout.draws[first:end] {
                assert(data.entry_count < MAX_CULL_ENTRIES)
                entries[data.entry_count] = {draw_index, command, view, 0, 0}
                data.entry_count += 1
            }
        }
        batches[call] = {layout.draws[first], command, region}
        data.command_count += 1
    }
    assert(data.instance_count + len(layout.draws) <= MAX_INSTANCES)
    data.instance_count += len(layout.draws)
    return batches
}

renderer_prepare_frame :: proc(scene: ^Scene) -> ^FrameDraws {
    r := &g_renderer
    r.culling_stats = {gpu = r.culling_stats.gpu}
    data := &r.frame_draws
    data.draw_count = 0
    data.caster_count = 0
    data.instance_count = 0
    data.entry_count = 0
    data.command_count = 0
    data.meshlet_index_count = 0
    data.meshlet_entry_count = 0
    // Each draw with meshlets takes the next slots in the camera's meshlet
    // visibility flags: the same draws in the same order each frame keep
    // their flags.
    meshlet_flags := 0

    post := &r.post_cb_mapped_data[r.frame_slot]
    sky := &r.sky_cb_mapped_data[r.frame_slot]
    objects := r.object_mapped[int(r.frame_slot) * MAX_DRAWS:]
    cull_bounds := r.cull_bounds_mapped[int(r.frame_slot) * MAX_DRAWS:]
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

    // A probe captured this frame sees in every direction, so it needs every
    // light, not only those reaching the camera's view.
    renderer_update_probes(scene)
    capturing := renderer_capturing()


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
        // For meshlets: their spheres scale by the largest axis, and their
        // normal cones only hold under a uniform scale.
        axis_scales := [3]f32{
            alg.length(alg.Vector3f32{model[0, 0], model[1, 0], model[2, 0]}),
            alg.length(alg.Vector3f32{model[0, 1], model[1, 1], model[2, 1]}),
            alg.length(alg.Vector3f32{model[0, 2], model[1, 2], model[2, 2]}),
        }
        max_scale := max(axis_scales[0], axis_scales[1], axis_scales[2])
        uniform_scale := min(axis_scales[0], axis_scales[1], axis_scales[2]) > max_scale * 0.999

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

            // Bindless: the shaders index the SRV heap with these.
            texture_indices: [MATERIAL_TEXTURE_COUNT]u32
            for texture, t in textures {
                assert(assets_texture_valid(texture))
                texture_indices[t] = r.textures[texture].srv_index
            }

            draw^ = Draw{
                mesh = mesh,
                first_index = submesh.first_index,
                index_count = submesh.index_count,
                variant = Draw_Variant(int(cutout) + 2 * int(material.double_sided)),
                blended = material.alpha_blend,
                bounds = bounds_to_world(submesh.bounds, model),
                // Unlit marker meshes do not cast shadows.
                casts_shadow = !material.unlit,
                alpha_texture = material.texture if cutout else 0,
                alpha_cutoff = alpha_cutoff if cutout else 0,
            }
            if r.meshlet_culling_enabled && submesh.meshlet_count > 0 && meshlet_flags + int(submesh.meshlet_count) <= MAX_MESHLET_FLAGS {
                draw.first_meshlet = r.meshes[mesh].first_meshlet + submesh.first_meshlet
                draw.meshlet_count = submesh.meshlet_count
                draw.meshlet_flag = u32(meshlet_flags)
                meshlet_flags += int(submesh.meshlet_count)
            }

            if draw.casts_shadow {
                data.caster_bounds[data.caster_count] = draw.bounds
                data.caster_count += 1
            }
            // Without bounds, huge axes keep the draw in every view.
            cull_bounds[data.draw_count] = CullBounds{
                center = draw.bounds.center,
                half_axes = draw.bounds.half_axes if draw.bounds.valid else {{1e30, 0, 0}, {0, 1e30, 0}, {0, 0, 1e30}},
                model_rows = {
                    {model[0, 0], model[0, 1], model[0, 2], model[0, 3]},
                    {model[1, 0], model[1, 1], model[1, 2], model[1, 3]},
                    {model[2, 0], model[2, 1], model[2, 2], model[2, 3]},
                },
                max_scale = max_scale,
                cone_ok = u32(uniform_scale && !material.double_sided),
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
                textures = texture_indices,
            }
            data.draw_count += 1
        }
    }

    // Shadow-casting lights get atlas tiles, drawn when they or the casters
    // around them changed; the lights below point at their tiles.
    renderer_update_shadow_atlas(scene, data, camera_position, camera_frustum)

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
        }

        if atlas := renderer_shadow_light_of(i, scene.has_point_light[i]); atlas != nil && atlas.gpu_index >= 0 {
            light.shadow_index = i32(atlas.gpu_index)
            light.shadow_texel_scale = atlas.texel_scale
        }

        // The range sphere's box against the camera frustum.
        range_bounds := WorldBounds{
            center = light.position,
            half_axes = {{light.range, 0, 0}, {0, light.range, 0}, {0, 0, light.range}},
            valid = true,
        }
        if r.frustum_culling_enabled && !capturing && !frustum_intersects_bounds(camera_frustum, range_bounds) {
            continue
        }
        assert(light_count < MAX_LIGHTS)
        frame_lights[light_count] = light
        light_count += 1
    }
    r.visible_light_count = light_count

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
    shadow_view_projection: [SHADOW_TILE_VIEWS]alg.Matrix4f32
    for view, i in r.shadow_tile_views[:r.shadow_tile_view_count] do shadow_view_projection[i] = view.view_projection
    constants := FrameConstants{
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
        probe_count = u32(r.probes.count),
        probe_diffuse = u32(r.probes.diffuse),
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
        volume_count = u32(r.volumes.count),
        volume_show = u32(r.volumes.show),
        shadow_view_projection = shadow_view_projection,
    }
    r.frame_cb_mapped_data[r.frame_slot] = constants
    if capturing do renderer_write_probe_capture_constants(constants, sky^, camera_far_clip(camera))

    r.previous_view_projection = view_projection

    // Every draw goes to the GPU as a candidate for each view that could
    // draw it; the cull pass (renderer_cull_draws) tests them. Blended draws
    // keep a back-to-front order (for their motion vectors), so they are
    // sorted here, culled or not.
    Transparent_Draw :: struct {index: u32, distance: f32}
    transparent := make([dynamic]Transparent_Draw, context.temp_allocator)
    opaque := make([dynamic]u32, context.temp_allocator)
    casters := make([dynamic]u32, context.temp_allocator)
    for draw, draw_index in data.draws[:data.draw_count] {
        if draw.blended {
            append(&transparent, Transparent_Draw{u32(draw_index), alg.length(draw.bounds.center - camera_position)})
        } else {
            append(&opaque, u32(draw_index))
        }
        if draw.casts_shadow do append(&casters, u32(draw_index))
    }

    // Back to front. Blending is order-independent, so this only decides
    // whose motion vector wins where blended surfaces overlap: the last one
    // drawn, the nearest by submesh center.
    slice.sort_by(transparent[:], proc(a, b: Transparent_Draw) -> bool {return a.distance > b.distance})
    transparent_order := make([]u32, len(transparent), context.temp_allocator)
    for draw, i in transparent do transparent_order[i] = draw.index

    // The camera's calls come first, so they always fit: early, late, then
    // blended. The cull pass tells the entries apart by these counts.
    opaque_layout := renderer_batch_draws(data, opaque[:], merge = true)
    data.scene_batches = renderer_add_view_batches(data, opaque_layout, 0, meshlets = true)
    opaque_entry_count := data.entry_count
    late_command_offset := data.command_count
    data.late_scene_batches = renderer_add_view_batches(data, opaque_layout, 0, with_entries = false, early = data.scene_batches)
    data.transparent_batches = renderer_add_view_batches(data, renderer_batch_draws(data, transparent_order, merge = false), 0)
    data.camera_entry_count = data.entry_count
    data.camera_meshlet_entry_count = data.meshlet_entry_count

    // Only the cascades and this frame's atlas views get calls.
    view_frustums: [CULL_VIEW_COUNT]Frustum
    view_frustums[0] = camera_frustum
    view_active: [SHADOW_VIEW_COUNT]bool
    for cascade in 0..<SHADOW_CASCADE_COUNT {
        view_frustums[1 + cascade] = cascade_frustums[cascade]
        view_active[cascade] = true
    }
    for view, i in r.shadow_tile_views[:r.shadow_tile_view_count] {
        view_frustums[1 + SHADOW_CASCADE_COUNT + i] = frustum_from_matrix(view.view_projection)
        view_active[SHADOW_CASCADE_COUNT + i] = true
    }
    caster_layout := renderer_batch_draws(data, casters[:], merge = true)
    for view in 0..<SHADOW_VIEW_COUNT {
        data.shadow_batches[view] = renderer_add_view_batches(data, caster_layout, u32(1 + view)) if view_active[view] else nil
    }
    // A probe capture draws the opaque surfaces, like the camera, in each face.
    data.probe_batches = {}
    if capturing {
        faces := renderer_probe_face_view_projections(camera_far_clip(camera))
        for face_view_projection, face in faces {
            view_frustums[PROBE_FIRST_CULL_VIEW + face] = frustum_from_matrix(face_view_projection)
            data.probe_batches[face] = renderer_add_view_batches(data, opaque_layout, u32(PROBE_FIRST_CULL_VIEW + face))
        }
    }

    cull := &r.cull_constants_mapped[r.frame_slot]
    for frustum, view in view_frustums do cull.view_planes[view] = transmute([6][4]f32)frustum.planes
    cull.view_projection = view_projection
    cull.hiz_size = {f32(r.hiz_width), f32(r.hiz_height)}
    cull.hiz_mip_count = r.hiz_mip_count
    cull.occlusion_enabled = u32(r.occlusion_culling_enabled)
    cull.entry_count = u32(data.entry_count)
    cull.culling_enabled = u32(r.frustum_culling_enabled)
    cull.opaque_entry_count = u32(opaque_entry_count)
    cull.camera_entry_count = u32(data.camera_entry_count)
    cull.late_command_offset = u32(late_command_offset)
    cull.meshlet_entry_count = u32(data.meshlet_entry_count)
    cull.camera_meshlet_entry_count = u32(data.camera_meshlet_entry_count)
    cull.camera_position = {camera_position.x, camera_position.y, camera_position.z, 1}
    // The counters start at zero; the calls follow them.
    (^CullCounters)(renderer_frame_indirect_header())^ = {}

    r.culling_stats.scene_total = data.draw_count
    r.culling_stats.shadow_total = len(casters)
    return data
}

// This frame slot's indirect calls in the upload buffer, which
// renderer_cull_draws copies to the GPU's.
renderer_frame_indirect_draws :: proc() -> [^]IndirectDraw {
    return ([^]IndirectDraw)(renderer_frame_indirect_header()[CULL_HEADER_SIZE:])
}

renderer_frame_indirect_header :: proc() -> [^]u8 {
    r := &g_renderer
    return r.indirect_upload_mapped[int(r.frame_slot) * INDIRECT_SLOT_SIZE:]
}

// The cull pass's root signature and its buffers, for either phase. `late`
// selects the phase (cull.hlsl's g_pass.x).
renderer_bind_cull :: proc(late: bool) {
    r := &g_renderer
    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetComputeRootSignature(r.cull_root_signature)
    r.command_list->SetPipelineState(r.cull_pipeline_state)
    pass := [4]u32{u32(late), 0, 0, 0}
    r.command_list->SetComputeRoot32BitConstants(u32(Cull_Root_Slot.Pass_Constants), 4, &pass[0], 0)
    r.command_list->SetComputeRootConstantBufferView(u32(Cull_Root_Slot.Constants),
        r.cull_constant_buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * size_of(CullConstants))
    r.command_list->SetComputeRootShaderResourceView(u32(Cull_Root_Slot.Entries),
        r.cull_entry_buffer->GetGPUVirtualAddress() + u64(int(r.frame_slot) * MAX_CULL_ENTRIES * size_of(CullEntry)))
    r.command_list->SetComputeRootShaderResourceView(u32(Cull_Root_Slot.Bounds),
        r.cull_bounds_buffer->GetGPUVirtualAddress() + u64(int(r.frame_slot) * MAX_DRAWS * size_of(CullBounds)))
    r.command_list->SetComputeRootDescriptorTable(u32(Cull_Root_Slot.Hiz), renderer_srv_gpu(r.hiz_srv_start))
    r.command_list->SetComputeRootUnorderedAccessView(u32(Cull_Root_Slot.Commands), r.indirect_buffer->GetGPUVirtualAddress())
    r.command_list->SetComputeRootUnorderedAccessView(u32(Cull_Root_Slot.Instances), r.instance_buffer->GetGPUVirtualAddress())
    r.command_list->SetComputeRootUnorderedAccessView(u32(Cull_Root_Slot.Visibility), r.visibility_buffer->GetGPUVirtualAddress())
    r.command_list->SetComputeRootShaderResourceView(u32(Cull_Root_Slot.Meshlets), r.meshlet_buffer->GetGPUVirtualAddress())
    r.command_list->SetComputeRootDescriptorTable(u32(Cull_Root_Slot.Mesh_Indices), renderer_srv_gpu(0))
    r.command_list->SetComputeRootUnorderedAccessView(u32(Cull_Root_Slot.Meshlet_Indices), r.meshlet_index_buffer->GetGPUVirtualAddress())
    r.command_list->SetComputeRootUnorderedAccessView(u32(Cull_Root_Slot.Meshlet_Visibility), r.meshlet_flag_buffer->GetGPUVirtualAddress())
}

// The early cull (cull.hlsl): copies this frame's indirect calls to the GPU,
// then fills in the shadow views' calls and the camera's early ones (what it
// saw last frame). Runs before the shadow pass.
renderer_cull_draws :: proc(data: ^FrameDraws) {
    r := &g_renderer
    renderer_begin_gpu_pass(.Culling)
    defer renderer_end_gpu_pass(.Culling)

    // The buffers decay to the common state after each frame's commands.
    barriers := [5]d3d12.RESOURCE_BARRIER{
        resource_transition(r.indirect_buffer, d3d12.RESOURCE_STATE_COMMON, {.COPY_DEST}),
        resource_transition(r.instance_buffer, d3d12.RESOURCE_STATE_COMMON, {.UNORDERED_ACCESS}),
        resource_transition(r.visibility_buffer, d3d12.RESOURCE_STATE_COMMON, {.UNORDERED_ACCESS}),
        resource_transition(r.meshlet_index_buffer, d3d12.RESOURCE_STATE_COMMON, {.UNORDERED_ACCESS}),
        resource_transition(r.meshlet_flag_buffer, d3d12.RESOURCE_STATE_COMMON, {.UNORDERED_ACCESS}),
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
    r.command_list->CopyBufferRegion(
        r.indirect_buffer, 0, r.indirect_upload_buffer, u64(int(r.frame_slot) * INDIRECT_SLOT_SIZE),
        u64(CULL_HEADER_SIZE + data.command_count * size_of(IndirectDraw)),
    )
    barriers[0] = resource_transition(r.indirect_buffer, {.COPY_DEST}, {.UNORDERED_ACCESS})
    r.command_list->ResourceBarrier(1, &barriers[0])

    renderer_bind_cull(late = false)
    if data.entry_count > 0 do r.command_list->Dispatch(u32(data.entry_count + 63) / 64, 1, 1)
    renderer_dispatch_meshlet_cull(data.meshlet_entry_count)

    barriers[0] = resource_transition(r.indirect_buffer, {.UNORDERED_ACCESS}, {.INDIRECT_ARGUMENT})
    barriers[1] = resource_transition(r.instance_buffer, {.UNORDERED_ACCESS}, {.NON_PIXEL_SHADER_RESOURCE})
    barriers[2] = resource_transition(r.meshlet_index_buffer, {.UNORDERED_ACCESS}, {.INDEX_BUFFER})
    r.command_list->ResourceBarrier(3, &barriers[0])
}

// One 32-thread group per meshlet entry (CSCullMeshlets), on a 2D grid since
// a dispatch dimension holds at most 65535 groups. Leaves the meshlet
// pipeline set.
renderer_dispatch_meshlet_cull :: proc(count: int) {
    if count == 0 do return
    r := &g_renderer
    r.command_list->SetPipelineState(r.cull_meshlet_pipeline_state)
    r.command_list->Dispatch(u32(min(count, MESHLET_GROUPS_PER_ROW)), u32((count + MESHLET_GROUPS_PER_ROW - 1) / MESHLET_GROUPS_PER_ROW), 1)
}
MESHLET_GROUPS_PER_ROW :: 65535

// Between the prepass's early and late draws (the depth buffer readable by
// compute): builds the depth pyramid from the early depth, then the late
// cull fills in the camera's late and blended calls and records what the
// camera sees for next frame. Copies the counters for the panel. Leaves the
// compute root signature set.
renderer_cull_late :: proc(data: ^FrameDraws) {
    r := &g_renderer
    renderer_begin_gpu_pass(.Occlusion)
    defer renderer_end_gpu_pass(.Occlusion)

    renderer_bind_cull(late = true)
    if r.occlusion_culling_enabled {
        renderer_begin_event("Depth pyramid")
        renderer_build_hiz()
        renderer_end_event()
    }

    barriers := [3]d3d12.RESOURCE_BARRIER{
        resource_transition(r.indirect_buffer, {.INDIRECT_ARGUMENT}, {.UNORDERED_ACCESS}),
        resource_transition(r.instance_buffer, {.NON_PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS}),
        resource_transition(r.meshlet_index_buffer, {.INDEX_BUFFER}, {.UNORDERED_ACCESS}),
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
    // The early cull read the visibility flags (draws' and meshlets') that
    // this one rewrites.
    visibility_done := [2]d3d12.RESOURCE_BARRIER{{Type = .UAV}, {Type = .UAV}}
    visibility_done[0].UAV = {pResource = r.visibility_buffer}
    visibility_done[1].UAV = {pResource = r.meshlet_flag_buffer}
    r.command_list->ResourceBarrier(len(visibility_done), &visibility_done[0])

    if data.camera_entry_count > 0 {
        r.command_list->SetPipelineState(r.cull_pipeline_state)
        r.command_list->Dispatch(u32(data.camera_entry_count + 63) / 64, 1, 1)
    }
    renderer_dispatch_meshlet_cull(data.camera_meshlet_entry_count)

    barriers[0] = resource_transition(r.indirect_buffer, {.UNORDERED_ACCESS}, {.INDIRECT_ARGUMENT, .COPY_SOURCE})
    barriers[1] = resource_transition(r.instance_buffer, {.UNORDERED_ACCESS}, {.NON_PIXEL_SHADER_RESOURCE})
    barriers[2] = resource_transition(r.meshlet_index_buffer, {.UNORDERED_ACCESS}, {.INDEX_BUFFER})
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])
    r.command_list->CopyBufferRegion(r.cull_readback, u64(r.frame_slot) * size_of(CullCounters), r.indirect_buffer, 0, size_of(CullCounters))
}

// Builds the depth pyramid level by level, each from the one before (level
// 0 from the depth buffer). Between frames the whole pyramid is readable by
// compute; each level is written as a UAV in turn. The cull root signature
// must be set.
renderer_build_hiz :: proc() {
    r := &g_renderer
    r.command_list->SetPipelineState(r.hiz_pipeline_state)
    source_size := [2]u32{r.width, r.height}
    for level in 0..<r.hiz_mip_count {
        target_size := [2]u32{max(r.hiz_width >> level, 1), max(r.hiz_height >> level, 1)}
        barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
        barrier.Transition = {
            pResource = r.hiz_texture, Subresource = level,
            StateBefore = {.NON_PIXEL_SHADER_RESOURCE}, StateAfter = {.UNORDERED_ACCESS},
        }
        r.command_list->ResourceBarrier(1, &barrier)

        sizes := [4]u32{source_size.x, source_size.y, target_size.x, target_size.y}
        r.command_list->SetComputeRoot32BitConstants(u32(Cull_Root_Slot.Pass_Constants), 4, &sizes[0], 0)
        source := r.depth_srv_index if level == 0 else r.hiz_srv_start + level
        r.command_list->SetComputeRootDescriptorTable(u32(Cull_Root_Slot.Hiz_Source), renderer_srv_gpu(source))
        r.command_list->SetComputeRootDescriptorTable(u32(Cull_Root_Slot.Hiz_Target), renderer_srv_gpu(r.hiz_uav_start + level))
        r.command_list->Dispatch((target_size.x + 7) / 8, (target_size.y + 7) / 8, 1)

        barrier.Transition.StateBefore = {.UNORDERED_ACCESS}
        barrier.Transition.StateAfter = {.NON_PIXEL_SHADER_RESOURCE}
        r.command_list->ResourceBarrier(1, &barrier)
        source_size = target_size
    }
    // Back to the late cull's phase constant.
    pass := [4]u32{1, 0, 0, 0}
    r.command_list->SetComputeRoot32BitConstants(u32(Cull_Root_Slot.Pass_Constants), 4, &pass[0], 0)
}

// (Re)creates the depth pyramid: the power of two at or below the window
// size in each direction, down to one texel. Called with the other
// screen-sized targets, at startup and on resize; its views keep their
// heap slots.
renderer_create_hiz :: proc() {
    r := &g_renderer
    floor_pow2 :: proc(x: u32) -> u32 {
        p := u32(1)
        for p * 2 <= x do p *= 2
        return p
    }
    r.hiz_width = floor_pow2(r.width)
    r.hiz_height = floor_pow2(r.height)
    r.hiz_mip_count = 1
    for max(r.hiz_width, r.hiz_height) >> r.hiz_mip_count > 0 do r.hiz_mip_count += 1
    assert(r.hiz_mip_count <= HIZ_MAX_MIPS)

    // The full pyramid (culling), each level alone (building the next), and
    // each level's UAV.
    if r.hiz_srv_start == 0 {
        r.hiz_srv_start = renderer_alloc_srv(1 + HIZ_MAX_MIPS)
        r.hiz_uav_start = renderer_alloc_srv(HIZ_MAX_MIPS)
    }

    heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.hiz_width),
        Height = r.hiz_height,
        DepthOrArraySize = 1,
        MipLevels = u16(r.hiz_mip_count),
        Format = .R32_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_UNORDERED_ACCESS},
    }
    dx_check(r.device->CreateCommittedResource(
        &heap, {}, &desc, {.NON_PIXEL_SHADER_RESOURCE}, nil,
        d3d12.IResource_UUID, (^rawptr)(&r.hiz_texture),
    ))

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R32_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = r.hiz_mip_count}
    r.device->CreateShaderResourceView(r.hiz_texture, &srv_desc, renderer_srv_cpu(r.hiz_srv_start))
    for level in 0..<r.hiz_mip_count {
        srv_desc.Texture2D = {MostDetailedMip = level, MipLevels = 1}
        r.device->CreateShaderResourceView(r.hiz_texture, &srv_desc, renderer_srv_cpu(r.hiz_srv_start + 1 + level))
        uav_desc := d3d12.UNORDERED_ACCESS_VIEW_DESC{Format = .R32_FLOAT, ViewDimension = .TEXTURE2D}
        uav_desc.Texture2D = {MipSlice = level}
        r.device->CreateUnorderedAccessView(r.hiz_texture, nil, &uav_desc, renderer_srv_cpu(r.hiz_uav_start + level))
    }
}

// The counters frame `slot` counted, once the GPU has finished it.
renderer_read_cull_counters :: proc(slot: u32) {
    r := &g_renderer
    read_range := d3d12.RANGE{Begin = uint(slot) * size_of(CullCounters), End = uint(slot + 1) * size_of(CullCounters)}
    mapped: rawptr
    dx_check(r.cull_readback->Map(0, &read_range, &mapped))
    // Map returns the buffer's start.
    r.culling_stats.gpu = ([^]CullCounters)(mapped)[slot]
    written_range := d3d12.RANGE{}
    r.cull_readback->Unmap(0, &written_range)
}

Cull_Root_Slot :: enum u32 {
    Constants,      // b0
    Pass_Constants, // b1: root constants, the phase or the pyramid level sizes
    Entries,        // t0: root SRV
    Bounds,         // t1: root SRV
    Hiz,            // t2: the whole depth pyramid
    Hiz_Source,     // t3: the level (or depth) a pyramid level is built from
    Commands,       // u0: root UAV, the indirect calls
    Instances,      // u1: root UAV, the instance list
    Hiz_Target,     // u2: the pyramid level being built
    Visibility,     // u3: root UAV, what the camera saw last frame
    Meshlets,       // t4: root SRV, every mesh's meshlets (GpuMeshlet)
    Mesh_Indices,   // t0 in space 1: the SRV heap, for meshes' index buffers
    Meshlet_Indices, // u4: root UAV, the compacted index buffer
    Meshlet_Visibility, // u5: root UAV, what the camera's meshlets showed last frame
}

// The cull pass's buffers and root signature, and the command signature the
// mesh passes draw with. The pipeline is built with the others
// (renderer_build_pipelines). Needs the main root signature.
renderer_create_culling :: proc() {
    r := &g_renderer
    mapped: rawptr
    r.cull_constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * size_of(CullConstants)))
    r.cull_constants_mapped = ([^]CullConstants)(mapped)
    r.cull_entry_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_CULL_ENTRIES * size_of(CullEntry)))
    r.cull_entry_mapped = ([^]CullEntry)(mapped)
    r.cull_bounds_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_DRAWS * size_of(CullBounds)))
    r.cull_bounds_mapped = ([^]CullBounds)(mapped)
    r.indirect_upload_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * INDIRECT_SLOT_SIZE))
    r.indirect_upload_mapped = ([^]u8)(mapped)

    // One of each on the GPU: frames run in order on the one queue.
    r.indirect_buffer = create_buffer(INDIRECT_SLOT_SIZE, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    r.instance_buffer = create_buffer(MAX_INSTANCES * size_of(u32), .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    // Kept across frames; starts zeroed, so the first frame draws everything late.
    r.visibility_buffer = create_buffer(MAX_DRAWS * size_of(u32), .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    r.cull_readback = create_buffer(FRAME_COUNT * size_of(CullCounters), .READBACK, {}, {.COPY_DEST})
    // Meshlets: the compacted indices of the visible ones (drawn as an index
    // buffer), and the camera's meshlet visibility, kept across frames.
    r.meshlet_index_buffer = create_buffer(MESHLET_INDEX_CAPACITY * size_of(u32), .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    r.meshlet_index_view = {
        BufferLocation = r.meshlet_index_buffer->GetGPUVirtualAddress(),
        SizeInBytes = MESHLET_INDEX_CAPACITY * size_of(u32),
        Format = .R32_UINT,
    }
    r.meshlet_flag_buffer = create_buffer(MAX_MESHLET_FLAGS * size_of(u32), .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)

    ranges := #partial [Cull_Root_Slot]d3d12.DESCRIPTOR_RANGE{
        .Hiz = {RangeType = .SRV, NumDescriptors = 1, BaseShaderRegister = 2},
        .Hiz_Source = {RangeType = .SRV, NumDescriptors = 1, BaseShaderRegister = 3},
        .Hiz_Target = {RangeType = .UAV, NumDescriptors = 1, BaseShaderRegister = 2},
        // The whole SRV heap as raw buffers, for the meshes' index buffers.
        .Mesh_Indices = {RangeType = .SRV, NumDescriptors = SRV_HEAP_CAPACITY, BaseShaderRegister = 0, RegisterSpace = 1},
    }
    params: [Cull_Root_Slot]d3d12.ROOT_PARAMETER
    params[.Constants] = {ParameterType = .CBV, Descriptor = {ShaderRegister = 0}}
    params[.Pass_Constants] = {ParameterType = ._32BIT_CONSTANTS, Constants = {ShaderRegister = 1, Num32BitValues = 4}}
    params[.Entries] = {ParameterType = .SRV, Descriptor = {ShaderRegister = 0}}
    params[.Bounds] = {ParameterType = .SRV, Descriptor = {ShaderRegister = 1}}
    params[.Commands] = {ParameterType = .UAV, Descriptor = {ShaderRegister = 0}}
    params[.Instances] = {ParameterType = .UAV, Descriptor = {ShaderRegister = 1}}
    params[.Visibility] = {ParameterType = .UAV, Descriptor = {ShaderRegister = 3}}
    params[.Meshlets] = {ParameterType = .SRV, Descriptor = {ShaderRegister = 4}}
    params[.Meshlet_Indices] = {ParameterType = .UAV, Descriptor = {ShaderRegister = 4}}
    params[.Meshlet_Visibility] = {ParameterType = .UAV, Descriptor = {ShaderRegister = 5}}
    for slot in ([]Cull_Root_Slot{.Hiz, .Hiz_Source, .Hiz_Target, .Mesh_Indices}) {
        params[slot] = {ParameterType = .DESCRIPTOR_TABLE, DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &ranges[slot]}}
    }
    rs_desc := d3d12.ROOT_SIGNATURE_DESC{NumParameters = len(params), pParameters = &params[Cull_Root_Slot(0)]}
    r.cull_root_signature = create_root_signature(&rs_desc, "Cull")

    // IndirectDraw's fields, in order.
    arguments := [4]d3d12.INDIRECT_ARGUMENT_DESC{
        {Type = .VERTEX_BUFFER_VIEW},
        {Type = .INDEX_BUFFER_VIEW},
        {Type = .CONSTANT},
        {Type = .DRAW_INDEXED},
    }
    arguments[0].VertexBuffer = {Slot = 0}
    arguments[2].Constant = {RootParameterIndex = u32(Root_Slot.Draw_Constants), Num32BitValuesToSet = 1}
    signature_desc := d3d12.COMMAND_SIGNATURE_DESC{
        ByteStride = size_of(IndirectDraw),
        NumArgumentDescs = len(arguments),
        pArgumentDescs = &arguments[0],
    }
    dx_check(r.device->CreateCommandSignature(
        &signature_desc, r.root_signature, d3d12.ICommandSignature_UUID, (^rawptr)(&r.draw_command_signature),
    ))
}

// The pipelines are released with the others (renderer_pipeline_slots), and
// the depth pyramid with the screen-sized targets.
renderer_release_culling :: proc() {
    r := &g_renderer
    r.cull_constant_buffer->Release()
    r.cull_entry_buffer->Release()
    r.cull_bounds_buffer->Release()
    r.indirect_upload_buffer->Release()
    r.indirect_buffer->Release()
    r.instance_buffer->Release()
    r.visibility_buffer->Release()
    r.cull_readback->Release()
    r.meshlet_index_buffer->Release()
    r.meshlet_flag_buffer->Release()
    if r.meshlet_buffer != nil do r.meshlet_buffer->Release()
    r.cull_root_signature->Release()
    r.draw_command_signature->Release()
}

// The cull and depth pyramid pipelines; rebuilt by shader hot-reload.
renderer_create_cull_pipeline :: proc() {
    r := &g_renderer
    entries := [3]cstring{"CSCull", "CSCullMeshlets", "CSBuildHiZ"}
    pipelines := [3]^^d3d12.IPipelineState{&r.cull_pipeline_state, &r.cull_meshlet_pipeline_state, &r.hiz_pipeline_state}
    for entry, i in entries {
        cs := renderer_compile_shader("shaders/cull.hlsl", entry, "cs")
        defer cs->Release()
        if renderer_skip_pipeline() do continue
        desc := d3d12.COMPUTE_PIPELINE_STATE_DESC{pRootSignature = r.cull_root_signature, CS = shader_bytecode(cs)}
        renderer_check_pipeline(r.device->CreateComputePipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(pipelines[i])))
    }
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
