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
}

mesh_load_obj :: proc(path: string, allocator := context.allocator) -> (mesh: MeshData, ok: bool){
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
                x := strconv.parse_f32(fields[1]) or_else 0
                y := strconv.parse_f32(fields[2]) or_else 0
                z := strconv.parse_f32(fields[3]) or_else 0
                append(&positions, [3]f32{x, y, z})

            case "vn":
                x := strconv.parse_f32(fields[1]) or_else 0
                y := strconv.parse_f32(fields[2]) or_else 0
                z := strconv.parse_f32(fields[3]) or_else 0
                append(&normals, [3]f32{x, y, z})

            case "vt":
                u := strconv.parse_f32(fields[1]) or_else 0
                v := strconv.parse_f32(fields[2]) or_else 0
                append(&texcoords, [2]f32{u, v})
            case "f":
                // Разбиваем грань на треугольники если их больше 3 вершин (fan triangulation)
                face_indices := make([dynamic]u32, context.temp_allocator)

                for i in 1..<len(fields) {
                    key := parse_face_vertex(fields[i])

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

                // Триангулируем веером: (0,1,2), (0,2,3), (0,3,4)...
                for i in 1..<len(face_indices) - 1 {
                    append(&out_indices, face_indices[0])
                    append(&out_indices, face_indices[i])
                    append(&out_indices, face_indices[i + 1])
                }
        }
    }

    mesh.vertices = out_vertices[:]
    mesh.indices  = out_indices[:]
    mesh_generate_tangents(mesh)
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
parse_face_vertex :: proc(s: string) -> (key: struct { pos_idx, tex_idx, norm_idx: int }) {
    parts := strings.split(s, "/", context.temp_allocator)

    key.pos_idx = strconv.parse_int(parts[0]) or_else 0

    if len(parts) > 1 && len(parts[1]) > 0 {
        key.tex_idx = strconv.parse_int(parts[1]) or_else 0
    }
    if len(parts) > 2 && len(parts[2]) > 0 {
        key.norm_idx = strconv.parse_int(parts[2]) or_else 0
    }

    return
}