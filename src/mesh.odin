package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:math/linalg"
import "core:math"
import "core:slice"

MeshData :: struct {
    vertices: []Vertex,
    indices: []u32,
    // Index ranges drawn with one material slot each; together they cover
    // all indices. An OBJ has a single submesh.
    submeshes: []Submesh,
    // Every large submesh's meshlets (mesh_build_meshlets), in submesh order.
    meshlets: []Meshlet,
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
}

// One submesh covering the whole mesh, for single-material sources.
mesh_single_submesh :: proc(mesh: ^MeshData, allocator := context.allocator) {
    mesh.submeshes = make([]Submesh, 1, allocator)
    mesh.submeshes[0] = {index_count = u32(len(mesh.indices))}
    mesh_compute_submesh_bounds(mesh^)
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
    tri_offsets := make([]u32, vertex_count + 1, context.temp_allocator)
    vertex_mark := make([]i32, vertex_count, context.temp_allocator)
    fill := make([]u32, vertex_count, context.temp_allocator)
    for submesh_index in 0..<len(mesh.submeshes) {
        submesh := &mesh.submeshes[submesh_index]
        submesh.first_meshlet, submesh.meshlet_count = u32(len(meshlets)), 0
        triangle_count := int(submesh.index_count / 3)
        if triangle_count < MESHLET_MIN_SUBMESH_TRIANGLES do continue
        range := mesh.indices[submesh.first_index:][:triangle_count * 3]

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
            meshlet.first_index = submesh.first_index + u32(first)
            meshlet.index_count = u32(len(reordered) - first)
            append(&meshlets, meshlet)
            submesh.meshlet_count += 1
        }
        copy(range, reordered[:])
    }
    mesh.meshlets = meshlets[:]
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
