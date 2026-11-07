package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:math/linalg"
import "core:math"
import "core:slice"
import "core:sync"
import "core:thread"

MeshData :: struct {
    vertices: []Vertex,
    indices: []u32,
    // Index ranges drawn with one material slot each; together they cover
    // all indices. An OBJ has a single submesh.
    submeshes: []Submesh,
    // Every large submesh's meshlets (mesh_build_meshlets), in submesh order,
    // each submesh's full version and then its levels of detail.
    meshlets: []Meshlet,
    // Every large submesh's levels of detail (mesh_build_lods), in submesh
    // order; their indices follow the submeshes' in `indices`.
    lods: []MeshLod,
}

// Submeshes with fewer triangles are culled whole: splitting them would cost
// more cull work than it saves.
MESHLET_MIN_SUBMESH_TRIANGLES :: 512
MESHLET_MAX_VERTICES :: 64
MESHLET_MAX_TRIANGLES :: 124

// A small patch of a submesh's triangles, culled on its own
// (renderer_frame_data.odin, cull.hlsl). Its triangles are contiguous in the
// mesh's index buffer.
Meshlet :: struct {
    first_index, index_count: u32,
    // Mesh-space bounding sphere.
    center: [3]f32,
    radius: f32,
    // Normal cone: every triangle's face normal is within the cone's angle of
    // `cone_axis`, and `cone_cutoff` is the angle's sine. A viewer then sees
    // only back faces when dot(center - eye, axis) >= cutoff * |center - eye|
    // + radius. 1 (never) for meshlets whose normals spread too far.
    cone_axis: [3]f32,
    cone_cutoff: f32,
}

MeshBounds :: struct {
    minimum, maximum: linalg.Vector3f32,
    valid: bool,
}

Submesh :: struct {
    first_index, index_count: u32,
    material_slot: u32,
    // Local-space bounds of just this range, for per-draw culling.
    bounds: MeshBounds,
    // Its meshlets in MeshData.meshlets; none for small submeshes.
    first_meshlet, meshlet_count: u32,
    // Its levels of detail in MeshData.lods, coarser and coarser; none for
    // small submeshes.
    first_lod, lod_count: u32,
}

// One submesh covering the whole mesh, for single-material sources.
mesh_single_submesh :: proc(mesh: ^MeshData, allocator := context.allocator) {
    mesh.submeshes = make([]Submesh, 1, allocator)
    mesh.submeshes[0] = {index_count = u32(len(mesh.indices))}
    mesh_compute_submesh_bounds(mesh^)
    mesh_build_lods(mesh, allocator)
    mesh_build_meshlets(mesh, allocator)
}

// Splits each large submesh into meshlets and reorders its index range so
// each meshlet's triangles are contiguous; the draws over the whole range are
// unchanged. A meshlet grows from a seed triangle by repeatedly taking the
// neighbouring triangle (sharing a vertex) that adds the fewest new vertices,
// nearest the meshlet's centre on ties, until either limit is reached. That
// keeps meshlets compact, so their bounds and normal cones are tight.
mesh_build_meshlets :: proc(mesh: ^MeshData, allocator := context.allocator) {
    meshlets := make([dynamic]Meshlet, allocator)
    vertex_count := len(mesh.vertices)
    // Per vertex: the triangles using it (offsets into one list), and the
    // meshlet it last joined.
    scratch := Meshlet_Scratch{
        tri_offsets = make([]u32, vertex_count + 1, context.temp_allocator),
        vertex_mark = make([]i32, vertex_count, context.temp_allocator),
        fill = make([]u32, vertex_count, context.temp_allocator),
    }
    for &submesh in mesh.submeshes {
        submesh.first_meshlet, submesh.meshlet_count = mesh_build_range_meshlets(mesh, submesh.first_index, submesh.index_count, &meshlets, scratch)
        for &lod in mesh.lods[submesh.first_lod:][:submesh.lod_count] {
            lod.first_meshlet, lod.meshlet_count = mesh_build_range_meshlets(mesh, lod.first_index, lod.index_count, &meshlets, scratch)
        }
    }
    mesh.meshlets = meshlets[:]
}

@(private="file")
Meshlet_Scratch :: struct {
    tri_offsets: []u32,
    vertex_mark: []i32,
    fill: []u32,
}

// One index range's meshlets (none below MESHLET_MIN_SUBMESH_TRIANGLES),
// appended to `meshlets`, with the range reordered to match.
@(private="file")
mesh_build_range_meshlets :: proc(
    mesh: ^MeshData, first_index, index_count: u32, meshlets: ^[dynamic]Meshlet, scratch: Meshlet_Scratch,
) -> (first_meshlet, meshlet_count: u32) {
    vertex_count := len(mesh.vertices)
    tri_offsets, vertex_mark, fill := scratch.tri_offsets, scratch.vertex_mark, scratch.fill
    first_meshlet = u32(len(meshlets))
    {
        triangle_count := int(index_count / 3)
        if triangle_count < MESHLET_MIN_SUBMESH_TRIANGLES do return
        range := mesh.indices[first_index:][:triangle_count * 3]

        slice.zero(tri_offsets)
        for index in range do tri_offsets[index + 1] += 1
        for v in 0..<vertex_count do tri_offsets[v + 1] += tri_offsets[v]
        slice.zero(fill)
        tri_list := make([]u32, len(range), context.temp_allocator)
        for index, i in range {
            tri_list[tri_offsets[index] + fill[index]] = u32(i / 3)
            fill[index] += 1
        }
        for &mark in vertex_mark do mark = -1

        used := make([]bool, triangle_count, context.temp_allocator)
        reordered := make([dynamic]u32, 0, len(range), context.temp_allocator)
        candidates := make([dynamic]u32, context.temp_allocator)
        next_seed := 0
        for {
            for next_seed < triangle_count && used[next_seed] do next_seed += 1
            if next_seed == triangle_count do break
            meshlet_id := i32(len(meshlets))
            first := len(reordered)
            vertices_in := 0
            centroid_sum: [3]f32
            clear(&candidates)
            append(&candidates, u32(next_seed))
            for len(reordered) - first < MESHLET_MAX_TRIANGLES * 3 {
                // Out of neighbours (a separate piece of the surface): go on
                // with the next unused triangle in index order, usually close
                // by, rather than leave the meshlet small.
                if len(candidates) == 0 {
                    for next_seed < triangle_count && used[next_seed] do next_seed += 1
                    if next_seed == triangle_count do break
                    append(&candidates, u32(next_seed))
                }
                // The candidate adding the fewest vertices, then nearest.
                best, best_new, best_distance := -1, 4, max(f32)
                centroid := centroid_sum / f32(max(vertices_in, 1))
                for c := 0; c < len(candidates); {
                    t := candidates[c]
                    if used[t] {
                        unordered_remove(&candidates, c)
                        continue
                    }
                    new_vertices := 0
                    center: [3]f32
                    for k in 0..<3 {
                        v := range[t * 3 + u32(k)]
                        if vertex_mark[v] != meshlet_id do new_vertices += 1
                        center += mesh.vertices[v].position / 3
                    }
                    d := center - centroid
                    distance := d.x * d.x + d.y * d.y + d.z * d.z
                    if new_vertices < best_new || (new_vertices == best_new && distance < best_distance) {
                        best, best_new, best_distance = c, new_vertices, distance
                    }
                    c += 1
                }
                // Every candidate was already taken: refill (above) and look again.
                if best < 0 && len(candidates) == 0 do continue
                if best < 0 || vertices_in + best_new > MESHLET_MAX_VERTICES do break
                t := candidates[best]
                unordered_remove(&candidates, best)
                used[t] = true
                for k in 0..<3 {
                    v := range[t * 3 + u32(k)]
                    append(&reordered, v)
                    if vertex_mark[v] == meshlet_id do continue
                    vertex_mark[v] = meshlet_id
                    vertices_in += 1
                    centroid_sum += mesh.vertices[v].position
                    for neighbour in tri_list[tri_offsets[v]:tri_offsets[v + 1]] {
                        if !used[neighbour] do append(&candidates, neighbour)
                    }
                }
            }
            meshlet := mesh_meshlet_bounds(mesh.vertices, reordered[first:])
            meshlet.first_index = first_index + u32(first)
            meshlet.index_count = u32(len(reordered) - first)
            append(meshlets, meshlet)
            meshlet_count += 1
        }
        copy(range, reordered[:])
    }
    return
}

// A meshlet's bounding sphere (around its box's centre) and normal cone.
// Face normals take their side from the vertex normals, so they point out of
// the surface whatever the winding.
mesh_meshlet_bounds :: proc(vertices: []Vertex, indices: []u32) -> (meshlet: Meshlet) {
    low, high := linalg.Vector3f32(max(f32)), linalg.Vector3f32(-max(f32))
    for index in indices {
        p := linalg.Vector3f32(vertices[index].position)
        low, high = linalg.min(low, p), linalg.max(high, p)
    }
    center := (low + high) * 0.5
    for index in indices {
        meshlet.radius = max(meshlet.radius, linalg.length(linalg.Vector3f32(vertices[index].position) - center))
    }
    meshlet.center = center

    normals := make([]linalg.Vector3f32, len(indices) / 3, context.temp_allocator)
    axis: linalg.Vector3f32
    for t in 0..<len(normals) {
        a, b, c := vertices[indices[t * 3]], vertices[indices[t * 3 + 1]], vertices[indices[t * 3 + 2]]
        n := linalg.cross(linalg.Vector3f32(b.position - a.position), linalg.Vector3f32(c.position - a.position))
        if linalg.length(n) < 1e-12 do continue
        n = linalg.normalize(n)
        if linalg.dot(n, linalg.Vector3f32(a.normal + b.normal + c.normal)) < 0 do n = -n
        normals[t] = n
        axis += n
    }
    meshlet.cone_cutoff = 1
    if linalg.length(axis) < 1e-6 do return
    axis = linalg.normalize(axis)
    min_dot := f32(1)
    for n in normals do if n != {} do min_dot = min(min_dot, linalg.dot(n, axis))
    // Within about 84 degrees of the axis, or the cone never culls anything.
    if min_dot <= 0.1 do return
    meshlet.cone_axis = axis
    meshlet.cone_cutoff = math.sqrt(1 - min_dot * min_dot)
    return
}

mesh_compute_submesh_bounds :: proc(mesh: MeshData) {
    for &submesh in mesh.submeshes {
        submesh.bounds = {}
        for i in submesh.first_index..<submesh.first_index + submesh.index_count {
            p := linalg.Vector3f32(mesh.vertices[mesh.indices[i]].position)
            if !submesh.bounds.valid {
                submesh.bounds = {minimum = p, maximum = p, valid = true}
                continue
            }
            submesh.bounds.minimum = linalg.min(submesh.bounds.minimum, p)
            submesh.bounds.maximum = linalg.max(submesh.bounds.maximum, p)
        }
    }
}

mesh_destroy :: proc(mesh: MeshData) {
    delete(mesh.vertices)
    delete(mesh.indices)
    delete(mesh.submeshes)
    delete(mesh.meshlets)
    delete(mesh.lods)
}

mesh_compute_bounds :: proc(mesh: MeshData) -> MeshBounds{
    if len(mesh.vertices) == 0 {
        return {}
    }

    first := linalg.Vector3f32(mesh.vertices[0].position)
    bounds := MeshBounds{
        minimum = first,
        maximum = first,
        valid = true,
    }

    for vertex in mesh.vertices[1:] {
        for axis in 0..<3{
            bounds.minimum[axis] = min(bounds.minimum[axis], vertex.position[axis])
            bounds.maximum[axis] = max(bounds.maximum[axis], vertex.position[axis])
        }
    }

    return bounds
}

mesh_load_obj :: proc(
    path: string, 
    allocator := context.allocator,
    flip_v := false,
) -> (mesh: MeshData, ok: bool){
    data, read_ok := os.read_entire_file(path, context.temp_allocator)
    if read_ok != os.General_Error.None{
        fmt.eprintln("Cannot open OBJ", path)
        return {}, false
    }

    positions := make([dynamic][3]f32, context.temp_allocator)
    normals := make([dynamic][3]f32, context.temp_allocator)
    texcoords := make([dynamic][2]f32, context.temp_allocator)

    out_vertices := make([dynamic]Vertex, allocator)
    out_indices := make([dynamic]u32, allocator)
    defer if !ok {
        delete(out_vertices)
        delete(out_indices)
    }

    Vertex_Key :: struct { pos_idx, tex_idx, norm_idx: int}
    vertex_cache := make(map[Vertex_Key]u32, context.temp_allocator)
    // Some face vertex came without a normal ("f 1/1 2/2 3/3").
    missing_normals := false

    text := string(data)
    for line in strings.split_lines_iterator(&text){
        trimmed := strings.trim_space(line)
        if len(trimmed) == 0 || trimmed[0] == '#'{
            continue
        }

        fields := strings.fields(trimmed, context.temp_allocator)
        if len(fields) == 0 do continue

        switch fields[0]{
            case "v":
                if len(fields) < 4 do return {}, false
                x, x_ok := strconv.parse_f32(fields[1])
                y, y_ok := strconv.parse_f32(fields[2])
                z, z_ok := strconv.parse_f32(fields[3])
                if !x_ok || !y_ok || !z_ok || math.is_nan(x) || math.is_nan(y) || math.is_nan(z) || math.is_inf(x) || math.is_inf(y) || math.is_inf(z) do return {}, false
                // OBJ is right-handed; negating Z converts it to this renderer's
                // left-handed space (faces are reversed below, as in gltf.odin).
                append(&positions, [3]f32{x, y, -z})

            case "vn":
                if len(fields) < 4 do return {}, false
                x, x_ok := strconv.parse_f32(fields[1])
                y, y_ok := strconv.parse_f32(fields[2])
                z, z_ok := strconv.parse_f32(fields[3])
                if !x_ok || !y_ok || !z_ok || math.is_nan(x) || math.is_nan(y) || math.is_nan(z) || math.is_inf(x) || math.is_inf(y) || math.is_inf(z) do return {}, false
                append(&normals, [3]f32{x, y, -z})

            case "vt":
                if len(fields) < 3 do return {}, false
                u, u_ok := strconv.parse_f32(fields[1])
                v, v_ok := strconv.parse_f32(fields[2])
                if !u_ok || !v_ok || math.is_nan(u) || math.is_nan(v) || math.is_inf(u) || math.is_inf(v) do return {}, false
                if flip_v {
                    v = 1 - v
                }
                append(&texcoords, [2]f32{u, v})
            case "f":
                face_indices := make([dynamic]u32, context.temp_allocator)

                for i in 1..<len(fields) {
                    if fields[i][0] == '#' do break
                    key, key_ok := parse_face_vertex(fields[i])
                    if !key_ok do return {}, false
                    key.pos_idx, key_ok = obj_resolve_index(key.pos_idx, len(positions))
                    if !key_ok do return {}, false
                    if key.tex_idx != 0 {
                        key.tex_idx, key_ok = obj_resolve_index(key.tex_idx, len(texcoords))
                        if !key_ok do return {}, false
                    }
                    if key.norm_idx != 0 {
                        key.norm_idx, key_ok = obj_resolve_index(key.norm_idx, len(normals))
                        if !key_ok do return {}, false
                    } else {
                        missing_normals = true
                    }

                    if cached, found := vertex_cache[Vertex_Key(key)]; found {
                        append(&face_indices, cached)
                    } else {
                        pos := positions[key.pos_idx - 1]
                        norm: [3]f32
                        if key.norm_idx > 0 {
                            norm = normals[key.norm_idx - 1]
                        }
                        tex: [2]f32
                        if key.tex_idx > 0 {
                            tex = texcoords[key.tex_idx - 1]
                        }

                        vertex := Vertex{
                            position = pos,
                            normal   = norm,
                            texcoord = tex,
                        }

                        new_index := u32(len(out_vertices))
                        append(&out_vertices, vertex)
                        vertex_cache[Vertex_Key(key)] = new_index
                        append(&face_indices, new_index)
                    }
                }

                if len(face_indices) < 3 do return {}, false
                // Reversed: OBJ's counter-clockwise front faces become the
                // clockwise ones D3D expects.
                for i in 1..<len(face_indices) - 1 {
                    append(&out_indices, face_indices[0])
                    append(&out_indices, face_indices[i + 1])
                    append(&out_indices, face_indices[i])
                }
        }
    }

    if len(out_vertices) == 0 || len(out_indices) == 0 do return {}, false
    mesh.vertices = out_vertices[:]
    mesh.indices  = out_indices[:]
    if missing_normals do mesh_fill_missing_normals(mesh.vertices, mesh.indices)
    mesh_generate_tangents(mesh)
    mesh_single_submesh(&mesh, allocator)
    return mesh, true
}

// Area-weighted smooth normals (the sum of the surrounding triangles' face
// normals) for the vertices whose normal is zero, as in sources that come
// without them. Triangles must already have this renderer's clockwise
// winding.
mesh_fill_missing_normals :: proc(vertices: []Vertex, indices: []u32) {
    sums := make([]linalg.Vector3f32, len(vertices), context.temp_allocator)
    for triangle in 0..<len(indices) / 3 {
        a := indices[triangle * 3]
        b := indices[triangle * 3 + 1]
        c := indices[triangle * 3 + 2]
        pa := linalg.Vector3f32(vertices[a].position)
        n := linalg.cross(linalg.Vector3f32(vertices[b].position) - pa, linalg.Vector3f32(vertices[c].position) - pa)
        for i in ([3]u32{a, b, c}) do sums[i] += n
    }
    for &vertex, i in vertices {
        if vertex.normal != {} do continue
        n := sums[i]
        vertex.normal = linalg.normalize(n) if linalg.dot(n, n) > 0 else {0, 1, 0}
    }
}

// Fills each vertex's tangent from the UV directions of the triangles around
// it, made perpendicular to the normal, with the bitangent's handedness in w
// (the shader rebuilds the bitangent from it). Also normalizes the normals.
mesh_generate_tangents :: proc(mesh: MeshData) {
    tangents := make(
        []linalg.Vector3f32,
        len(mesh.vertices),
        context.temp_allocator,
    )
    bitangents := make(
        []linalg.Vector3f32,
        len(mesh.vertices),
        context.temp_allocator,
    )

    for triangle in 0..<len(mesh.indices) / 3 {
        i0 := mesh.indices[triangle * 3 + 0]
        i1 := mesh.indices[triangle * 3 + 1]
        i2 := mesh.indices[triangle * 3 + 2]

        v0 := mesh.vertices[i0]
        v1 := mesh.vertices[i1]
        v2 := mesh.vertices[i2]

        edge1 := linalg.Vector3f32(v1.position) -
                 linalg.Vector3f32(v0.position)
        edge2 := linalg.Vector3f32(v2.position) -
                 linalg.Vector3f32(v0.position)

        uv1 := linalg.Vector2f32(v1.texcoord) -
               linalg.Vector2f32(v0.texcoord)
        uv2 := linalg.Vector2f32(v2.texcoord) -
               linalg.Vector2f32(v0.texcoord)

        determinant := uv1.x * uv2.y - uv1.y * uv2.x
        if math.abs(determinant) < 0.00000001 {
            continue
        }

        tangent := (edge1 * uv2.y - edge2 * uv1.y) / determinant
        bitangent := (edge2 * uv1.x - edge1 * uv2.x) / determinant

        triangle_indices := [3]u32{i0, i1, i2}
        for index in triangle_indices {
            tangents[index] += tangent
            bitangents[index] += bitangent
        }
    }

    for i in 0..<len(mesh.vertices) {
        N := linalg.Vector3f32(mesh.vertices[i].normal)
        if linalg.dot(N, N) < 0.00000001 {
            N = {0, 1, 0}
        } else {
            N = linalg.normalize(N)
        }

        // Remove the tangent's component along the normal.
        T := tangents[i] - N * linalg.dot(N, tangents[i])

        // Provide a valid basis even for degenerate/missing UVs.
        if linalg.dot(T, T) < 0.00000001 {
            helper := linalg.Vector3f32{0, 1, 0}
            if math.abs(N.y) > 0.99 {
                helper = {1, 0, 0}
            }
            T = linalg.cross(helper, N)
        }
        T = linalg.normalize(T)

        handedness: f32 = 1
        if linalg.dot(linalg.cross(N, T), bitangents[i]) < 0 {
            handedness = -1
        }

        mesh.vertices[i].normal = N
        mesh.vertices[i].tangent = {T.x, T.y, T.z, handedness}
    }
}

@(private)
parse_face_vertex :: proc(s: string) -> (key: struct { pos_idx, tex_idx, norm_idx: int }, ok: bool) {
    parts := strings.split(s, "/", context.temp_allocator)

    if len(parts) < 1 || len(parts) > 3 do return {}, false
    key.pos_idx, ok = strconv.parse_int(parts[0])
    if !ok || key.pos_idx == 0 do return {}, false

    if len(parts) > 1 && len(parts[1]) > 0 {
        key.tex_idx, ok = strconv.parse_int(parts[1])
        if !ok || key.tex_idx == 0 do return {}, false
    }
    if len(parts) > 2 && len(parts[2]) > 0 {
        key.norm_idx, ok = strconv.parse_int(parts[2])
        if !ok || key.norm_idx == 0 do return {}, false
    }

    return key, true
}

// OBJ indices start at 1; negative ones count back from the latest element.
obj_resolve_index :: proc(index, count: int) -> (int, bool) {
    resolved := index if index > 0 else count + index + 1
    return resolved, resolved > 0 && resolved <= count
}

// ---------------------------------------------------------------------------
// Levels of detail. Each large submesh gets a chain of simplified versions,
// each about half the triangles of the one before, built when the mesh loads
// or is imported (mesh_build_lods). They reuse the mesh's vertices: only new
// index ranges, appended to the index buffer, with meshlets of their own. The
// renderer draws the coarsest level whose error, projected to the screen,
// stays under a pixel (renderer_frame_data.odin, renderer_select_lod).
//
// The simplifier collapses edges by their quadric error (Garland and
// Heckbert, 1997), in the manner of meshoptimizer: each collapse moves one
// vertex onto a neighbour (so no new vertices), the cheapest first. Vertices
// that share a position (seams in UVs or normals) move together, and what
// kind of place a position is decides where it may go:
//   manifold: inside the surface, one vertex: anywhere;
//   border:   on an open edge (the mesh's, or the submesh's own, such as a
//             material boundary): only along that edge;
//   seam:     on a UV or normal seam, two vertices: only along the seam, both
//             to the matching vertices on its two sides;
//   locked:   anything else (corners, non-manifold edges): never.
// Collapses that would turn a triangle over are skipped.

MeshLod :: struct {
    first_index, index_count: u32,
    first_meshlet, meshlet_count: u32,
    // How far this level's surface may stray from the original, in mesh
    // units: the largest collapse's distance, by the quadrics.
    error: f32,
}

// Levels per submesh, below the full one.
MAX_MESH_LODS :: 6
// Smaller submeshes keep only their full version.
LOD_MIN_SUBMESH_TRIANGLES :: 256
// The chain stops at about this many triangles...
LOD_MIN_TRIANGLES :: 64
// ...or when a level keeps more than this share of the one before (the rest
// cannot be simplified without breaking borders or seams).
LOD_MIN_REDUCTION :: f32(0.85)
// Planes along borders and seams, added to their vertices' quadrics with this
// weight times the edge's length squared, so they keep their shape.
LOD_BORDER_WEIGHT :: f64(10)
LOD_SEAM_WEIGHT :: f64(1)

@(private="file")
Quadric :: struct {
    a: [10]f64,
    weight: f64,
}

@(private="file")
quadric_plane :: proc(n: [3]f64, d, weight: f64) -> Quadric {
    return Quadric{
        a = [10]f64{
            n.x * n.x, n.x * n.y, n.x * n.z, n.x * d,
            n.y * n.y, n.y * n.z, n.y * d,
            n.z * n.z, n.z * d,
            d * d,
        } * weight,
        weight = weight,
    }
}

@(private="file")
quadric_add :: proc(q: ^Quadric, other: Quadric) {
    q.a += other.a
    q.weight += other.weight
}

// The distance from p to the quadric's planes: the root of the weighted mean
// squared distance.
@(private="file")
quadric_distance :: proc(q: Quadric, p: [3]f64) -> f64 {
    x, y, z := p.x, p.y, p.z
    a := q.a
    e := a[0] * x * x + 2 * a[1] * x * y + 2 * a[2] * x * z + 2 * a[3] * x +
         a[4] * y * y + 2 * a[5] * y * z + 2 * a[6] * y +
         a[7] * z * z + 2 * a[8] * z + a[9]
    return math.sqrt(max(e, 0) / max(q.weight, 1e-30))
}

@(private="file")
Vertex_Kind :: enum u8 {Manifold, Border, Seam, Locked}

// An edge between two positions (lo < hi): how many triangles run it each
// way, the vertices of its first lo -> hi and hi -> lo use (a seam when they
// differ), and a triangle with it.
@(private="file")
Lod_Edge :: struct {
    forward, backward: u32,
    forward_a, forward_b, backward_a, backward_b: u32,
    triangle: u32,
}

@(private="file")
Lod_Collapse :: struct {
    from, to: u32,
    error: f32,
}

// One submesh's simplification in progress. Positions are named by their
// group: the lowest vertex index at that position.
@(private="file")
Simplifier :: struct {
    vertices: []Vertex,
    indices: [dynamic]u32,
    group: []u32,
    // Each group's vertices (CSR over groups).
    wedge_offsets, wedges: []u32,
    kind: []Vertex_Kind,
    quadrics: []Quadric,
    // Reused per pass: each group's triangles (CSR), the edges, candidates,
    // where each vertex moves, and groups taken this pass.
    fan_offsets, fan: []u32,
    edges: map[u64]Lod_Edge,
    candidates: [dynamic]Lod_Collapse,
    remap, fill: []u32,
    taken: []bool,
    // Each group's cheapest allowed move this pass.
    best_to: []u32,
    best_error: []f32,
    error: f32,
}

@(private="file")
lod_edge_key :: proc(a, b: u32) -> (key: u64, forward: bool) {
    if a < b do return u64(a) << 32 | u64(b), true
    return u64(b) << 32 | u64(a), false
}

@(private="file")
lod_position :: proc(s: ^Simplifier, group: u32) -> [3]f64 {
    p := s.vertices[group].position
    return {f64(p.x), f64(p.y), f64(p.z)}
}

// The edges of the current triangles, by position.
@(private="file")
lod_build_edges :: proc(s: ^Simplifier) {
    clear(&s.edges)
    for t in 0..<len(s.indices) / 3 {
        for k in 0..<3 {
            a, b := s.indices[t * 3 + k], s.indices[t * 3 + (k + 1) % 3]
            ga, gb := s.group[a], s.group[b]
            if ga == gb do continue
            key, forward := lod_edge_key(ga, gb)
            if key not_in s.edges do s.edges[key] = {triangle = u32(t)}
            edge := &s.edges[key]
            if forward {
                if edge.forward == 0 do edge.forward_a, edge.forward_b = a, b
                edge.forward += 1
            } else {
                if edge.backward == 0 do edge.backward_a, edge.backward_b = a, b
                edge.backward += 1
            }
        }
    }
}

@(private="file")
lod_edge_open :: proc(edge: Lod_Edge) -> bool {
    return edge.forward == 0 || edge.backward == 0
}

@(private="file")
lod_edge_seam :: proc(edge: Lod_Edge) -> bool {
    return edge.forward == 1 && edge.backward == 1 &&
           (edge.forward_a != edge.backward_b || edge.forward_b != edge.backward_a)
}

// The triangle's face normal (not normalized), from its positions.
@(private="file")
lod_face :: proc(s: ^Simplifier, t: int) -> [3]f64 {
    p0 := lod_position(s, s.group[s.indices[t * 3]])
    p1 := lod_position(s, s.group[s.indices[t * 3 + 1]])
    p2 := lod_position(s, s.group[s.indices[t * 3 + 2]])
    return linalg.cross(p1 - p0, p2 - p0)
}

// Groups, quadrics and kinds, from the submesh's original triangles.
@(private="file")
lod_init :: proc(s: ^Simplifier, vertices: []Vertex, range: []u32) {
    vertex_count := len(vertices)
    s.vertices = vertices
    s.indices = make([dynamic]u32, len(range), context.temp_allocator)
    copy(s.indices[:], range)
    s.group = make([]u32, vertex_count, context.temp_allocator)
    s.kind = make([]Vertex_Kind, vertex_count, context.temp_allocator)
    s.quadrics = make([]Quadric, vertex_count, context.temp_allocator)
    s.fan_offsets = make([]u32, vertex_count + 1, context.temp_allocator)
    s.fan = make([]u32, len(range), context.temp_allocator)
    s.remap = make([]u32, vertex_count, context.temp_allocator)
    s.taken = make([]bool, vertex_count, context.temp_allocator)
    s.fill = make([]u32, vertex_count, context.temp_allocator)
    s.best_to = make([]u32, vertex_count, context.temp_allocator)
    s.best_error = make([]f32, vertex_count, context.temp_allocator)
    s.edges = make(map[u64]Lod_Edge, len(range), context.temp_allocator)
    s.candidates = make([dynamic]Lod_Collapse, 0, len(range) * 2, context.temp_allocator)

    // Positions: the first vertex seen at each names the group.
    first_at := make(map[[3]f32]u32, len(range), context.temp_allocator)
    used := make([]bool, vertex_count, context.temp_allocator)
    for index in range {
        if used[index] do continue
        used[index] = true
        p := vertices[index].position
        if group, found := first_at[p]; found {
            s.group[index] = group
        } else {
            first_at[p] = index
            s.group[index] = index
        }
    }
    // Each group's vertices.
    s.wedge_offsets = make([]u32, vertex_count + 1, context.temp_allocator)
    for v in 0..<vertex_count do if used[v] do s.wedge_offsets[s.group[v] + 1] += 1
    for v in 0..<vertex_count do s.wedge_offsets[v + 1] += s.wedge_offsets[v]
    s.wedges = make([]u32, s.wedge_offsets[vertex_count], context.temp_allocator)
    fill := make([]u32, vertex_count, context.temp_allocator)
    for v in 0..<vertex_count {
        if !used[v] do continue
        g := s.group[v]
        s.wedges[s.wedge_offsets[g] + fill[g]] = u32(v)
        fill[g] += 1
    }

    // Each triangle's plane, weighted by its area, on its corners' groups.
    for t in 0..<len(range) / 3 {
        n := lod_face(s, t)
        length := linalg.length(n)
        if length < 1e-20 do continue
        n /= length
        p0 := lod_position(s, s.group[range[t * 3]])
        q := quadric_plane(n, -linalg.dot(n, p0), length * 0.5)
        for k in 0..<3 do quadric_add(&s.quadrics[s.group[range[t * 3 + k]]], q)
    }

    // Borders and seams: count them per group, and add their planes.
    lod_build_edges(s)
    borders := make([]u8, vertex_count, context.temp_allocator)
    seams := make([]u8, vertex_count, context.temp_allocator)
    locked := make([]bool, vertex_count, context.temp_allocator)
    for key, edge in s.edges {
        lo, hi := u32(key >> 32), u32(key & 0xFFFFFFFF)
        if edge.forward > 1 || edge.backward > 1 {
            locked[lo], locked[hi] = true, true
            continue
        }
        open := lod_edge_open(edge)
        seam := lod_edge_seam(edge)
        if !open && !seam do continue
        if open {
            borders[lo] = min(borders[lo] + 1, 255)
            borders[hi] = min(borders[hi] + 1, 255)
        } else {
            seams[lo] = min(seams[lo] + 1, 255)
            seams[hi] = min(seams[hi] + 1, 255)
        }
        // A plane through the edge, upright on its triangle.
        p_lo, p_hi := lod_position(s, lo), lod_position(s, hi)
        direction := p_hi - p_lo
        length_sq := linalg.dot(direction, direction)
        face := lod_face(s, int(edge.triangle))
        normal := linalg.cross(direction, face)
        normal_length := linalg.length(normal)
        if length_sq < 1e-20 || normal_length < 1e-20 do continue
        normal /= normal_length
        q := quadric_plane(normal, -linalg.dot(normal, p_lo), length_sq * (LOD_BORDER_WEIGHT if open else LOD_SEAM_WEIGHT))
        quadric_add(&s.quadrics[lo], q)
        quadric_add(&s.quadrics[hi], q)
    }
    for v in 0..<vertex_count {
        if !used[v] || s.group[v] != u32(v) do continue
        wedge_count := s.wedge_offsets[v + 1] - s.wedge_offsets[v]
        switch {
        case locked[v]:
            s.kind[v] = .Locked
        case borders[v] == 0 && seams[v] == 0 && wedge_count == 1:
            s.kind[v] = .Manifold
        case borders[v] == 2 && seams[v] == 0 && wedge_count == 1:
            s.kind[v] = .Border
        case seams[v] == 2 && borders[v] == 0 && wedge_count == 2:
            s.kind[v] = .Seam
        case:
            s.kind[v] = .Locked
        }
    }
}

// Each group's current triangles.
@(private="file")
lod_build_fans :: proc(s: ^Simplifier) {
    slice.zero(s.fan_offsets)
    for index in s.indices do s.fan_offsets[s.group[index] + 1] += 1
    for v in 0..<len(s.fan_offsets) - 1 do s.fan_offsets[v + 1] += s.fan_offsets[v]
    slice.zero(s.fill)
    for index, i in s.indices {
        g := s.group[index]
        s.fan[s.fan_offsets[g] + s.fill[g]] = u32(i / 3)
        s.fill[g] += 1
    }
}

// The current edge between groups `from` and `to`, from `from`'s triangles.
@(private="file")
lod_edge_between :: proc(s: ^Simplifier, from, to: u32) -> (edge: Lod_Edge) {
    for t in s.fan[s.fan_offsets[from]:s.fan_offsets[from + 1]] {
        for k in 0..<3 {
            a, b := s.indices[t * 3 + u32(k)], s.indices[t * 3 + u32(k + 1) % 3]
            if s.group[a] == from && s.group[b] == to {
                if edge.forward == 0 do edge.forward_a, edge.forward_b = a, b
                edge.forward += 1
            } else if s.group[a] == to && s.group[b] == from {
                if edge.backward == 0 do edge.backward_a, edge.backward_b = a, b
                edge.backward += 1
            }
        }
    }
    return
}

// Whether `from` may move onto `to` by its kind: borders only along open
// edges, seams only along seams.
@(private="file")
lod_allowed :: proc(s: ^Simplifier, from, to: u32) -> bool {
    switch s.kind[from] {
    case .Manifold:
        return true
    case .Border:
        edge := lod_edge_between(s, from, to)
        return edge.forward + edge.backward == 1
    case .Seam:
        return lod_edge_seam(lod_edge_between(s, from, to))
    case .Locked:
        return false
    }
    return false
}

// Where each of `from`'s vertices goes: the vertex of `to` it shares a
// triangle with (on its own side of a seam). False if one has none, or if a
// triangle around `from` would turn over.
@(private="file")
lod_try_collapse :: proc(s: ^Simplifier, from, to: u32) -> bool {
    target := lod_position(s, to)
    for wedge in s.wedges[s.wedge_offsets[from]:s.wedge_offsets[from + 1]] {
        s.remap[wedge] = wedge
    }
    for t in s.fan[s.fan_offsets[from]:s.fan_offsets[from + 1]] {
        corners := s.indices[t * 3:][:3]
        to_corner := -1
        from_corner := -1
        for k in 0..<3 {
            if s.group[corners[k]] == to do to_corner = k
            if s.group[corners[k]] == from do from_corner = k
        }
        if to_corner >= 0 {
            // This triangle disappears; it tells its `from` vertex where to go.
            s.remap[corners[from_corner]] = corners[to_corner]
            continue
        }
        // The triangle with `from` moved: must keep facing the same way.
        p: [3][3]f64
        for k in 0..<3 do p[k] = lod_position(s, s.group[corners[k]])
        before := linalg.cross(p[1] - p[0], p[2] - p[0])
        p[from_corner] = target
        after := linalg.cross(p[1] - p[0], p[2] - p[0])
        if linalg.dot(before, after) <= 0 do return false
    }
    for wedge in s.wedges[s.wedge_offsets[from]:s.wedge_offsets[from + 1]] {
        if s.remap[wedge] == wedge do return false
    }
    return true
}

// Collapses edges, cheapest first, until the triangles are down to `target`
// or no allowed collapse is left. Each pass gathers every allowed collapse,
// sorts them by error, and makes as many as could be needed, skipping any
// that touches a group already moved this pass or next to one; then the
// triangles are rewritten and the ones that collapsed dropped.
@(private="file")
lod_simplify :: proc(s: ^Simplifier, target: int) {
    for len(s.indices) / 3 > target {
        lod_build_fans(s)
        // Each group's cheapest allowed move.
        for index in s.indices do s.best_error[s.group[index]] = max(f32)
        for t in 0..<len(s.indices) / 3 {
            for k in 0..<3 {
                ga, gb := s.group[s.indices[t * 3 + k]], s.group[s.indices[t * 3 + (k + 1) % 3]]
                if ga == gb do continue
                for direction in 0..<2 {
                    from, to := ga, gb
                    if direction == 1 do from, to = gb, ga
                    if s.kind[from] == .Locked do continue
                    error := f32(quadric_distance(s.quadrics[from], lod_position(s, to)))
                    if error >= s.best_error[from] || !lod_allowed(s, from, to) do continue
                    s.best_error[from] = error
                    s.best_to[from] = to
                }
            }
        }
        clear(&s.candidates)
        for index in s.indices {
            g := s.group[index]
            if s.best_error[g] == max(f32) do continue
            append(&s.candidates, Lod_Collapse{g, s.best_to[g], s.best_error[g]})
            // Once per group.
            s.best_error[g] = max(f32)
        }
        if len(s.candidates) == 0 do break
        slice.sort_by(s.candidates[:], proc(a, b: Lod_Collapse) -> bool {return a.error < b.error})

        // About two triangles go per collapse. A pass goes no further than
        // half again the error of the collapse that would meet the budget:
        // cheap collapses blocked by a neighbour's this pass wait for the next
        // instead of costlier ones taking their place (meshoptimizer's limit).
        budget := max((len(s.indices) / 3 - target) / 2, 1)
        pass_limit := s.candidates[min(budget, len(s.candidates) - 1)].error * 1.5
        slice.zero(s.taken)
        for v in 0..<len(s.remap) do s.remap[v] = u32(v)
        done := 0
        for candidate in s.candidates {
            if done >= budget || candidate.error > pass_limit do break
            if s.taken[candidate.from] || s.taken[candidate.to] do continue
            if !lod_try_collapse(s, candidate.from, candidate.to) do continue
            // Its triangles' groups are taken for the rest of this pass, so
            // every check above saw positions that still hold.
            for t in s.fan[s.fan_offsets[candidate.from]:s.fan_offsets[candidate.from + 1]] {
                for k in 0..<3 do s.taken[s.group[s.indices[t * 3 + u32(k)]]] = true
            }
            quadric_add(&s.quadrics[candidate.to], s.quadrics[candidate.from])
            s.error = max(s.error, candidate.error)
            done += 1
        }
        if done == 0 do break

        kept := 0
        for t in 0..<len(s.indices) / 3 {
            a, b, c := s.remap[s.indices[t * 3]], s.remap[s.indices[t * 3 + 1]], s.remap[s.indices[t * 3 + 2]]
            if s.group[a] == s.group[b] || s.group[b] == s.group[c] || s.group[a] == s.group[c] do continue
            s.indices[kept * 3], s.indices[kept * 3 + 1], s.indices[kept * 3 + 2] = a, b, c
            kept += 1
        }
        resize(&s.indices, kept * 3)
    }
}

// The level-of-detail chains of every large submesh: each level simplified
// from the one before to half its triangles, its indices appended after the
// mesh's (reallocated with `allocator`), until the chain stops gaining.
// Submeshes are simplified at the same time on worker threads (each with its
// own temporary memory), then their levels are appended in submesh order.
mesh_build_lods :: proc(mesh: ^MeshData, allocator := context.allocator) {
    Lod_Chain :: struct {
        // Each level's indices one after another, and the levels (first_index
        // counted within `indices` until they are appended).
        indices: [dynamic]u32,
        lods: [dynamic]MeshLod,
    }
    Lod_Work :: struct {
        mesh: ^MeshData,
        chains: []Lod_Chain,
        next: int,
    }
    chain_submesh :: proc(mesh: ^MeshData, submesh: Submesh, chain: ^Lod_Chain) {
        triangles := int(submesh.index_count / 3)
        if triangles < LOD_MIN_SUBMESH_TRIANGLES do return
        // The submesh's working memory goes when it is done.
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        s: Simplifier
        lod_init(&s, mesh.vertices, mesh.indices[submesh.first_index:][:submesh.index_count])
        previous := triangles
        for _ in 0..<MAX_MESH_LODS {
            target := previous / 2
            if target < LOD_MIN_TRIANGLES do break
            lod_simplify(&s, target)
            count := len(s.indices) / 3
            if f32(count) > f32(previous) * LOD_MIN_REDUCTION do break
            append(&chain.lods, MeshLod{first_index = u32(len(chain.indices)), index_count = u32(len(s.indices)), error = s.error})
            append(&chain.indices, ..s.indices[:])
            previous = count
        }
    }
    worker :: proc(work: ^Lod_Work) {
        for {
            i := sync.atomic_add(&work.next, 1)
            if i >= len(work.chains) do break
            chain_submesh(work.mesh, work.mesh.submeshes[i], &work.chains[i])
        }
    }

    work := Lod_Work{mesh = mesh, chains = make([]Lod_Chain, len(mesh.submeshes))}
    defer {
        for chain in work.chains {
            delete(chain.indices)
            delete(chain.lods)
        }
        delete(work.chains)
    }
    large := 0
    for submesh in mesh.submeshes do if submesh.index_count / 3 >= LOD_MIN_SUBMESH_TRIANGLES do large += 1
    if large > 1 {
        threads := make([]^thread.Thread, min(large, max(os.get_processor_core_count(), 1)), context.temp_allocator)
        for &t in threads do t = thread.create_and_start_with_poly_data(&work, worker)
        thread.join_multiple(..threads)
        for t in threads do thread.destroy(t)
    } else {
        worker(&work)
    }

    lods := make([dynamic]MeshLod, allocator)
    base_count := len(mesh.indices)
    extra_count := 0
    for chain in work.chains do extra_count += len(chain.indices)
    indices := mesh.indices
    if extra_count > 0 {
        indices = make([]u32, base_count + extra_count, allocator)
        copy(indices, mesh.indices)
    }
    at := base_count
    for &submesh, i in mesh.submeshes {
        chain := &work.chains[i]
        submesh.first_lod, submesh.lod_count = u32(len(lods)), u32(len(chain.lods))
        for lod in chain.lods {
            moved := lod
            moved.first_index += u32(at)
            append(&lods, moved)
        }
        copy(indices[at:], chain.indices[:])
        at += len(chain.indices)
    }
    mesh.lods = lods[:]
    if extra_count > 0 {
        delete(mesh.indices, allocator)
        mesh.indices = indices
    }
}
