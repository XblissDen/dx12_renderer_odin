package main

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:image"
import "core:image/png"

MeshHandle :: distinct u32
TextureHandle :: distinct u32
TextureUsage :: enum {albedo, normal, roughness, metallic, data}
TextureSource :: enum {file, checkerboard, solid}
MeshImport :: struct {flip_v: bool}
TextureImport :: struct {flip_green: bool}

AssetMaterial :: struct {
    albedo, normal, roughness_map, metallic_map: string,
    // Optional factors: omitted values get defaults; an explicit zero stays zero.
    roughness, metallic, normal_strength, uv_scale: Maybe(f32),
}
MeshDesc :: struct {
    id, name, path: string,
    settings: MeshImport `json:"import"`,
    material: AssetMaterial,
}
TextureDesc :: struct {
    id, name, path: string,
    usage: TextureUsage,
    source: TextureSource,
    settings: TextureImport `json:"import"`,
    width, height, tile_size: u32,
    color: [4]u8,
}
AssetManifest :: struct {version: u32, models: []MeshDesc, textures: []TextureDesc}
MeshAsset :: struct {desc: MeshDesc, label: cstring, data: MeshData, bounds: MeshBounds, material: Material}
TextureAsset :: struct {desc: TextureDesc, label: cstring, hidden: bool}
AssetRegistry :: struct {
    arena: mem.Dynamic_Arena,
    active: bool,
    meshes: [dynamic]MeshAsset,
    textures: [dynamic]TextureAsset,
    mesh_ids: map[string]MeshHandle,
    texture_ids: map[string]TextureHandle,
    white, flat_normal, one: TextureHandle,
}
g_assets: AssetRegistry

assets_mesh_valid :: proc(h: MeshHandle) -> bool {return h != 0 && int(h) < len(g_assets.meshes)}
assets_texture_valid :: proc(h: TextureHandle) -> bool {return h != 0 && int(h) < len(g_assets.textures)}
assets_optional_texture_valid :: proc(h: TextureHandle) -> bool {return h == 0 || assets_texture_valid(h)}
assets_mesh :: proc(id: string) -> MeshHandle {return g_assets.mesh_ids[id]}
assets_texture :: proc(id: string) -> TextureHandle {return g_assets.texture_ids[id]}
assets_mesh_id :: proc(h: MeshHandle) -> string {return g_assets.meshes[h].desc.id if assets_mesh_valid(h) else ""}
assets_texture_id :: proc(h: TextureHandle) -> string {return g_assets.textures[h].desc.id if assets_texture_valid(h) else ""}
assets_texture_usage :: proc(h: TextureHandle, usage: TextureUsage) -> bool {
    return assets_texture_valid(h) && g_assets.textures[h].desc.usage == usage
}
texture_asset_is_albedo :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .albedo)}
texture_asset_is_normal :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .normal)}
texture_asset_is_roughness :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .roughness)}
texture_asset_is_metallic :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .metallic)}

assets_label :: proc(name, id: string) -> cstring {
    text := name if len(name) > 0 else id
    return strings.clone_to_cstring(text, mem.dynamic_arena_allocator(&g_assets.arena)) or_else panic("Asset label allocation failed")
}

assets_register_texture :: proc(desc: TextureDesc, hidden := false) -> TextureHandle {
    handle := TextureHandle(len(g_assets.textures))
    append(&g_assets.textures, TextureAsset{desc = desc, label = assets_label(desc.name, desc.id), hidden = hidden})
    g_assets.texture_ids[desc.id] = handle
    return handle
}

assets_material :: proc(desc: AssetMaterial) -> (material: Material, ok: bool) {
    material = {tint = {1, 1, 1}, texture = g_assets.white, roughness = 0.8, uv_scale = 1}
    if desc.albedo != "" {
        material.texture = assets_texture(desc.albedo)
        if !texture_asset_is_albedo(material.texture) do return {}, false
    }
    roughness, has_roughness := desc.roughness.(f32)
    metallic, has_metallic := desc.metallic.(f32)
    normal_strength, has_normal_strength := desc.normal_strength.(f32)
    uv_scale, has_uv_scale := desc.uv_scale.(f32)
    if has_roughness do material.roughness = roughness
    if has_metallic do material.metallic = metallic
    if has_uv_scale do material.uv_scale = uv_scale
    if desc.normal != "" {
        material.normal_texture = assets_texture(desc.normal)
        if !texture_asset_is_normal(material.normal_texture) do return {}, false
        material.normal_strength = normal_strength if has_normal_strength else 1
    }
    if desc.roughness_map != "" {
        material.roughness_texture = assets_texture(desc.roughness_map)
        if !texture_asset_is_roughness(material.roughness_texture) do return {}, false
        material.use_roughness_map = true
        if !has_roughness do material.roughness = 1
    }
    if desc.metallic_map != "" {
        material.metallic_texture = assets_texture(desc.metallic_map)
        if !texture_asset_is_metallic(material.metallic_texture) do return {}, false
        material.use_metallic_map = true
        if !has_metallic do material.metallic = 1
    }
    if !(material.roughness >= 0 && material.roughness <= 1) ||
       !(material.metallic >= 0 && material.metallic <= 1) ||
       !(material.normal_strength >= 0) || !(material.uv_scale > 0) {
        return {}, false
    }
    return material, true
}

assets_destroy :: proc() {
    for asset in g_assets.meshes {
        delete(asset.data.vertices)
        delete(asset.data.indices)
    }
    delete(g_assets.meshes)
    delete(g_assets.textures)
    delete(g_assets.mesh_ids)
    delete(g_assets.texture_ids)
    if g_assets.active do mem.dynamic_arena_destroy(&g_assets.arena)
    g_assets = {}
    delete(g_asset_marshalers)
    delete(g_asset_unmarshalers)
    g_asset_marshalers = {}
    g_asset_unmarshalers = {}
}

assets_init :: proc(path: string) -> (message: string) {
    assert(!g_assets.active)
    mem.dynamic_arena_init(&g_assets.arena)
    g_assets.active = true
    defer if message != "" do assets_destroy()
    allocator := mem.dynamic_arena_allocator(&g_assets.arena)
    data, error := os.read_entire_file(path, context.temp_allocator)
    if error != nil do return "Cannot read asset catalog."
    if !json.is_valid(data, .JSON, true) do return "Invalid asset catalog JSON."
    manifest: AssetManifest
    decode_error := json.unmarshal(data, &manifest, allocator = allocator)
    if decode_error != nil || manifest.version != 1 {
        fmt.eprintln("Asset catalog:", decode_error)
        return "Invalid asset catalog/version."
    }
    append(&g_assets.meshes, MeshAsset{}) // Zero is an invalid handle.
    append(&g_assets.textures, TextureAsset{})
    g_assets.white = assets_register_texture({id = "builtin.white", usage = .albedo, source = .solid, width = 1, height = 1, color = {255,255,255,255}}, true)
    g_assets.flat_normal = assets_register_texture({id = "builtin.normal", usage = .normal, source = .solid, width = 1, height = 1, color = {128,128,255,255}}, true)
    g_assets.one = assets_register_texture({id = "builtin.one", usage = .data, source = .solid, width = 1, height = 1, color = {255,255,255,255}}, true)
    for desc in manifest.textures {
        if desc.id == "" || assets_texture(desc.id) != 0 do return "Empty/duplicate texture asset ID."
        if desc.source == .file && desc.path == "" do return "A file texture needs a path."
        if desc.source != .file && (desc.width == 0 || desc.height == 0 || u64(desc.width) * u64(desc.height) > u64(image.MAX_DIMENSIONS)) do return "Invalid generated texture dimensions."
        if desc.source == .checkerboard && desc.tile_size == 0 do return "Checkerboard needs a tile size."
        assets_register_texture(desc)
    }
    for desc in manifest.models {
        if desc.id == "" || desc.path == "" || assets_mesh(desc.id) != 0 do return "Empty/duplicate model ID or missing path."
        mesh, ok := mesh_load_obj(desc.path, flip_v = desc.settings.flip_v)
        if !ok do return "Failed to import model."
        material, material_ok := assets_material(desc.material)
        if !material_ok {
            delete(mesh.vertices); delete(mesh.indices)
            return "Invalid model default material reference."
        }
        bounds := mesh_compute_bounds(mesh)
        if !bounds.valid {
            delete(mesh.vertices); delete(mesh.indices)
            return "Model has no geometry."
        }
        handle := MeshHandle(len(g_assets.meshes))
        append(&g_assets.meshes, MeshAsset{desc = desc, label = assets_label(desc.name, desc.id), data = mesh, bounds = bounds, material = material})
        g_assets.mesh_ids[desc.id] = handle
    }
    assets_json_init()
    return ""
}

// Return owned RGBA8 pixels to the startup uploader, including generated assets.
assets_texture_pixels :: proc(desc: TextureDesc, allocator := context.allocator) -> (pixels: []u8, width, height: u32) {
    if desc.source != .file {
        width, height = desc.width, desc.height
        pixels = make([]u8, int(width * height) * 4, allocator)
        for y in 0..<height {
            for x in 0..<width {
                color := desc.color
                if desc.source == .checkerboard {
                    color = {240,240,240,255} if ((x / desc.tile_size + y / desc.tile_size) % 2) == 0 else {35,55,100,255}
                }
                for c in 0..<4 do pixels[int((y * width + x) * 4) + c] = color[c]
            }
        }
        return
    }
    img, err := image.load_from_file(desc.path, {.alpha_add_if_missing})
    if err != nil do fmt.panicf("Texture import failed: %s: %v", desc.path, err)
    defer image.destroy(img)
    assert(img.channels == 4 && (img.depth == 8 || img.depth == 16))
    width, height = u32(img.width), u32(img.height)
    pixels = make([]u8, int(width * height) * 4, allocator)
    if img.depth == 16 {
        source := ([^]u16)(raw_data(img.pixels.buf[:]))
        for i in 0..<len(pixels) do pixels[i] = u8((u32(source[i]) + 128) / 257)
    } else {
        copy(pixels, img.pixels.buf[:])
    }
    if desc.settings.flip_green {
        for pixel in 0..<int(width * height) do pixels[pixel * 4 + 1] = 255 - pixels[pixel * 4 + 1]
    }
    return
}

g_asset_marshalers: map[typeid]json.User_Marshaler
g_asset_unmarshalers: map[typeid]json.User_Unmarshaler
g_asset_json_installed: bool
g_asset_read_legacy: bool

assets_json_init :: proc() {
    if !g_asset_json_installed {
        json.set_user_marshalers(&g_asset_marshalers)
        json.set_user_unmarshalers(&g_asset_unmarshalers)
        g_asset_json_installed = true
    }
    g_asset_marshalers[typeid_of(MeshHandle)] = assets_marshal_mesh
    g_asset_marshalers[typeid_of(TextureHandle)] = assets_marshal_texture
    g_asset_unmarshalers[typeid_of(MeshHandle)] = assets_unmarshal_mesh
    g_asset_unmarshalers[typeid_of(TextureHandle)] = assets_unmarshal_texture
}
assets_marshal_mesh :: proc(w: io.Writer, value: any, options: ^json.Marshal_Options) -> json.Marshal_Error {
    h := value.(MeshHandle)
    if h != 0 && !assets_mesh_valid(h) do return json.Marshal_Data_Error.Unsupported_Type
    return json.marshal_to_writer(w, assets_mesh_id(h), options)
}
assets_marshal_texture :: proc(w: io.Writer, value: any, options: ^json.Marshal_Options) -> json.Marshal_Error {
    h := value.(TextureHandle)
    if h != 0 && !assets_texture_valid(h) do return json.Marshal_Data_Error.Unsupported_Type
    return json.marshal_to_writer(w, assets_texture_id(h), options)
}
assets_legacy_mesh_id :: proc(id: string) -> string {
    switch id {case "Cube": return "cube"; case "Pyramid": return "pyramid"; case "Barrel": return "barrel"}
    return id
}
assets_legacy_texture_id :: proc(id: string) -> string {
    switch id {
        case "Portrait": return "portrait"
        case "Checkerboard": return "checkerboard"
        case "Stone_Albedo": return "stone.albedo"
        case "Stone_Normal": return "stone.normal"
        case "Stone_Roughness": return "stone.roughness"
        case "Barrel_Albedo": return "barrel.albedo"
        case "Barrel_Normal": return "barrel.normal"
        case "Barrel_Roughness": return "barrel.roughness"
        case "Barrel_Metallic": return "barrel.metallic"
    }
    return id
}
assets_unmarshal_mesh :: proc(parser: ^json.Parser, value: any) -> json.Unmarshal_Error {
    token := json.parse_value(parser) or_return
    id, ok := token.(string)
    if !ok do return json.Unmarshal_Data_Error.Invalid_Data
    if g_asset_read_legacy do id = assets_legacy_mesh_id(id)
    handle := assets_mesh(id)
    if id != "" && handle == 0 do return json.Unmarshal_Data_Error.Invalid_Data
    (^MeshHandle)(value.data)^ = handle
    return nil
}
assets_unmarshal_texture :: proc(parser: ^json.Parser, value: any) -> json.Unmarshal_Error {
    token := json.parse_value(parser) or_return
    id, ok := token.(string)
    if !ok do return json.Unmarshal_Data_Error.Invalid_Data
    if g_asset_read_legacy do id = assets_legacy_texture_id(id)
    handle := assets_texture(id)
    if id != "" && handle == 0 do return json.Unmarshal_Data_Error.Invalid_Data
    (^TextureHandle)(value.data)^ = handle
    return nil
}