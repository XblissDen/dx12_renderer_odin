package main

import "core:fmt"
import "core:math"
import "core:slice"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"

// Sun shadows cover the camera view out to this distance, then fade out.
// The distance is split into cascades: each gets its own shadow map, so nearby
// receivers get small texels while distant ones still have shadows.
SHADOW_CASCADE_COUNT :: 4
DEFAULT_SHADOW_DISTANCE :: f32(40)
MIN_SHADOW_DISTANCE :: f32(2)
MAX_SHADOW_DISTANCE :: f32(200)
SHADOW_FADE_FRACTION :: f32(0.15)
// Blend of logarithmic (1) and uniform (0) split spacing.
SHADOW_SPLIT_LAMBDA :: f32(0.8)

// Bias in shadow-map texels. The 5x5 tent filter reaches 2.5 texels away, so
// the slope term must cover that much depth change on tilted receivers.
// (Receivers also look up the map slightly off their surface:
// SHADOW_NORMAL_OFFSET_TEXELS in scene.hlsl.)
DEFAULT_SHADOW_BIAS_CONSTANT :: f32(1.0)
DEFAULT_SHADOW_BIAS_SLOPE :: f32(1.5)
MAX_SHADOW_BIAS :: f32(10)

// Spot and point light shadows share one depth atlas. Each shadow-casting
// light in view gets square tiles (a spot light one, a point light one per
// cube face), sized by how large its range looks on screen, and a tile is
// drawn again only when its light or the shadow casters around the light
// change. Tiles are powers of two, placed on a grid of 64-texel cells.
SHADOW_ATLAS_SIZE :: 4096
SHADOW_ATLAS_CELL :: 64
SHADOW_ATLAS_CELLS :: SHADOW_ATLAS_SIZE / SHADOW_ATLAS_CELL
SPOT_SHADOW_MIN_SIZE :: 128
SPOT_SHADOW_MAX_SIZE :: 1024
POINT_SHADOW_MIN_SIZE :: 64
POINT_SHADOW_MAX_SIZE :: 512
POINT_SHADOW_FACES :: 6
// Texels on each side of a point light's face beyond its 90 degrees, so the
// shadow filter near a face's edge stays inside the tile.
POINT_SHADOW_GUARD :: 3
MAX_SHADOW_LIGHTS :: 64
MAX_SHADOW_TILES :: MAX_SHADOW_LIGHTS * POINT_SHADOW_FACES
// Light views drawn into the atlas per frame at most (a spot light takes
// one, a point light six); changed lights beyond it wait for a later frame.
SHADOW_TILE_VIEWS :: 28
// Shadow views per frame: the sun's cascades, then the atlas views.
SHADOW_VIEW_COUNT :: SHADOW_CASCADE_COUNT + SHADOW_TILE_VIEWS

// A square of the atlas, in texels.
ShadowTile :: struct {
    x, y, size: u32,
}

// A shadow-casting light holding tiles in the atlas: one for a spot light,
// one per cube face for a point light.
ShadowLight :: struct {
    entity: int,
    point: bool,
    tiles: [POINT_SHADOW_FACES]ShadowTile,
    // Projected radius in pixels: bigger lights draw first and keep tiles.
    importance: f32,
    // What the tiles hold once drawn: the views they were drawn with, the
    // texel size per unit of distance, and a hash of the casters around the
    // light then.
    drawn: bool,
    drawn_frame: u64,
    view_projection: [POINT_SHADOW_FACES]alg.Matrix4f32,
    texel_scale: f32,
    caster_hash: u64,
    // This frame's first entry in the GPU tile buffer.
    gpu_index: int,
}

// A light view drawn into the atlas this frame.
ShadowTileView :: struct {
    tile: ShadowTile,
    view_projection: alg.Matrix4f32,
    entity: int,
    face: int, // -1 for a spot light.
}

// Per tile of a drawn light, read by the lit pass and the fog; laid out like
// scene.hlsl's. A point light's six follow each other in face order.
GpuShadowTile :: struct {
    // Already in the shader's row-vector form, like the frame constants'.
    view_projection: alg.Matrix4f32,
    // The tile in atlas UVs: offset, then size.
    rect: [4]f32,
    // Matrices align to 32 bytes; the shader's struct pads to match.
    _pad: [4]f32,
}
#assert(size_of(GpuShadowTile) == 96)
// Rasterizer bias for spot (and point) shadow casters, in D3D units. Their
// receivers' offset along the normal is SPOT_SHADOW_NORMAL_OFFSET_TEXELS in
// scene.hlsl.
SPOT_SHADOW_DEPTH_BIAS :: 0
SPOT_SHADOW_SLOPE_BIAS :: f32(2.0)

// Between shadow passes the maps are read by the lit pass and by the
// volumetric fog's compute pass.
SHADOW_READ_STATE :: d3d12.RESOURCE_STATES{.PIXEL_SHADER_RESOURCE, .NON_PIXEL_SHADER_RESOURCE}

// Each face's view of a cube map rendered from `position` (point shadows,
// reflection probe captures): look_at_lh with these targets and ups gives
// D3D's face order and orientation (+X, -X, +Y, -Y, +Z, -Z). A field of view
// wider than 90 degrees adds a margin around each face.
CUBE_FACE_DIRECTIONS := [6]alg.Vector3f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
CUBE_FACE_UPS := [6]alg.Vector3f32{{0, 1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {0, 1, 0}, {0, 1, 0}}

cube_face_view_projections :: proc(position: alg.Vector3f32, near, far: f32, fov: f32 = math.PI / 2) -> (faces: [6]alg.Matrix4f32) {
    projection := perspective_lh(fov, 1, near, far)
    for &face, i in faces do face = look_at_lh(position, position + CUBE_FACE_DIRECTIONS[i], CUBE_FACE_UPS[i]) * projection
    return
}

// A shadow-casting light that wants tiles this frame, with the views its
// tiles would be drawn with at `size`.
ShadowCandidate :: struct {
    entity: int,
    point: bool,
    importance: f32,
    // The tile (or face) size it asks for, before rounding to a power of two.
    ideal_size: f32,
    position: alg.Vector3f32,
    range: f32,
}

// The views a light's tiles are drawn with at `size`, and the world size of
// a texel per unit of distance along the view: a spot light's cone (its
// outer angle is the field of view), or a point light's six faces, each
// widened by POINT_SHADOW_GUARD texels on every side.
renderer_shadow_light_views :: proc(scene: ^Scene, entity: int, point: bool, size: u32) -> (views: [POINT_SHADOW_FACES]alg.Matrix4f32, texel_scale: f32) {
    world := scene_world_matrix(scene, entity)
    position := alg.Vector3f32{world[0, 3], world[1, 3], world[2, 3]}
    if point {
        light := scene.point_lights[entity]
        tan_half := f32(size) / f32(size - 2 * POINT_SHADOW_GUARD)
        near := max(light.range * 0.001, 0.02)
        views = cube_face_view_projections(position, near, light.range, 2 * math.atan(tan_half))
        return views, 2 * tan_half / f32(size)
    }
    light := scene.spot_lights[entity]
    direction := spot_light_direction(world)
    up := alg.Vector3f32{0, 1, 0}
    if math.abs(direction.y) > 0.99 do up = {0, 0, 1}
    near := max(light.range * 0.001, 0.02)
    views[0] = look_at_lh(position, position + direction, up) * perspective_lh(2 * light.outer_angle, 1, near, light.range)
    return views, 2 * math.tan(light.outer_angle) / f32(size)
}

// The power-of-two tile size for an ideal size, within the light kind's limits.
renderer_shadow_tile_size :: proc(ideal: f32, point: bool) -> u32 {
    low, high := u32(SPOT_SHADOW_MIN_SIZE), u32(SPOT_SHADOW_MAX_SIZE)
    if point do low, high = POINT_SHADOW_MIN_SIZE, POINT_SHADOW_MAX_SIZE
    size := low
    for size < high && f32(size) < ideal do size *= 2
    return size
}

// Takes the first free aligned square of `size` texels.
renderer_shadow_atlas_take :: proc(size: u32) -> (tile: ShadowTile, ok: bool) {
    r := &g_renderer
    cells := int(size / SHADOW_ATLAS_CELL)
    for y := 0; y < SHADOW_ATLAS_CELLS; y += cells {
        search: for x := 0; x < SHADOW_ATLAS_CELLS; x += cells {
            for cy in y..<y + cells do for cx in x..<x + cells do if r.shadow_atlas_cells[cy][cx] do continue search
            for cy in y..<y + cells do for cx in x..<x + cells do r.shadow_atlas_cells[cy][cx] = true
            return {u32(x * SHADOW_ATLAS_CELL), u32(y * SHADOW_ATLAS_CELL), size}, true
        }
    }
    return
}

renderer_shadow_atlas_give_back :: proc(tile: ShadowTile) {
    r := &g_renderer
    x, y, cells := int(tile.x / SHADOW_ATLAS_CELL), int(tile.y / SHADOW_ATLAS_CELL), int(tile.size / SHADOW_ATLAS_CELL)
    for cy in y..<y + cells do for cx in x..<x + cells do r.shadow_atlas_cells[cy][cx] = false
}

renderer_shadow_atlas_free :: proc(light: ^ShadowLight) {
    for tile in light.tiles[:POINT_SHADOW_FACES if light.point else 1] do renderer_shadow_atlas_give_back(tile)
}

// Tiles for a light at `size`, or the largest smaller size that fits; false
// (and nothing taken) if not even the smallest does.
renderer_shadow_atlas_place :: proc(light: ^ShadowLight, size: u32) -> bool {
    low := u32(POINT_SHADOW_MIN_SIZE if light.point else SPOT_SHADOW_MIN_SIZE)
    count := POINT_SHADOW_FACES if light.point else 1
    for try := size; try >= low; try /= 2 {
        placed := 0
        for placed < count {
            light.tiles[placed] = renderer_shadow_atlas_take(try) or_break
            placed += 1
        }
        if placed == count do return true
        for tile in light.tiles[:placed] do renderer_shadow_atlas_give_back(tile)
    }
    return false
}

// A hash of the shadow casters whose bounds reach within `radius` of
// `center`: their placement, mesh, pipeline variant and cutout material. A
// light's tiles are drawn again when it changes.
renderer_shadow_caster_hash :: proc(data: ^FrameDraws, center: alg.Vector3f32, radius: f32) -> u64 {
    Key :: struct {
        center: [3]f32,
        half_axes: [3][3]f32,
        mesh: MeshHandle,
        first_index: u32,
        variant: Draw_Variant,
        alpha_texture: TextureHandle,
        alpha_cutoff: f32,
    }
    h := u64(0xcbf29ce484222325)
    for &draw in data.draws[:data.draw_count] {
        if !draw.casts_shadow do continue
        if draw.bounds.valid {
            axes := draw.bounds.half_axes
            extent := alg.length(axes[0]) + alg.length(axes[1]) + alg.length(axes[2])
            if alg.length(draw.bounds.center - center) > radius + extent do continue
        }
        // Field by field into a zeroed key, so padding (in the key, or in
        // the draw's own structs) never reaches the hash.
        key: Key
        key.center, key.half_axes = draw.bounds.center, draw.bounds.half_axes
        key.mesh, key.first_index = draw.mesh, draw.first_index
        key.variant, key.alpha_texture, key.alpha_cutoff = draw.variant, draw.alpha_texture, draw.alpha_cutoff
        for byte in transmute([size_of(Key)]u8)key {
            h = (h ~ u64(byte)) * 0x100000001b3
        }
    }
    return h
}

// Gives the shadow-casting lights in view their atlas tiles, picks the light
// views to draw this frame (changed lights, most important first, up to
// SHADOW_TILE_VIEWS), and writes the GPU tiles of every drawn light. Lights
// keep their tiles while their size stays about right, so unchanged ones
// are never drawn again. When a light does not fit but outranks one holding
// tiles, every tile is placed again in order of importance. Without the atlas
// (renderer_shadow_atlas_used), every light gives its tiles back.
renderer_update_shadow_atlas :: proc(scene: ^Scene, data: ^FrameDraws, camera_position: alg.Vector3f32, camera_frustum: Frustum) {
    r := &g_renderer

    // Wanted: lights whose range reaches the view, by projected radius. None
    // without the atlas, so the lights holding tiles give them back below.
    candidates := make([dynamic]ShadowCandidate, context.temp_allocator)
    pixels_per_radian := f32(r.height) * 0.5 / math.tan(CAMERA_FOV_Y * 0.5)
    entity_count := scene.entity_count if renderer_shadow_atlas_used() else 0
    for i in 0..<entity_count {
        if !scene.alive[i] || !scene.has_transform[i] do continue
        point := scene.has_point_light[i] && scene.point_lights[i].cast_shadows
        spot := scene.has_spot_light[i] && scene.spot_lights[i].cast_shadows
        if !point && !spot do continue
        position := scene_world_position(scene, i)
        range := scene.point_lights[i].range if point else scene.spot_lights[i].range
        bounds := WorldBounds{center = position, half_axes = {{range, 0, 0}, {0, range, 0}, {0, 0, range}}, valid = true}
        if r.frustum_culling_enabled && !frustum_intersects_bounds(camera_frustum, bounds) do continue
        distance := alg.length(position - camera_position)
        importance := f32(1e6) if distance <= range else range / math.sqrt(distance * distance - range * range) * pixels_per_radian
        // A face spans a quarter of the turn a spot light's cone typically
        // does. Within the kind's sizes, so a light past the largest keeps it.
        ideal := importance * (0.5 if point else 1)
        ideal = clamp(ideal, f32(POINT_SHADOW_MIN_SIZE if point else SPOT_SHADOW_MIN_SIZE), f32(POINT_SHADOW_MAX_SIZE if point else SPOT_SHADOW_MAX_SIZE))
        append(&candidates, ShadowCandidate{i, point, importance, ideal, position, range})
    }
    slice.sort_by(candidates[:], proc(a, b: ShadowCandidate) -> bool {return a.importance > b.importance})
    if len(candidates) > MAX_SHADOW_LIGHTS do resize(&candidates, MAX_SHADOW_LIGHTS)

    // Lights no longer wanted, and those whose size is now far off, give
    // their tiles back.
    find :: proc(candidates: []ShadowCandidate, light: ShadowLight) -> int {
        for candidate, i in candidates do if candidate.entity == light.entity && candidate.point == light.point do return i
        return -1
    }
    for i := 0; i < r.shadow_light_count; {
        light := &r.shadow_lights[i]
        c := find(candidates[:], light^)
        size := f32(light.tiles[0].size)
        if c < 0 || candidates[c].ideal_size > size * 1.5 || candidates[c].ideal_size < size * 0.35 {
            renderer_shadow_atlas_free(light)
            r.shadow_lights[i] = r.shadow_lights[r.shadow_light_count - 1]
            r.shadow_light_count -= 1
            continue
        }
        light.importance = candidates[c].importance
        i += 1
    }

    // New ones, most important first.
    rebuild := false
    for candidate in candidates {
        if renderer_shadow_light_of(candidate.entity, candidate.point) != nil do continue
        light := ShadowLight{entity = candidate.entity, point = candidate.point, importance = candidate.importance}
        if renderer_shadow_atlas_place(&light, renderer_shadow_tile_size(candidate.ideal_size, candidate.point)) {
            r.shadow_lights[r.shadow_light_count] = light
            r.shadow_light_count += 1
            continue
        }
        for holder in r.shadow_lights[:r.shadow_light_count] do rebuild ||= holder.importance < candidate.importance
        if rebuild do break
    }
    if rebuild {
        r.shadow_atlas_cells = {}
        r.shadow_light_count = 0
        for candidate in candidates {
            light := ShadowLight{entity = candidate.entity, point = candidate.point, importance = candidate.importance}
            if !renderer_shadow_atlas_place(&light, renderer_shadow_tile_size(candidate.ideal_size, candidate.point)) do continue
            r.shadow_lights[r.shadow_light_count] = light
            r.shadow_light_count += 1
        }
    }
    slice.sort_by(r.shadow_lights[:r.shadow_light_count], proc(a, b: ShadowLight) -> bool {return a.importance > b.importance})

    // Which lights changed since their tiles were drawn.
    Change :: struct {
        light: ^ShadowLight,
        views: [POINT_SHADOW_FACES]alg.Matrix4f32,
        texel_scale: f32,
        caster_hash: u64,
        priority: f32,
    }
    changes := make([dynamic]Change, context.temp_allocator)
    for &light in r.shadow_lights[:r.shadow_light_count] {
        views, texel_scale := renderer_shadow_light_views(scene, light.entity, light.point, light.tiles[0].size)
        range := scene.point_lights[light.entity].range if light.point else scene.spot_lights[light.entity].range
        caster_hash := renderer_shadow_caster_hash(data, scene_world_position(scene, light.entity), range)
        if light.drawn && light.view_projection == views && light.caster_hash == caster_hash do continue
        // Never drawn first; then bigger lights, and those waiting longer, so
        // every changed light gets its turn even when more change than fit.
        priority := max(f32) if !light.drawn else light.importance * f32(r.frame_counter - light.drawn_frame)
        append(&changes, Change{&light, views, texel_scale, caster_hash, priority})
    }
    slice.sort_by(changes[:], proc(a, b: Change) -> bool {return a.priority > b.priority})

    // Draw what fits in this frame's views.
    r.shadow_tile_view_count = 0
    for change in changes {
        light := change.light
        faces := POINT_SHADOW_FACES if light.point else 1
        if r.shadow_tile_view_count + faces > SHADOW_TILE_VIEWS do continue
        for face in 0..<faces {
            r.shadow_tile_views[r.shadow_tile_view_count] = {
                light.tiles[face], change.views[face], light.entity, face if light.point else -1,
            }
            r.shadow_tile_view_count += 1
        }
        light.drawn = true
        light.drawn_frame = r.frame_counter
        light.view_projection = change.views
        light.texel_scale = change.texel_scale
        light.caster_hash = change.caster_hash
    }

    // Every drawn light's tiles, for the shaders.
    gpu := r.shadow_tile_mapped[int(r.frame_slot) * MAX_SHADOW_TILES:]
    gpu_count := 0
    for &light in r.shadow_lights[:r.shadow_light_count] {
        light.gpu_index = -1
        if !light.drawn do continue
        light.gpu_index = gpu_count
        for face in 0..<(POINT_SHADOW_FACES if light.point else 1) {
            tile := light.tiles[face]
            gpu[gpu_count] = GpuShadowTile{
                view_projection = light.view_projection[face],
                rect = {f32(tile.x), f32(tile.y), f32(tile.size), f32(tile.size)} / SHADOW_ATLAS_SIZE,
            }
            gpu_count += 1
        }
    }
}
// Whether anything reads the shadow atlas this frame: the lit pass, unless
// rays replace it (renderer_ray_light_shadows_active), and the fog.
renderer_shadow_atlas_used :: proc() -> bool {
    return !renderer_ray_light_shadows_active() || renderer_fog_active()
}

// The atlas tiles of an entity's light, if it holds any.
renderer_shadow_light_of :: proc(entity: int, point: bool) -> ^ShadowLight {
    r := &g_renderer
    for &light in r.shadow_lights[:r.shadow_light_count] do if light.entity == entity && light.point == point do return &light
    return nil
}

ShadowCascade :: struct {
    view_projection: alg.Matrix4f32,
    // View depth (along the camera's forward axis) where this cascade ends.
    split_depth: f32,
    // World size of one texel, and the depth change across one texel on a
    // receiver facing the sun, in shadow-map depth units.
    texel_world: f32,
    texel_depth: f32,
}

ShadowFit :: struct {
    cascades: [SHADOW_CASCADE_COUNT]ShadowCascade,
    fade_start, fade_end: f32,
}

// Splits the view out to the shadow distance into cascades and fits each one.
renderer_fit_shadow :: proc(
    sun_direction: alg.Vector3f32,
    camera_position, camera_forward: alg.Vector3f32,
    aspect, far_clip, distance: f32,
    casters: []WorldBounds,
) -> (fit: ShadowFit) {
    shadow_distance := clamp(distance, CAMERA_NEAR_CLIP * 2, far_clip)
    near := CAMERA_NEAR_CLIP

    slice_near := near
    for i in 0..<SHADOW_CASCADE_COUNT {
        // Practical split scheme: mostly logarithmic, which matches how
        // perspective shrinks texels with distance.
        t := f32(i + 1) / SHADOW_CASCADE_COUNT
        logarithmic := near * math.pow(shadow_distance / near, t)
        uniform := near + (shadow_distance - near) * t
        slice_far := math.lerp(uniform, logarithmic, SHADOW_SPLIT_LAMBDA)
        if i == SHADOW_CASCADE_COUNT - 1 do slice_far = shadow_distance

        fit.cascades[i] = renderer_fit_shadow_cascade(
            sun_direction, camera_position, camera_forward,
            aspect, slice_near, slice_far, casters,
        )
        slice_near = slice_far
    }

    fit.fade_start = shadow_distance * (1 - SHADOW_FADE_FRACTION)
    fit.fade_end = shadow_distance
    return
}

// Fits the sun's orthographic volume around one slice of the camera view.
// The volume is a bounding sphere of the slice: its size does not change as
// the camera turns, and its center snaps to whole shadow-map texels, so shadow
// edges stay still while the camera moves.
renderer_fit_shadow_cascade :: proc(
    sun_direction: alg.Vector3f32,
    camera_position, camera_forward: alg.Vector3f32,
    aspect, slice_near, slice_far: f32,
    casters: []WorldBounds,
) -> ShadowCascade {
    // Slice corners sit sqrt(k2) * depth from the view axis. The center depth
    // minimizing the enclosing sphere balances near and far corners.
    tan_half_fov := math.tan(CAMERA_FOV_Y * 0.5)
    k2 := tan_half_fov * tan_half_fov * (1 + aspect * aspect)
    center_depth := min((slice_near + slice_far) * 0.5 * (1 + k2), slice_far)

    far_corner := math.sqrt(
        (slice_far - center_depth) * (slice_far - center_depth) +
        slice_far * slice_far * k2,
    )
    near_corner := math.sqrt(
        (center_depth - slice_near) * (center_depth - slice_near) +
        slice_near * slice_near * k2,
    )
    // Quantize so floating-point noise never changes the texel size.
    radius := math.ceil(max(far_corner, near_corner) * 64) / 64
    center := camera_position + camera_forward * center_depth

    // Same basis look_at_lh builds for an eye at the origin facing the sun's rays.
    sun_up := alg.Vector3f32{0, 1, 0}
    if math.abs(sun_direction.y) > 0.99 {
        sun_up = {0, 0, 1}
    }
    light_z := alg.normalize(sun_direction)
    light_x := alg.normalize(alg.cross(sun_up, light_z))
    light_y := alg.cross(light_z, light_x)

    texel := 2 * radius / SHADOW_MAP_SIZE
    center_x := math.floor(alg.dot(light_x, center) / texel) * texel
    center_y := math.floor(alg.dot(light_y, center) / texel) * texel
    center_z := alg.dot(light_z, center)

    // Receivers end at the sphere. Casters between it and the sun can still
    // shadow it, so pull the near plane back to include them.
    near_z := center_z - radius
    far_z := center_z + radius
    for bounds in casters {
        if !bounds.valid {
            continue
        }

        extent: [3]f32
        axes := [3]alg.Vector3f32{light_x, light_y, light_z}
        for axis, i in axes {
            for half_axis in bounds.half_axes {
                extent[i] += math.abs(alg.dot(axis, half_axis))
            }
        }

        offset_x := alg.dot(light_x, bounds.center) - center_x
        offset_y := alg.dot(light_y, bounds.center) - center_y
        if math.abs(offset_x) > radius + extent[0] ||
           math.abs(offset_y) > radius + extent[1] {
            continue
        }
        near_z = min(near_z, alg.dot(light_z, bounds.center) - extent[2])
    }
    near_z -= texel

    view := look_at_lh({0, 0, 0}, light_z, sun_up)
    projection := orthographic_lh(
        center_x - radius, center_x + radius,
        center_y - radius, center_y + radius,
        near_z, far_z,
    )

    return ShadowCascade{
        view_projection = view * projection,
        split_depth = slice_far,
        texel_world = texel,
        texel_depth = texel / (far_z - near_z),
    }
}

renderer_create_shadow_map :: proc() {
    r := &g_renderer
    r.shadow_map, r.shadow_dsv_heap = renderer_create_shadow_array(
        SHADOW_MAP_SIZE, SHADOW_CASCADE_COUNT, r.shadow_srv_index,
    )
    r.shadow_atlas, r.shadow_atlas_dsv_heap = renderer_create_shadow_array(SHADOW_ATLAS_SIZE, 1, r.shadow_atlas_srv_index)
    mapped: rawptr
    r.shadow_tile_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_SHADOW_TILES * size_of(GpuShadowTile)))
    r.shadow_tile_mapped = ([^]GpuShadowTile)(mapped)
}

// This frame slot's GPU tiles of the drawn lights.
renderer_shadow_tile_address :: proc() -> u64 {
    r := &g_renderer
    return r.shadow_tile_buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * MAX_SHADOW_TILES * size_of(GpuShadowTile)
}

// A square depth texture array for shadows, left in SHADOW_READ_STATE
// state: one depth view per slice, and a shader view of every slice at
// `srv_index`.
renderer_create_shadow_array :: proc(size, slices, srv_index: u32) -> (
    texture: ^d3d12.IResource,
    dsv_heap: ^d3d12.IDescriptorHeap,
) {
    r := &g_renderer

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    shadow_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(size),
        Height = size,
        DepthOrArraySize = u16(slices),
        MipLevels = 1,
        Format = .R32_TYPELESS,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_DEPTH_STENCIL},
    }

    clear_value := d3d12.CLEAR_VALUE{Format = .D32_FLOAT}
    clear_value.DepthStencil = {Depth = 1.0, Stencil = 0}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &shadow_desc,
        SHADOW_READ_STATE,
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&texture),
    ))

    dsv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = slices,
        Type = .DSV,
    }
    dx_check(r.device->CreateDescriptorHeap(
        &dsv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&dsv_heap),
    ))

    for slice in 0..<slices {
        shadow_dsv := d3d12.DEPTH_STENCIL_VIEW_DESC{
            Format = .D32_FLOAT,
            ViewDimension = .TEXTURE2DARRAY,
        }
        shadow_dsv.Texture2DArray = {
            FirstArraySlice = slice,
            ArraySize = 1,
        }
        r.device->CreateDepthStencilView(texture, &shadow_dsv, descriptor_handle(dsv_heap, .DSV, slice))
    }

    shadow_srv := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R32_FLOAT,
        ViewDimension = .TEXTURE2DARRAY,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    shadow_srv.Texture2DArray = {MipLevels = 1, ArraySize = slices}
    r.device->CreateShaderResourceView(texture, &shadow_srv, renderer_srv_cpu(srv_index))
    return
}
renderer_render_shadow_pass :: proc(
    draws: []Draw,
    // Draw calls per shadow view: cascades, then this frame's atlas views.
    view_batches: [SHADOW_VIEW_COUNT][]DrawBatch,
) {
    r := &g_renderer

    renderer_begin_gpu_pass(.Shadow)
    shadow_barrier := d3d12.RESOURCE_BARRIER {Type = .TRANSITION}
    shadow_barrier.Transition = {
        pResource = r.shadow_map,
        StateBefore = SHADOW_READ_STATE,
        StateAfter = {.DEPTH_WRITE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &shadow_barrier)

    shadow_viewport := d3d12.VIEWPORT{
        Width = SHADOW_MAP_SIZE,
        Height = SHADOW_MAP_SIZE,
        MinDepth = 0,
        MaxDepth = 1,
    }

    shadow_scissor := d3d12.RECT{
        right = SHADOW_MAP_SIZE,
        bottom = SHADOW_MAP_SIZE,
    }

    r.command_list->RSSetViewports(1, &shadow_viewport)
    r.command_list->RSSetScissorRects(1, &shadow_scissor)
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    // Cutouts read their albedo alpha from the bindless textures.
    shadow_heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(shadow_heaps))
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_bind_cbv(.Frame_Constants, renderer_frame_cb_address())

    for cascade in 0..<SHADOW_CASCADE_COUNT {
        renderer_begin_event(fmt.tprintf("Sun cascade %d", cascade))
        defer renderer_end_event()
        dsv_handle := descriptor_handle(r.shadow_dsv_heap, .DSV, u32(cascade))
        r.command_list->OMSetRenderTargets(0, nil, false, &dsv_handle)
        r.command_list->ClearDepthStencilView(
            dsv_handle, {.DEPTH}, 1.0, 0, 0, nil,
        )
        // VSShadow reads this view's matrix from the frame constants.
        r.command_list->SetGraphicsRoot32BitConstant(u32(Root_Slot.Shadow_View), u32(cascade), 0)

        renderer_draw_batches(draws, view_batches[cascade], r.shadow_pipeline_states)
    }

    shadow_barrier.Transition.StateBefore = {.DEPTH_WRITE}
    shadow_barrier.Transition.StateAfter = SHADOW_READ_STATE
    r.command_list->ResourceBarrier(1, &shadow_barrier)

    // This frame's atlas views, each into its tile, drawn with the bias
    // pipelines. VSShadow reads view SHADOW_CASCADE_COUNT + i.
    if r.shadow_tile_view_count > 0 {
        shadow_barrier.Transition.pResource = r.shadow_atlas
        shadow_barrier.Transition.StateBefore = SHADOW_READ_STATE
        shadow_barrier.Transition.StateAfter = {.DEPTH_WRITE}
        r.command_list->ResourceBarrier(1, &shadow_barrier)
        dsv_handle := descriptor_handle(r.shadow_atlas_dsv_heap, .DSV, 0)
        r.command_list->OMSetRenderTargets(0, nil, false, &dsv_handle)
        for view, i in r.shadow_tile_views[:r.shadow_tile_view_count] {
            // One event per light, around a point light's six faces.
            if view.face <= 0 {
                kind := "Spot light" if view.face < 0 else "Point light"
                renderer_begin_event(fmt.tprintf("%s %d (%d px)", kind, view.entity, view.tile.size))
            }
            defer if view.face < 0 || view.face == POINT_SHADOW_FACES - 1 do renderer_end_event()

            tile := view.tile
            viewport := d3d12.VIEWPORT{TopLeftX = f32(tile.x), TopLeftY = f32(tile.y), Width = f32(tile.size), Height = f32(tile.size), MaxDepth = 1}
            scissor := d3d12.RECT{left = i32(tile.x), top = i32(tile.y), right = i32(tile.x + tile.size), bottom = i32(tile.y + tile.size)}
            r.command_list->RSSetViewports(1, &viewport)
            r.command_list->RSSetScissorRects(1, &scissor)
            r.command_list->ClearDepthStencilView(dsv_handle, {.DEPTH}, 1.0, 0, 1, &scissor)
            shadow_view := SHADOW_CASCADE_COUNT + i
            r.command_list->SetGraphicsRoot32BitConstant(u32(Root_Slot.Shadow_View), u32(shadow_view), 0)
            renderer_draw_batches(draws, view_batches[shadow_view], r.light_shadow_pipeline_states)
        }
        shadow_barrier.Transition.StateBefore = {.DEPTH_WRITE}
        shadow_barrier.Transition.StateAfter = SHADOW_READ_STATE
        r.command_list->ResourceBarrier(1, &shadow_barrier)
    }
    renderer_end_gpu_pass(.Shadow)
}
