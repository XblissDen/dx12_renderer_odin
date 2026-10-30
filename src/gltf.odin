package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import alg "core:math/linalg"
import "core:os"
import "core:strings"

// glTF 2.0 loading (.gltf with external or embedded buffers, and .glb).
// A model comes out two ways. Flattened: node transforms are baked into the
// vertices, and all primitives sharing a material become one submesh. And as
// its node tree: each node's placement relative to its parent, and the parts
// (one per glTF mesh, in the mesh's own space) the nodes draw. Geometry is
// converted from glTF's right-handed space (+Y up, +Z toward the viewer) to
// this renderer's left-handed space by negating Z and reversing the triangle
// winding to the clockwise front faces D3D expects.

Gltf_Material :: struct {
    name: string,
    base_color: [4]f32,
    metallic, roughness, normal_scale: f32,
    emissive: [3]f32,
    emissive_strength, occlusion_strength, alpha_cutoff: f32,
    // Indices into Gltf_Model.images, or -1.
    base_color_image, metallic_roughness_image, normal_image: int,
    emissive_image, occlusion_image: int,
    alpha_mode: string, // OPAQUE, MASK or BLEND
    double_sided: bool,
}

Gltf_Image :: struct {
    uri: string,     // Relative to the model file; empty when embedded.
    data: []u8,      // Embedded bytes (GLB buffer view or data URI).
    mime_type: string,
}

Gltf_Model :: struct {
    mesh: MeshData,             // Owned by the caller's allocator.
    materials: []Gltf_Material, // One per material slot, in slot order.
    images: []Gltf_Image,
    // The node tree, parents before children, and the parts its nodes draw.
    nodes: []Gltf_Node,
    parts: []Gltf_Part,
    warnings: []string,
}

Gltf_Node :: struct {
    name: string,
    parent: int, // Index into Gltf_Model.nodes, or -1 for a root.
    // Placement relative to the parent node, in left-handed space. Always
    // keeps handedness: a mirroring node draws a mirrored part instead.
    local: alg.Matrix4f32,
    part: int,   // Index into Gltf_Model.parts, or -1 for none.
}

// One glTF mesh in its own space, with submeshes numbered by the model's
// material slots. `mirrored` parts are reflected across X, for nodes whose
// transform mirrors.
Gltf_Part :: struct {
    name: string,
    mesh_index: int,
    mirrored: bool,
    mesh: MeshData, // Owned by the caller's allocator.
}

@(private="file")
Doc_Node :: struct {
    name: string,
    mesh: Maybe(int),
    children: []int,
    matrix_: Maybe([16]f32) `json:"matrix"`,
    translation: Maybe([3]f32),
    rotation: Maybe([4]f32),
    scale: Maybe([3]f32),
}

@(private="file")
Doc_Primitive :: struct {
    attributes: map[string]int,
    indices: Maybe(int),
    material: Maybe(int),
    mode: Maybe(int),
}

@(private="file")
Doc_Accessor :: struct {
    buffer_view: Maybe(int) `json:"bufferView"`,
    byte_offset: int `json:"byteOffset"`,
    component_type: int `json:"componentType"`,
    normalized: bool,
    count: int,
    kind: string `json:"type"`,
    sparse: Maybe(struct {count: int}),
}

@(private="file")
Doc_Buffer_View :: struct {
    buffer: int,
    byte_offset: int `json:"byteOffset"`,
    byte_length: int `json:"byteLength"`,
    byte_stride: int `json:"byteStride"`,
}

@(private="file")
Doc_Texture_Ref :: struct {
    index: int,
    tex_coord: int `json:"texCoord"`,
    scale: Maybe(f32),    // Normal textures.
    strength: Maybe(f32), // Occlusion textures.
}

@(private="file")
Doc_Material :: struct {
    name: string,
    pbr: struct {
        base_color_factor: Maybe([4]f32) `json:"baseColorFactor"`,
        base_color_texture: Maybe(Doc_Texture_Ref) `json:"baseColorTexture"`,
        metallic_factor: Maybe(f32) `json:"metallicFactor"`,
        roughness_factor: Maybe(f32) `json:"roughnessFactor"`,
        metallic_roughness_texture: Maybe(Doc_Texture_Ref) `json:"metallicRoughnessTexture"`,
    } `json:"pbrMetallicRoughness"`,
    normal_texture: Maybe(Doc_Texture_Ref) `json:"normalTexture"`,
    occlusion_texture: Maybe(Doc_Texture_Ref) `json:"occlusionTexture"`,
    emissive_texture: Maybe(Doc_Texture_Ref) `json:"emissiveTexture"`,
    emissive_factor: Maybe([3]f32) `json:"emissiveFactor"`,
    alpha_mode: string `json:"alphaMode"`,
    alpha_cutoff: Maybe(f32) `json:"alphaCutoff"`,
    double_sided: bool `json:"doubleSided"`,
    extensions: struct {
        // Scales emission past glTF's [0, 1] factor range.
        emissive_strength: Maybe(struct {
            value: Maybe(f32) `json:"emissiveStrength"`,
        }) `json:"KHR_materials_emissive_strength"`,
    },
}

@(private="file")
Doc :: struct {
    scene: Maybe(int),
    scenes: []struct {nodes: []int},
    nodes: []Doc_Node,
    meshes: []struct {name: string, primitives: []Doc_Primitive},
    accessors: []Doc_Accessor,
    buffer_views: []Doc_Buffer_View `json:"bufferViews"`,
    buffers: []struct {uri: string, byte_length: int `json:"byteLength"`},
    materials: []Doc_Material,
    textures: []struct {source: Maybe(int)},
    images: []struct {uri: string, mime_type: string `json:"mimeType"`, buffer_view: Maybe(int) `json:"bufferView"`},
    extensions_required: []string `json:"extensionsRequired"`,
}

GLB_MAGIC :: 0x46546C67 // "glTF"
GLB_CHUNK_JSON :: 0x4E4F534A
GLB_CHUNK_BIN :: 0x004E4942

// Parses and flattens a glTF file. Everything except model.mesh lives in
// the temporary allocator and must be used before it is freed.
gltf_load :: proc(path: string, allocator := context.allocator) -> (model: Gltf_Model, error: string) {
    file_data, read_error := os.read_entire_file(path, context.temp_allocator)
    if read_error != nil do return {}, "Cannot read the glTF file."

    json_bytes := file_data
    glb_bin: []u8
    if len(file_data) >= 12 && (^u32le)(raw_data(file_data))^ == GLB_MAGIC {
        json_bytes, glb_bin, error = gltf_split_glb(file_data)
        if error != "" do return
    }

    doc: Doc
    if json.unmarshal(json_bytes, &doc, allocator = context.temp_allocator) != nil {
        return {}, "Invalid glTF JSON."
    }
    if len(doc.extensions_required) > 0 {
        return {}, fmt.tprintf("Unsupported required glTF extension: %s.", strings.join(doc.extensions_required, ", ", context.temp_allocator))
    }

    // Buffers: the GLB binary chunk, a base64 data URI, or a file next to the model.
    directory := os.dir(path)
    buffers := make([][]u8, len(doc.buffers), context.temp_allocator)
    for buffer, i in doc.buffers {
        switch {
            case buffer.uri == "":
                if glb_bin == nil do return {}, "A glTF buffer has no data."
                buffers[i] = glb_bin
            case strings.has_prefix(buffer.uri, "data:"):
                buffers[i], error = gltf_decode_data_uri(buffer.uri)
                if error != "" do return
            case:
                buffer_path := fmt.tprintf("%s/%s", directory, gltf_decode_uri(buffer.uri))
                buffer_data, buffer_error := os.read_entire_file(buffer_path, context.temp_allocator)
                if buffer_error != nil do return {}, fmt.tprintf("Cannot read glTF buffer %s.", buffer.uri)
                buffers[i] = buffer_data
        }
        if len(buffers[i]) < buffer.byte_length do return {}, "A glTF buffer is shorter than declared."
    }

    images := make([]Gltf_Image, len(doc.images), context.temp_allocator)
    for image, i in doc.images {
        images[i].mime_type = image.mime_type
        if view, has_view := image.buffer_view.?; has_view {
            images[i].data, error = gltf_buffer_view_bytes(&doc, buffers, view)
            if error != "" do return
        } else if strings.has_prefix(image.uri, "data:") {
            images[i].data, error = gltf_decode_data_uri(image.uri)
            if error != "" do return
        } else {
            images[i].uri = gltf_decode_uri(image.uri)
        }
    }

    loader := Gltf_Loader{
        doc = &doc, buffers = buffers,
        slot_of_material = make(map[int]int, allocator = context.temp_allocator),
        nodes = make([dynamic]Gltf_Node, context.temp_allocator),
        parts = make([dynamic]Gltf_Loader_Part, context.temp_allocator),
        part_of_mesh = make(map[[2]int]int, allocator = context.temp_allocator),
    }
    scene_index := doc.scene.? or_else 0
    if scene_index < 0 || scene_index >= len(doc.scenes) {
        if len(doc.scenes) > 0 do return {}, "Invalid glTF scene index."
        // No scenes: treat every root node as part of the model.
        for node in 0..<len(doc.nodes) {
            if gltf_is_child(&doc, node) do continue
            error = gltf_visit_node(&loader, node, 1, 1, -1, 0)
            if error != "" do return
        }
    } else {
        for node in doc.scenes[scene_index].nodes {
            error = gltf_visit_node(&loader, node, 1, 1, -1, 0)
            if error != "" do return
        }
    }
    if len(loader.primitives) == 0 do return {}, "The glTF scene has no triangle geometry."
    if len(loader.slot_materials) > MAX_MODEL_MATERIALS {
        return {}, fmt.tprintf("The model uses %d materials; at most %d are supported.", len(loader.slot_materials), MAX_MODEL_MATERIALS)
    }

    model.mesh = gltf_merge_by_slot(loader.primitives[:], len(loader.slot_materials), allocator)
    parts := make([]Gltf_Part, len(loader.parts), context.temp_allocator)
    for part, i in loader.parts {
        parts[i] = {
            name = part.name, mesh_index = part.mesh_index, mirrored = part.mirrored,
            mesh = gltf_merge_by_slot(part.primitives[:], len(loader.slot_materials), allocator),
        }
    }
    model.parts = parts
    model.nodes = loader.nodes[:]
    model.images = images

    materials := make([]Gltf_Material, len(loader.slot_materials), context.temp_allocator)
    for material_index, slot in loader.slot_materials {
        materials[slot] = gltf_convert_material(&doc, material_index)
    }
    model.materials = materials
    model.warnings = loader.warnings[:]
    return
}

// Files a .gltf/.glb references next to itself (buffers and images), as
// decoded relative paths, so an import can copy them along.
gltf_external_files :: proc(path: string) -> (files: []string, error: string) {
    file_data, read_error := os.read_entire_file(path, context.temp_allocator)
    if read_error != nil do return nil, "Cannot read the glTF file."
    json_bytes := file_data
    if len(file_data) >= 12 && (^u32le)(raw_data(file_data))^ == GLB_MAGIC {
        json_bytes, _, error = gltf_split_glb(file_data)
        if error != "" do return
    }
    doc: Doc
    if json.unmarshal(json_bytes, &doc, allocator = context.temp_allocator) != nil {
        return nil, "Invalid glTF JSON."
    }

    result := make([dynamic]string, context.temp_allocator)
    add :: proc(result: ^[dynamic]string, uri: string) -> string {
        if uri == "" || strings.has_prefix(uri, "data:") do return ""
        relative := gltf_decode_uri(uri)
        // Only files beside or below the model can be copied into the project.
        if strings.contains(relative, "..") || strings.contains(relative, ":") || strings.has_prefix(relative, "/") {
            return fmt.tprintf("glTF file reference outside the model folder: %s", relative)
        }
        for existing in result do if existing == relative do return ""
        append(result, relative)
        return ""
    }
    for buffer in doc.buffers do if error = add(&result, buffer.uri); error != "" do return
    for image in doc.images do if error = add(&result, image.uri); error != "" do return
    return result[:], ""
}

@(private="file")
Gltf_Primitive_Out :: struct {
    vertices: []Vertex,
    indices: []u32,
    slot: int,
}

@(private="file")
Gltf_Loader_Part :: struct {
    name: string,
    mesh_index: int,
    mirrored: bool,
    primitives: [dynamic]Gltf_Primitive_Out,
}

@(private="file")
Gltf_Loader :: struct {
    doc: ^Doc,
    buffers: [][]u8,
    // The flattened model's primitives, in model space.
    primitives: [dynamic]Gltf_Primitive_Out,
    nodes: [dynamic]Gltf_Node,
    parts: [dynamic]Gltf_Loader_Part,
    // (mesh index, mirrored) -> index into parts, or -1 for a mesh without
    // triangles.
    part_of_mesh: map[[2]int]int,
    // glTF material index (-1 for "no material") -> slot, and the reverse.
    slot_of_material: map[int]int,
    slot_materials: [dynamic]int,
    warnings: [dynamic]string,
}

@(private="file")
gltf_split_glb :: proc(data: []u8) -> (json_bytes, bin: []u8, error: string) {
    header := ([^]u32le)(raw_data(data))
    if header[1] != 2 do return nil, nil, "Only glTF 2.0 binary files are supported."
    total := min(int(header[2]), len(data))
    offset := 12
    for offset + 8 <= total {
        chunk_length := int((^u32le)(&data[offset])^)
        chunk_type := (^u32le)(&data[offset + 4])^
        start := offset + 8
        if start + chunk_length > total do return nil, nil, "Truncated GLB chunk."
        switch chunk_type {
            case GLB_CHUNK_JSON: json_bytes = data[start:start + chunk_length]
            case GLB_CHUNK_BIN: if bin == nil do bin = data[start:start + chunk_length]
        }
        offset = start + chunk_length
    }
    if json_bytes == nil do return nil, nil, "The GLB file has no JSON chunk."
    return
}

@(private="file")
gltf_decode_data_uri :: proc(uri: string) -> (data: []u8, error: string) {
    comma := strings.index_byte(uri, ',')
    if comma < 0 || !strings.contains(uri[:comma], ";base64") do return nil, "Unsupported glTF data URI."
    decoded, decode_error := base64.decode(uri[comma + 1:], allocator = context.temp_allocator)
    if decode_error != nil do return nil, "Invalid base64 data in a glTF URI."
    return decoded, ""
}

// Resolves %XX escapes in relative URIs (e.g. spaces in file names).
gltf_decode_uri :: proc(uri: string) -> string {
    if !strings.contains_rune(uri, '%') do return uri
    hex :: proc(c: u8) -> (u8, bool) {
        switch c {
            case '0'..='9': return c - '0', true
            case 'a'..='f': return c - 'a' + 10, true
            case 'A'..='F': return c - 'A' + 10, true
        }
        return 0, false
    }
    out := make([dynamic]u8, 0, len(uri), context.temp_allocator)
    for i := 0; i < len(uri); i += 1 {
        if uri[i] == '%' && i + 2 < len(uri) {
            high, high_ok := hex(uri[i + 1])
            low, low_ok := hex(uri[i + 2])
            if high_ok && low_ok {
                append(&out, high * 16 + low)
                i += 2
                continue
            }
        }
        append(&out, uri[i])
    }
    return string(out[:])
}

@(private="file")
gltf_buffer_view_bytes :: proc(doc: ^Doc, buffers: [][]u8, view_index: int) -> ([]u8, string) {
    if view_index < 0 || view_index >= len(doc.buffer_views) do return nil, "Invalid glTF buffer view."
    view := doc.buffer_views[view_index]
    if view.buffer < 0 || view.buffer >= len(buffers) do return nil, "Invalid glTF buffer index."
    buffer := buffers[view.buffer]
    if view.byte_offset < 0 || view.byte_length < 0 || view.byte_offset + view.byte_length > len(buffer) {
        return nil, "A glTF buffer view is out of range."
    }
    return buffer[view.byte_offset:view.byte_offset + view.byte_length], ""
}

@(private="file")
gltf_is_child :: proc(doc: ^Doc, node: int) -> bool {
    for other in doc.nodes {
        for child in other.children do if child == node do return true
    }
    return false
}

@(private="file")
gltf_node_matrix :: proc(node: Doc_Node) -> alg.Matrix4f32 {
    if m, ok := node.matrix_.?; ok {
        // glTF stores matrices column by column.
        result: alg.Matrix4f32
        for column in 0..<4 do for row in 0..<4 do result[row, column] = m[column * 4 + row]
        return result
    }
    t := node.translation.? or_else {0, 0, 0}
    r := node.rotation.? or_else {0, 0, 0, 1}
    s := node.scale.? or_else {1, 1, 1}
    rotation := alg.matrix4_from_quaternion(quaternion(w = r[3], x = r[0], y = r[1], z = r[2]))
    return alg.matrix4_translate_f32(t) * rotation * alg.matrix4_scale_f32(s)
}

// Adds a node's primitives to the flattened model and the node to the tree,
// then its children. `parent` is the parent's model-space matrix (glTF's
// right-handed space); `parent_entity` is the parent node's placement as an
// entity would have it (left-handed, never mirroring).
@(private="file")
gltf_visit_node :: proc(
    loader: ^Gltf_Loader, node_index: int, parent, parent_entity: alg.Matrix4f32,
    parent_out, depth: int,
) -> string {
    doc := loader.doc
    if node_index < 0 || node_index >= len(doc.nodes) do return "Invalid glTF node index."
    if depth > 64 do return "The glTF node hierarchy is too deep (or cyclic)."
    node := doc.nodes[node_index]
    world := parent * gltf_node_matrix(node)

    // Left-handed: Z is negated on both sides (flip * world * flip). An
    // entity's scale stays positive, so a mirroring node keeps a mirror (in
    // X) for its part to undo: entity * mirror * mirrored part = the node.
    flip_z := alg.matrix4_scale_f32({1, 1, -1})
    mirror_x := alg.matrix4_scale_f32({-1, 1, 1})
    mirrored := alg.determinant(alg.Matrix3f32(world)) < 0
    entity := flip_z * world * flip_z
    if mirrored do entity = entity * mirror_x
    out := Gltf_Node{
        name = node.name,
        parent = parent_out,
        local = alg.matrix4_inverse_f32(parent_entity) * entity,
        part = -1,
    }

    if mesh_index, has_mesh := node.mesh.?; has_mesh {
        if mesh_index < 0 || mesh_index >= len(doc.meshes) do return "Invalid glTF mesh index."
        for primitive in doc.meshes[mesh_index].primitives {
            if error := gltf_add_primitive(loader, primitive, world, &loader.primitives); error != "" do return error
        }
        part, error := gltf_node_part(loader, mesh_index, mirrored, node.name)
        if error != "" do return error
        out.part = part
    }
    if out.name == "" do out.name = fmt.tprintf("Node %d", node_index)
    index := len(loader.nodes)
    append(&loader.nodes, out)

    for child in node.children {
        if error := gltf_visit_node(loader, child, world, entity, index, depth + 1); error != "" do return error
    }
    return ""
}

// The part drawing a glTF mesh in its own space, mirrored or not; parts are
// shared by every node that draws the same mesh.
@(private="file")
gltf_node_part :: proc(loader: ^Gltf_Loader, mesh_index: int, mirrored: bool, node_name: string) -> (part: int, error: string) {
    key := [2]int{mesh_index, int(mirrored)}
    if existing, found := loader.part_of_mesh[key]; found do return existing, ""

    mesh := loader.doc.meshes[mesh_index]
    result := Gltf_Loader_Part{
        name = mesh.name if mesh.name != "" else node_name,
        mesh_index = mesh_index,
        mirrored = mirrored,
        primitives = make([dynamic]Gltf_Primitive_Out, context.temp_allocator),
    }
    if result.name == "" do result.name = fmt.tprintf("Mesh %d", mesh_index)
    basis := alg.matrix4_scale_f32({-1, 1, 1}) if mirrored else alg.MATRIX4F32_IDENTITY
    for primitive in mesh.primitives {
        if error = gltf_add_primitive(loader, primitive, basis, &result.primitives); error != "" do return
    }
    part = -1
    if len(result.primitives) > 0 {
        part = len(loader.parts)
        append(&loader.parts, result)
    }
    loader.part_of_mesh[key] = part
    return part, ""
}

@(private="file")
gltf_component_size :: proc(component_type: int) -> int {
    switch component_type {
        case 5120, 5121: return 1 // BYTE, UNSIGNED_BYTE
        case 5122, 5123: return 2 // SHORT, UNSIGNED_SHORT
        case 5125, 5126: return 4 // UNSIGNED_INT, FLOAT
    }
    return 0
}

@(private="file")
gltf_component_count :: proc(kind: string) -> int {
    switch kind {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
    }
    return 0
}

// The bytes of one accessor and how to step through them.
@(private="file")
Gltf_Accessor_Data :: struct {
    bytes: []u8,
    stride, count, components, component_type: int,
    normalized: bool,
}

@(private="file")
gltf_accessor :: proc(loader: ^Gltf_Loader, index: int) -> (data: Gltf_Accessor_Data, error: string) {
    doc := loader.doc
    if index < 0 || index >= len(doc.accessors) do return {}, "Invalid glTF accessor index."
    accessor := doc.accessors[index]
    if _, sparse := accessor.sparse.?; sparse do return {}, "Sparse glTF accessors are not supported."
    view_index, has_view := accessor.buffer_view.?
    if !has_view do return {}, "glTF accessors without buffer views are not supported."

    view_bytes: []u8
    view_bytes, error = gltf_buffer_view_bytes(doc, loader.buffers, view_index)
    if error != "" do return
    data.components = gltf_component_count(accessor.kind)
    component_size := gltf_component_size(accessor.component_type)
    if data.components == 0 || component_size == 0 do return {}, "Unsupported glTF accessor type."
    element_size := data.components * component_size
    data.stride = doc.buffer_views[view_index].byte_stride
    if data.stride == 0 do data.stride = element_size
    data.count = accessor.count
    data.component_type = accessor.component_type
    data.normalized = accessor.normalized

    if accessor.count > 0 {
        end := accessor.byte_offset + (accessor.count - 1) * data.stride + element_size
        if accessor.byte_offset < 0 || end > len(view_bytes) do return {}, "A glTF accessor reads past its buffer view."
        data.bytes = view_bytes[accessor.byte_offset:end]
    }
    return
}

// One component as a float; normalized integers map to [0, 1] or [-1, 1].
@(private="file")
gltf_read_component :: proc(data: Gltf_Accessor_Data, element, component: int) -> f32 {
    offset := element * data.stride + component * gltf_component_size(data.component_type)
    p := rawptr(&data.bytes[offset])
    switch data.component_type {
        case 5126: return f32((^f32le)(p)^)
        case 5121:
            v := f32((^u8)(p)^)
            return v / 255 if data.normalized else v
        case 5123:
            v := f32((^u16le)(p)^)
            return v / 65535 if data.normalized else v
        case 5120:
            v := f32((^i8)(p)^)
            return max(v / 127, -1) if data.normalized else v
        case 5122:
            v := f32((^i16le)(p)^)
            return max(v / 32767, -1) if data.normalized else v
        case 5125: return f32((^u32le)(p)^)
    }
    return 0
}

@(private="file")
gltf_add_primitive :: proc(loader: ^Gltf_Loader, primitive: Doc_Primitive, world: alg.Matrix4f32, out: ^[dynamic]Gltf_Primitive_Out) -> string {
    if mode := primitive.mode.? or_else 4; mode != 4 {
        // Once, for the flattened model; parts see the same primitives again.
        if out == &loader.primitives {
            append(&loader.warnings, fmt.tprintf("Skipped a primitive with draw mode %d (only triangles are supported).", mode))
        }
        return ""
    }

    position_index, has_position := primitive.attributes["POSITION"]
    if !has_position do return "A glTF primitive has no positions."
    positions, error := gltf_accessor(loader, position_index)
    if error != "" do return error
    if positions.components != 3 || positions.component_type != 5126 do return "glTF positions must be float VEC3."
    vertex_count := positions.count

    normals, texcoords, tangents: Gltf_Accessor_Data
    if index, ok := primitive.attributes["NORMAL"]; ok {
        normals, error = gltf_accessor(loader, index)
        if error != "" do return error
        if normals.components != 3 || normals.count != vertex_count do return "Invalid glTF normals."
    }
    if index, ok := primitive.attributes["TEXCOORD_0"]; ok {
        texcoords, error = gltf_accessor(loader, index)
        if error != "" do return error
        if texcoords.components != 2 || texcoords.count != vertex_count do return "Invalid glTF texture coordinates."
    }
    if index, ok := primitive.attributes["TANGENT"]; ok {
        tangents, error = gltf_accessor(loader, index)
        if error != "" do return error
        if tangents.components != 4 || tangents.count != vertex_count do return "Invalid glTF tangents."
    }

    // Normals use the inverse transpose; a mirroring transform (negative
    // determinant) reverses the winding and the tangent handedness.
    normal_matrix := alg.transpose(alg.inverse(alg.Matrix3f32(world)))
    determinant := alg.determinant(alg.Matrix3f32(world))
    mirrored := determinant < 0

    vertices := make([]Vertex, vertex_count, context.temp_allocator)
    for v in 0..<vertex_count {
        p := [3]f32{gltf_read_component(positions, v, 0), gltf_read_component(positions, v, 1), gltf_read_component(positions, v, 2)}
        world_p := alg.mul(world, alg.Vector4f32{p.x, p.y, p.z, 1})
        vertex := &vertices[v]
        // Right-handed to left-handed: negate Z.
        vertex.position = {world_p.x, world_p.y, -world_p.z}

        if normals.count > 0 {
            n := alg.normalize(normal_matrix * alg.Vector3f32{
                gltf_read_component(normals, v, 0), gltf_read_component(normals, v, 1), gltf_read_component(normals, v, 2),
            })
            vertex.normal = {n.x, n.y, -n.z}
        }
        if texcoords.count > 0 {
            // glTF and D3D both put the UV origin at the top left.
            vertex.texcoord = {gltf_read_component(texcoords, v, 0), gltf_read_component(texcoords, v, 1)}
        }
        if tangents.count > 0 {
            t := alg.normalize(alg.Matrix3f32(world) * alg.Vector3f32{
                gltf_read_component(tangents, v, 0), gltf_read_component(tangents, v, 1), gltf_read_component(tangents, v, 2),
            })
            w := gltf_read_component(tangents, v, 3)
            if mirrored do w = -w
            // The Z negation is itself a mirror, so the handedness flips too.
            vertex.tangent = {t.x, t.y, -t.z, -w}
        }
    }

    indices: []u32
    if index_accessor, has_indices := primitive.indices.?; has_indices {
        data: Gltf_Accessor_Data
        data, error = gltf_accessor(loader, index_accessor)
        if error != "" do return error
        if data.components != 1 || (data.component_type != 5121 && data.component_type != 5123 && data.component_type != 5125) {
            return "glTF indices must be unsigned integer scalars."
        }
        indices = make([]u32, data.count, context.temp_allocator)
        for i in 0..<data.count {
            index := u32(gltf_read_component(data, i, 0))
            if int(index) >= vertex_count do return "A glTF index is out of range."
            indices[i] = index
        }
    } else {
        indices = make([]u32, vertex_count, context.temp_allocator)
        for i in 0..<vertex_count do indices[i] = u32(i)
    }
    if len(indices) < 3 || len(indices) % 3 != 0 do return ""

    // Negating Z keeps a triangle's screen-space order (a left-handed camera
    // looking down +Z still has +X to its right), so glTF's counter-clockwise
    // front faces must be swapped to D3D's clockwise ones. A mirroring node
    // transform has already reversed them, cancelling the swap.
    if !mirrored {
        for triangle in 0..<len(indices) / 3 {
            indices[triangle * 3 + 1], indices[triangle * 3 + 2] = indices[triangle * 3 + 2], indices[triangle * 3 + 1]
        }
    }

    if normals.count == 0 do gltf_compute_normals(vertices, indices)
    if tangents.count == 0 {
        mesh_generate_tangents({vertices = vertices, indices = indices})
        // Generated tangents follow +V; glTF normal maps' green channel points
        // toward -V (image "up", since V grows downward).
        for &vertex in vertices do vertex.tangent.w = -vertex.tangent.w
    }

    material := primitive.material.? or_else -1
    slot, has_slot := loader.slot_of_material[material]
    if !has_slot {
        slot = len(loader.slot_materials)
        loader.slot_of_material[material] = slot
        append(&loader.slot_materials, material)
    }
    append(out, Gltf_Primitive_Out{vertices = vertices, indices = indices, slot = slot})
    return ""
}

// Area-weighted smooth normals for primitives that come without any.
@(private="file")
gltf_compute_normals :: proc(vertices: []Vertex, indices: []u32) {
    for triangle in 0..<len(indices) / 3 {
        a := indices[triangle * 3]
        b := indices[triangle * 3 + 1]
        c := indices[triangle * 3 + 2]
        pa := alg.Vector3f32(vertices[a].position)
        // Clockwise front faces in this left-handed space.
        n := alg.cross(alg.Vector3f32(vertices[b].position) - pa, alg.Vector3f32(vertices[c].position) - pa)
        for i in ([3]u32{a, b, c}) do vertices[i].normal += n
    }
    for &vertex in vertices {
        n := alg.Vector3f32(vertex.normal)
        vertex.normal = alg.normalize(n) if alg.dot(n, n) > 0 else {0, 1, 0}
    }
}

// Concatenates primitives grouped by material slot: one submesh per slot
// they use.
@(private="file")
gltf_merge_by_slot :: proc(primitives: []Gltf_Primitive_Out, slot_count: int, allocator := context.allocator) -> MeshData {
    vertex_total, index_total := 0, 0
    for primitive in primitives {
        vertex_total += len(primitive.vertices)
        index_total += len(primitive.indices)
    }

    vertices := make([]Vertex, vertex_total, allocator)
    indices := make([]u32, index_total, allocator)
    submeshes := make([dynamic]Submesh, 0, slot_count, allocator)
    vertex_at, index_at := 0, 0
    for slot in 0..<slot_count {
        first_index := index_at
        for primitive in primitives {
            if primitive.slot != slot do continue
            copy(vertices[vertex_at:], primitive.vertices)
            for index, i in primitive.indices do indices[index_at + i] = index + u32(vertex_at)
            vertex_at += len(primitive.vertices)
            index_at += len(primitive.indices)
        }
        if index_at == first_index do continue
        append(&submeshes, Submesh{
            first_index = u32(first_index),
            index_count = u32(index_at - first_index),
            material_slot = u32(slot),
        })
    }

    mesh := MeshData{vertices = vertices, indices = indices, submeshes = submeshes[:]}
    mesh_compute_submesh_bounds(mesh)
    return mesh
}

@(private="file")
gltf_convert_material :: proc(doc: ^Doc, index: int) -> Gltf_Material {
    // The glTF default material: white, fully metallic and rough.
    result := Gltf_Material{
        name = "Default",
        base_color = {1, 1, 1, 1},
        metallic = 1,
        roughness = 1,
        normal_scale = 1,
        base_color_image = -1,
        metallic_roughness_image = -1,
        normal_image = -1,
        emissive_strength = 1,
        occlusion_strength = 1,
        alpha_cutoff = 0.5,
        emissive_image = -1,
        occlusion_image = -1,
        alpha_mode = "OPAQUE",
    }
    if index < 0 || index >= len(doc.materials) do return result

    material := doc.materials[index]
    result.name = material.name if material.name != "" else fmt.tprintf("Material %d", index)
    if material.alpha_mode != "" do result.alpha_mode = material.alpha_mode
    result.alpha_cutoff = material.alpha_cutoff.? or_else 0.5
    result.double_sided = material.double_sided
    result.emissive = material.emissive_factor.? or_else {}
    if extension, ok := material.extensions.emissive_strength.?; ok {
        result.emissive_strength = extension.value.? or_else 1
    }
    result.base_color = material.pbr.base_color_factor.? or_else result.base_color
    result.metallic = material.pbr.metallic_factor.? or_else 1
    result.roughness = material.pbr.roughness_factor.? or_else 1

    image_of :: proc(doc: ^Doc, ref: Doc_Texture_Ref) -> int {
        if ref.index < 0 || ref.index >= len(doc.textures) do return -1
        source := doc.textures[ref.index].source.? or_else -1
        return source if source >= 0 && source < len(doc.images) else -1
    }
    if ref, ok := material.pbr.base_color_texture.?; ok do result.base_color_image = image_of(doc, ref)
    if ref, ok := material.pbr.metallic_roughness_texture.?; ok do result.metallic_roughness_image = image_of(doc, ref)
    if ref, ok := material.normal_texture.?; ok {
        result.normal_image = image_of(doc, ref)
        result.normal_scale = ref.scale.? or_else 1
    }
    if ref, ok := material.emissive_texture.?; ok do result.emissive_image = image_of(doc, ref)
    if ref, ok := material.occlusion_texture.?; ok {
        result.occlusion_image = image_of(doc, ref)
        result.occlusion_strength = ref.strength.? or_else 1
    }
    return result
}
