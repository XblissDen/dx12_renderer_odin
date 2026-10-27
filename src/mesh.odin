package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:math/linalg"
import "core:math"

MeshData :: struct {
    vertices: []Vertex,
    indices: []u32,
    // Index ranges drawn with one material slot each; together they cover
    // all indices. An OBJ has a single submesh.
    submeshes: []Submesh,
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
}

// One submesh covering the whole mesh, for single-material sources.
mesh_single_submesh :: proc(mesh: ^MeshData, allocator := context.allocator) {
    mesh.submeshes = make([]Submesh, 1, allocator)
    mesh.submeshes[0] = {index_count = u32(len(mesh.indices))}
    mesh_compute_submesh_bounds(mesh^)
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
    mesh_generate_tangents(mesh)
    mesh_single_submesh(&mesh, allocator)
    return mesh, true
}

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

obj_resolve_index :: proc(index, count: int) -> (int, bool) {
    resolved := index if index > 0 else count + index + 1
    return resolved, resolved > 0 && resolved <= count
}
