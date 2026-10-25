package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:image"
import c "core:c"
import stbi "vendor:stb/image"

MeshHandle :: distinct u32
TextureHandle :: distinct u32
EnvironmentHandle :: distinct u32
// Emissive maps are sRGB color like albedo; occlusion maps are linear data.
TextureUsage :: enum {albedo, normal, roughness, metallic, emissive, occlusion, data}
TextureSource :: enum {file, checkerboard, solid}
MeshImport :: struct {flip_v: bool}
TextureImport :: struct {
    flip_green: bool,
    // Use one channel (0-3) of the image as gray, e.g. roughness (1) or
    // metallic (2) from a glTF occlusion-roughness-metallic texture.
    channel: Maybe(int),
}

AssetMaterial :: struct {
    name: string,
    albedo, normal, roughness_map, metallic_map, emissive_map, occlusion_map: string,
    // Optional factors: omitted values get defaults; an explicit zero stays zero.
    roughness, metallic, normal_strength, uv_scale: Maybe(f32),
    emissive_strength, occlusion_strength, alpha_cutoff, transparency: Maybe(f32),
    tint, emissive: Maybe([3]f32),
    alpha_mask, alpha_blend, double_sided: bool,
}
MeshDesc :: struct {
    id, name, path: string,
    settings: MeshImport `json:"import"`,
    // Single-material models (OBJ) use `material`. Multi-material models
    // (glTF) list one entry per submesh material slot in `materials` instead.
    material: AssetMaterial,
    materials: []AssetMaterial,
}
TextureDesc :: struct {
    id, name, path: string,
    usage: TextureUsage,
    source: TextureSource,
    settings: TextureImport `json:"import"`,
    width, height, tile_size: u32,
    color: [4]u8,
}
EnvironmentDesc :: struct {id, name, path: string}
EnvironmentAsset :: struct {desc: EnvironmentDesc, label: cstring}
AssetManifest :: struct {
    version: u32,
    models: []MeshDesc,
    textures: []TextureDesc,
    environments: []EnvironmentDesc,
    default_environment: string,
}
MeshAsset :: struct {
    desc: MeshDesc,
    label: cstring,
    data: MeshData,
    bounds: MeshBounds,
    // Default materials for new entities: slot 0, then the rest.
    material: Material,
    material_slots: MaterialSlots,
    material_names: [MAX_MODEL_MATERIALS]cstring,
}
TextureAsset :: struct {desc: TextureDesc, label: cstring, hidden: bool}
AssetRegistry :: struct {
    arena: mem.Dynamic_Arena,
    active: bool,
    catalog_path, catalog_text: string,
    import_arenas: [dynamic]mem.Dynamic_Arena,
    meshes: [dynamic]MeshAsset,
    textures: [dynamic]TextureAsset,
    environments: [dynamic]EnvironmentAsset,
    mesh_ids: map[string]MeshHandle,
    texture_ids: map[string]TextureHandle,
    environment_ids: map[string]EnvironmentHandle,
    default_environment: EnvironmentHandle,
    white, flat_normal, one: TextureHandle,
}
g_assets: AssetRegistry

AssetImportRequest :: struct {
    model: bool,
    path, name: string,
    usage: TextureUsage,
    flip_v, flip_green: bool,
    material: AssetMaterial,
}

assets_clone_import :: proc(value: $T, allocator: mem.Allocator) -> T {
    bytes, error := json.marshal(value, {use_enum_names = true})
    assert(error == nil)
    defer delete(bytes)
    result: T
    assert(json.unmarshal(bytes, &result, allocator = allocator) == nil)
    return result
}

assets_prepare_catalog :: proc(
    model: ^MeshDesc = nil,
    texture: ^TextureDesc = nil,
    extra_textures: []TextureDesc = nil,
) -> (path, contents: string, ok: bool) {
    manifest := AssetManifest{version = 1}
    models := make([dynamic]MeshDesc, context.temp_allocator)
    textures := make([dynamic]TextureDesc, context.temp_allocator)
    environments := make([dynamic]EnvironmentDesc, context.temp_allocator)
    for asset in g_assets.meshes[1:] do append(&models, asset.desc)
    for asset in g_assets.textures[1:] {
        if !asset.hidden do append(&textures, asset.desc)
    }
    if model != nil do append(&models, model^)
    if texture != nil do append(&textures, texture^)
    for desc in extra_textures do append(&textures, desc)
    manifest.models, manifest.textures = models[:], textures[:]
    for asset in g_assets.environments[1:] do append(&environments, asset.desc)
    manifest.environments = environments[:]
    manifest.default_environment = assets_environment_id(g_assets.default_environment)
    bytes, error := json.marshal(manifest, {
        pretty = true, use_spaces = true, spaces = 2, use_enum_names = true,
    }, context.temp_allocator)
    if error != nil do return "", "", false
    contents = string(bytes)
    directory := os.dir(g_assets.catalog_path)
    if directory == "" do directory = "."
    file, file_error := os.create_temp_file(directory, "assets-*.tmp")
    if file_error != nil do return "", "", false
    path = strings.clone(os.name(file), context.temp_allocator) or_else panic("Temporary path allocation failed")
    count, write_error := os.write(file, bytes)
    sync_error := os.sync(file)
    close_error := os.close(file)
    ok = write_error == nil && sync_error == nil && close_error == nil && count == len(bytes)
    if !ok do os.remove(path)
    return
}

assets_import_id :: proc(source: string, model: bool, usage: TextureUsage) -> (id, destination: string) {
    slug := make([dynamic]u8, context.temp_allocator)
    for byte in transmute([]u8)os.stem(source) {
        c := byte
        if c >= 'A' && c <= 'Z' do c += 'a' - 'A'
        valid := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
        append(&slug, c if valid else u8('_'))
    }
    if len(slug) == 0 do append(&slug, 'a')
    prefix := "model" if model else fmt.tprintf("texture.%v", usage)
    directory := "models/imported" if model else "textures/imported"
    extension := strings.to_lower(os.ext(source), context.temp_allocator)
    for number := 0; ; number += 1 {
        suffix := "" if number == 0 else fmt.tprintf(".%d", number)
        id = fmt.tprintf("%s.%s%s", prefix, string(slug[:]), suffix)
        destination = fmt.tprintf("%s/%s%s", directory, id, extension)
        if assets_mesh(id) == 0 && assets_texture(id) == 0 && !os.exists(destination) do return
    }
}

// Process imports between UI construction and renderer_begin_frame.
assets_is_gltf_path :: proc(path: string) -> bool {
    extension := os.ext(path)
    return strings.equal_fold(extension, ".gltf") || strings.equal_fold(extension, ".glb")
}

assets_import :: proc(request: AssetImportRequest) -> (model: MeshHandle, texture: TextureHandle, message: string) {
    if request.path == "" do return 0, 0, "Choose a source file."
    if request.model && assets_is_gltf_path(request.path) {
        model, message = assets_import_gltf(request)
        return model, 0, message
    }
    extension := os.ext(request.path)
    valid_extension := strings.equal_fold(extension, ".obj") if request.model else
        strings.equal_fold(extension, ".png") || strings.equal_fold(extension, ".jpg") || strings.equal_fold(extension, ".jpeg")
    if !valid_extension do return 0, 0, "Choose an OBJ/glTF model or a PNG/JPEG texture."
    if !request.model && g_renderer.srv_next >= SRV_HEAP_CAPACITY do return 0, 0, "The texture descriptor heap is full."

    scratch, owner: mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
    mem.dynamic_arena_init(&owner)
    committed := false
    defer if !committed do mem.dynamic_arena_destroy(&owner)
    allocator := mem.dynamic_arena_allocator(&owner)
    id, destination := assets_import_id(request.path, request.model, request.usage)
    if os.make_directory_all(os.dir(destination)) != nil do return 0, 0, "Cannot create the project import folder."
    defer if !committed do os.remove(destination)
    if os.copy_file(destination, request.path) != nil do return 0, 0, "Could not copy the source file into the project."
    name := strings.trim_space(request.name)
    if name == "" do name = os.stem(request.path)

    mesh_desc: MeshDesc
    texture_desc: TextureDesc
    mesh_data: MeshData
    gpu_mesh: GpuMesh
    gpu_texture: GpuTexture
    meshes: []GpuMesh
    textures: []GpuTexture
    defer if !committed {
        delete(mesh_data.vertices)
        delete(mesh_data.indices)
        if gpu_mesh.vertex_buffer != nil do gpu_mesh.vertex_buffer->Release()
        if gpu_mesh.index_buffer != nil do gpu_mesh.index_buffer->Release()
        if gpu_texture.resource != nil do gpu_texture.resource->Release()
        delete(meshes)
        delete(textures)
    }

    pixels: []u8
    width, height: u32
    bounds: MeshBounds
    material: Material
    if request.model {
        mesh_desc = assets_clone_import(MeshDesc{
            id = id, name = name, path = destination,
            settings = {flip_v = request.flip_v}, material = request.material,
        }, allocator)
        loaded: bool
        mesh_data, loaded = mesh_load_obj(destination, flip_v = request.flip_v)
        if !loaded do return 0, 0, "Invalid or empty OBJ geometry."
        bounds = mesh_compute_bounds(mesh_data)
        material_ok: bool
        material, material_ok = assets_material(mesh_desc.material)
        if !material_ok do return 0, 0, "Invalid default material references."
    } else {
        texture_desc = assets_clone_import(TextureDesc{
            id = id, name = name, path = destination, usage = request.usage,
            settings = {flip_green = request.flip_green && request.usage == .normal},
        }, allocator)
        pixels, width, height, message = assets_try_texture_pixels(texture_desc, context.temp_allocator)
        if message != "" do return 0, 0, message
    }

    catalog_tmp, catalog_contents: string
    prepared: bool
    if request.model {
        catalog_tmp, catalog_contents, prepared = assets_prepare_catalog(model = &mesh_desc)
    } else {
        catalog_tmp, catalog_contents, prepared = assets_prepare_catalog(texture = &texture_desc)
    }
    if !prepared do return 0, 0, "Could not write the updated asset catalog."
    defer os.remove(catalog_tmp)

    // Startup uploads reuse allocator 0; drain prior frame work before using it.
    renderer_wait_for_gpu()
    if request.model {
        if renderer_upload_mesh(&gpu_mesh, mesh_data) < 0 do return 0, 0, "GPU model upload failed."
        meshes = make([]GpuMesh, len(g_renderer.meshes) + 1)
        copy(meshes, g_renderer.meshes)
        meshes[len(meshes) - 1] = gpu_mesh
    } else {
        gpu_texture.srv_index = g_renderer.srv_next
        if renderer_upload_texture(&gpu_texture, texture_desc, pixels, width, height) < 0 do return 0, 0, "GPU texture upload failed."
        textures = make([]GpuTexture, len(g_renderer.textures) + 1)
        copy(textures, g_renderer.textures)
        textures[len(textures) - 1] = gpu_texture
    }

    label := strings.clone_to_cstring(name, allocator) or_else panic("Asset label allocation failed")
    current, read_error := os.read_entire_file(g_assets.catalog_path, context.temp_allocator)
    if read_error != nil || string(current) != g_assets.catalog_text do return 0, 0, "Catalog changed on disk. Restart to load those edits before importing."
    saved_text := strings.clone(catalog_contents) or_else panic("Catalog snapshot allocation failed")
    defer if !committed do delete(saved_text)
    if os.rename(catalog_tmp, g_assets.catalog_path) != nil do return 0, 0, "Cannot replace assets.json; check whether it is writable."

    if request.model {
        model = MeshHandle(len(g_assets.meshes))
        append(&g_assets.meshes, MeshAsset{
            desc = mesh_desc, label = label, data = mesh_data, bounds = bounds, material = material,
        })
        g_assets.mesh_ids[mesh_desc.id] = model
        delete(g_renderer.meshes)
        g_renderer.meshes = meshes
    } else {
        texture = TextureHandle(len(g_assets.textures))
        append(&g_assets.textures, TextureAsset{desc = texture_desc, label = label})
        g_assets.texture_ids[texture_desc.id] = texture
        delete(g_renderer.textures)
        g_renderer.textures = textures
        g_renderer.srv_next += 1
    }
    append(&g_assets.import_arenas, owner)
    delete(g_assets.catalog_text)
    g_assets.catalog_text = saved_text
    committed = true
    return model, texture, ""
}

// Imports a .gltf/.glb, its buffers and its images into models/imported/<id>/,
// and registers the model plus one texture per (image, use) in a single
// catalog write. The packed metallic-roughness texture becomes a roughness
// texture (green channel) and a metallic texture (blue channel). Nothing is
// added, and the folder is removed again, unless every step succeeds.
assets_import_gltf :: proc(request: AssetImportRequest) -> (model: MeshHandle, message: string) {
    scratch, owner: mem.Dynamic_Arena
    mem.dynamic_arena_init(&scratch)
    defer mem.dynamic_arena_destroy(&scratch)
    context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
    mem.dynamic_arena_init(&owner)
    committed := false
    defer if !committed do mem.dynamic_arena_destroy(&owner)
    allocator := mem.dynamic_arena_allocator(&owner)

    id, _ := assets_import_id(request.path, true, .albedo)
    folder := fmt.tprintf("models/imported/%s", id)
    if os.exists(folder) do return 0, "The import folder already exists; remove it or choose another name."
    if os.make_directory_all(folder) != nil do return 0, "Cannot create the project import folder."
    // The folder did not exist before, so removing it only undoes this import.
    defer if !committed do os.remove_all(folder)

    // Copy the model and every file it references, keeping relative paths.
    external, external_error := gltf_external_files(request.path)
    if external_error != "" do return 0, external_error
    source_dir := os.dir(request.path)
    model_path := fmt.tprintf("%s/%s", folder, os.base(request.path))
    if os.copy_file(model_path, request.path) != nil do return 0, "Could not copy the model into the project."
    for relative in external {
        destination := fmt.tprintf("%s/%s", folder, relative)
        if os.make_directory_all(os.dir(destination)) != nil do return 0, "Cannot create an import subfolder."
        if os.copy_file(destination, fmt.tprintf("%s/%s", source_dir, relative)) != nil {
            return 0, fmt.tprintf("Could not copy %s; is it next to the model?", relative)
        }
    }

    gltf, load_error := gltf_load(model_path)
    if load_error != "" do return 0, load_error
    mesh_data := gltf.mesh
    defer if !committed do mesh_destroy(mesh_data)

    // Embedded images (GLB, data URIs) become files beside the model.
    image_paths := make([]string, len(gltf.images), context.temp_allocator)
    for image, i in gltf.images {
        if image.uri != "" {
            image_paths[i] = fmt.tprintf("%s/%s", folder, image.uri)
            continue
        }
        extension := ".jpg" if image.mime_type == "image/jpeg" else ".png"
        image_paths[i] = fmt.tprintf("%s/image%d%s", folder, i, extension)
        if os.write_entire_file(image_paths[i], image.data) != nil do return 0, "Could not write an embedded glTF image."
    }

    // One texture per (image, use); several materials often share an image.
    Texture_Key :: struct {image: int, usage: TextureUsage}
    texture_ids := make(map[Texture_Key]string, allocator = context.temp_allocator)
    texture_descs := make([dynamic]TextureDesc, context.temp_allocator)
    texture_id :: proc(
        image: int, usage: TextureUsage, model_id: string, image_paths: []string,
        ids: ^map[Texture_Key]string, descs: ^[dynamic]TextureDesc,
    ) -> string {
        if image < 0 do return ""
        key := Texture_Key{image, usage}
        if existing, found := ids[key]; found do return existing
        id := fmt.tprintf("%s.image%d.%v", model_id, image, usage)
        desc := TextureDesc{id = id, name = os.stem(image_paths[image]), path = image_paths[image], usage = usage, source = .file}
        // glTF packs roughness in green and metallic in blue.
        if usage == .roughness do desc.settings.channel = 1
        if usage == .metallic do desc.settings.channel = 2
        // Occlusion is red, often in that same texture.
        if usage == .occlusion do desc.settings.channel = 0
        append(descs, desc)
        ids[key] = id
        return id
    }

    materials := make([]AssetMaterial, len(gltf.materials), context.temp_allocator)
    for source, slot in gltf.materials {
        mr := source.metallic_roughness_image
        materials[slot] = AssetMaterial{
            name = source.name,
            albedo = texture_id(source.base_color_image, .albedo, id, image_paths, &texture_ids, &texture_descs),
            normal = texture_id(source.normal_image, .normal, id, image_paths, &texture_ids, &texture_descs),
            roughness_map = texture_id(mr, .roughness, id, image_paths, &texture_ids, &texture_descs),
            metallic_map = texture_id(mr, .metallic, id, image_paths, &texture_ids, &texture_descs),
            roughness = clamp(source.roughness, 0, 1),
            metallic = clamp(source.metallic, 0, 1),
            normal_strength = max(source.normal_scale, 0),
            tint = [3]f32{source.base_color.r, source.base_color.g, source.base_color.b},
            emissive_map = texture_id(source.emissive_image, .emissive, id, image_paths, &texture_ids, &texture_descs),
            occlusion_map = texture_id(source.occlusion_image, .occlusion, id, image_paths, &texture_ids, &texture_descs),
            occlusion_strength = clamp(source.occlusion_strength, 0, 1),
            alpha_mask = source.alpha_mode == "MASK",
            alpha_blend = source.alpha_mode == "BLEND",
            double_sided = source.double_sided,
        }
        if source.emissive != {} {
            materials[slot].emissive = source.emissive
            materials[slot].emissive_strength = max(source.emissive_strength, 0)
        } else if source.emissive_image >= 0 {
            // A zero factor turns the map off; keep it, but dark.
            materials[slot].emissive = [3]f32{}
        }
        if materials[slot].alpha_mask {
            // Alpha is texture alpha times the factor's; dividing the cutoff
            // by the factor gives the same test on texture alpha alone.
            factor := source.base_color.a
            materials[slot].alpha_cutoff = clamp(source.alpha_cutoff / factor, 0, 1) if factor > 0 else 1
        }
        if materials[slot].alpha_blend {
            materials[slot].transparency = 1 - clamp(source.base_color.a, 0, 1)
        }
    }
    if g_renderer.srv_next + u32(len(texture_descs)) > SRV_HEAP_CAPACITY {
        return 0, "Not enough texture descriptor space for this model."
    }

    name := strings.trim_space(request.name)
    if name == "" do name = os.stem(request.path)
    mesh_desc := assets_clone_import(MeshDesc{id = id, name = name, path = model_path, materials = materials}, allocator)
    for &desc in texture_descs do desc = assets_clone_import(desc, allocator)

    catalog_tmp, catalog_contents, prepared := assets_prepare_catalog(model = &mesh_desc, extra_textures = texture_descs[:])
    if !prepared do return 0, "Could not write the updated asset catalog."
    defer os.remove(catalog_tmp)

    // GPU uploads. Startup uploads reuse allocator 0; drain prior frame work first.
    renderer_wait_for_gpu()
    gpu_mesh: GpuMesh
    gpu_textures := make([dynamic]GpuTexture, context.temp_allocator)
    defer if !committed {
        if gpu_mesh.vertex_buffer != nil do gpu_mesh.vertex_buffer->Release()
        if gpu_mesh.index_buffer != nil do gpu_mesh.index_buffer->Release()
        for texture in gpu_textures do if texture.resource != nil do texture.resource->Release()
    }
    if renderer_upload_mesh(&gpu_mesh, mesh_data) < 0 do return 0, "GPU model upload failed."
    batch := assets_decode_batch_size()
    for first := 0; first < len(texture_descs); first += batch {
        descs := texture_descs[first:min(first + batch, len(texture_descs))]
        decoded := make([]DecodedTexture, len(descs), context.temp_allocator)
        assets_decode_textures(descs, decoded)
        defer for texture in decoded do delete(texture.pixels, runtime.heap_allocator())
        for texture, i in decoded {
            if texture.message != "" do return 0, fmt.tprintf("%s (%s)", texture.message, descs[i].path)
            gpu := GpuTexture{srv_index = g_renderer.srv_next + u32(first + i)}
            if renderer_upload_texture(&gpu, descs[i], texture.pixels, texture.width, texture.height) < 0 do return 0, "GPU texture upload failed."
            append(&gpu_textures, gpu)
        }
    }

    current, read_error := os.read_entire_file(g_assets.catalog_path, context.temp_allocator)
    if read_error != nil || string(current) != g_assets.catalog_text do return 0, "Catalog changed on disk. Restart to load those edits before importing."
    saved_text := strings.clone(catalog_contents) or_else panic("Catalog snapshot allocation failed")
    defer if !committed do delete(saved_text)
    if os.rename(catalog_tmp, g_assets.catalog_path) != nil do return 0, "Cannot replace assets.json; check whether it is writable."

    // Committed on disk: register textures first, so the materials resolve.
    committed = true
    for desc in texture_descs {
        assets_register_texture(desc)
    }
    textures := make([]GpuTexture, len(g_renderer.textures) + len(gpu_textures))
    copy(textures, g_renderer.textures)
    copy(textures[len(g_renderer.textures):], gpu_textures[:])
    delete(g_renderer.textures)
    g_renderer.textures = textures
    g_renderer.srv_next += u32(len(gpu_textures))

    material, slots, names, materials_ok := assets_model_materials(mesh_desc, mesh_data)
    assert(materials_ok, "Imported glTF materials failed to resolve")
    model = MeshHandle(len(g_assets.meshes))
    append(&g_assets.meshes, MeshAsset{
        desc = mesh_desc,
        label = strings.clone_to_cstring(name, allocator) or_else panic("Asset label allocation failed"),
        data = mesh_data,
        bounds = mesh_compute_bounds(mesh_data),
        material = material,
        material_slots = slots,
        material_names = names,
    })
    g_assets.mesh_ids[mesh_desc.id] = model
    meshes := make([]GpuMesh, len(g_renderer.meshes) + 1)
    copy(meshes, g_renderer.meshes)
    meshes[len(meshes) - 1] = gpu_mesh
    delete(g_renderer.meshes)
    g_renderer.meshes = meshes

    append(&g_assets.import_arenas, owner)
    delete(g_assets.catalog_text)
    g_assets.catalog_text = saved_text

    if len(gltf.warnings) > 0 {
        message = fmt.aprintf("Imported with %d note(s): %s", len(gltf.warnings), gltf.warnings[0], allocator = allocator)
    }
    return
}

assets_mesh_valid :: proc(h: MeshHandle) -> bool {return h != 0 && int(h) < len(g_assets.meshes)}
assets_texture_valid :: proc(h: TextureHandle) -> bool {return h != 0 && int(h) < len(g_assets.textures)}
assets_optional_texture_valid :: proc(h: TextureHandle) -> bool {return h == 0 || assets_texture_valid(h)}
assets_mesh :: proc(id: string) -> MeshHandle {return g_assets.mesh_ids[id]}
assets_texture :: proc(id: string) -> TextureHandle {return g_assets.texture_ids[id]}
assets_environment :: proc(id: string) -> EnvironmentHandle {return g_assets.environment_ids[id]}
assets_environment_valid :: proc(h: EnvironmentHandle) -> bool {return h != 0 && int(h) < len(g_assets.environments)}
assets_environment_id :: proc(h: EnvironmentHandle) -> string {
    return g_assets.environments[h].desc.id if assets_environment_valid(h) else ""
}
assets_mesh_id :: proc(h: MeshHandle) -> string {return g_assets.meshes[h].desc.id if assets_mesh_valid(h) else ""}
assets_texture_id :: proc(h: TextureHandle) -> string {return g_assets.textures[h].desc.id if assets_texture_valid(h) else ""}
assets_texture_usage :: proc(h: TextureHandle, usage: TextureUsage) -> bool {
    return assets_texture_valid(h) && g_assets.textures[h].desc.usage == usage
}
texture_asset_is_albedo :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .albedo)}
texture_asset_is_normal :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .normal)}
texture_asset_is_roughness :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .roughness)}
texture_asset_is_metallic :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .metallic)}
texture_asset_is_emissive :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .emissive)}
texture_asset_is_occlusion :: proc(h: TextureHandle) -> bool {return assets_texture_usage(h, .occlusion)}

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

// A model's default materials, one per submesh slot, and their display names.
assets_model_materials :: proc(desc: MeshDesc, mesh: MeshData) -> (
    material: Material,
    slots: MaterialSlots,
    names: [MAX_MODEL_MATERIALS]cstring,
    ok: bool,
) {
    sources := desc.materials if len(desc.materials) > 0 else []AssetMaterial{desc.material}
    if len(sources) > MAX_MODEL_MATERIALS do return
    for submesh in mesh.submeshes {
        if int(submesh.material_slot) >= len(sources) do return
    }

    allocator := mem.dynamic_arena_allocator(&g_assets.arena)
    for source, slot in sources {
        resolved := assets_material(source) or_return
        if slot == 0 {
            material = resolved
        } else {
            slots.extra[slot - 1] = resolved
        }
        name := source.name if source.name != "" else fmt.tprintf("Material %d", slot)
        names[slot] = strings.clone_to_cstring(name, allocator) or_else panic("Material name allocation failed")
    }
    slots.count = len(sources)
    return material, slots, names, true
}

// OBJ or glTF geometry for a catalog entry.
assets_load_mesh :: proc(desc: MeshDesc) -> (mesh: MeshData, error: string) {
    extension := strings.to_lower(os.ext(desc.path), context.temp_allocator)
    switch extension {
        case ".gltf", ".glb":
            model: Gltf_Model
            model, error = gltf_load(desc.path)
            return model.mesh, error
        case:
            ok: bool
            mesh, ok = mesh_load_obj(desc.path, flip_v = desc.settings.flip_v)
            if !ok do return {}, "Invalid or empty OBJ geometry."
            return mesh, ""
    }
}

assets_material :: proc(desc: AssetMaterial) -> (material: Material, ok: bool) {
    material = {tint = desc.tint.? or_else {1, 1, 1}, texture = g_assets.white, roughness = 0.8, uv_scale = 1}
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
    // A map without a color glows with the map's own colors.
    emissive, has_emissive := desc.emissive.([3]f32)
    if desc.emissive_map != "" {
        material.emissive_texture = assets_texture(desc.emissive_map)
        if !texture_asset_is_emissive(material.emissive_texture) do return {}, false
        material.use_emissive_map = true
        if !has_emissive do emissive, has_emissive = {1, 1, 1}, true
    }
    if has_emissive {
        material.emissive = emissive
        material.emissive_strength = desc.emissive_strength.? or_else 1
    }
    if desc.occlusion_map != "" {
        material.occlusion_texture = assets_texture(desc.occlusion_map)
        if !texture_asset_is_occlusion(material.occlusion_texture) do return {}, false
        material.use_occlusion_map = true
        material.occlusion_strength = desc.occlusion_strength.? or_else 1
    }
    material.alpha_mask = desc.alpha_mask
    material.alpha_blend = desc.alpha_blend
    material.transparency = desc.transparency.? or_else 0
    material.alpha_cutoff = desc.alpha_cutoff.? or_else 0.5
    material.double_sided = desc.double_sided
    if !(material.roughness >= 0 && material.roughness <= 1) ||
       !(material.metallic >= 0 && material.metallic <= 1) ||
       !(material.normal_strength >= 0) || !(material.uv_scale > 0) ||
       !material_effects_valid(material) {
        return {}, false
    }
    return material, true
}

assets_destroy :: proc() {
    for asset in g_assets.meshes do mesh_destroy(asset.data)
    delete(g_assets.meshes)
    delete(g_assets.textures)
    delete(g_assets.environments)
    delete(g_assets.mesh_ids)
    delete(g_assets.texture_ids)
    delete(g_assets.environment_ids)
    if g_assets.active do mem.dynamic_arena_destroy(&g_assets.arena)
    for &arena in g_assets.import_arenas do mem.dynamic_arena_destroy(&arena)
    delete(g_assets.import_arenas)
    delete(g_assets.catalog_text)
    g_assets = {}
    delete(g_asset_marshalers)
    delete(g_asset_unmarshalers)
    g_asset_marshalers = {}
    g_asset_unmarshalers = {}
}

assets_create_base_catalog :: proc(path: string) -> string {
    // The starter scene requires these IDs. Imported assets are added later
    // through the editor and are not part of the base catalog.
    manifest := AssetManifest{
        version = 1,
        default_environment = "autumn_field_puresky",
        environments = []EnvironmentDesc{
            {id = "autumn_field_puresky", name = "Autumn Field Pure Sky", path = "textures/environments/autumn_field_puresky_4k.hdr"},
            {id = "kloofendal_43d_clear_puresky", name = "Kloofendal 43d Clear Pure Sky", path = "textures/environments/kloofendal_43d_clear_puresky_4k.hdr"},
        },
        models = []MeshDesc{
            {id = "cube", name = "Cube", path = "models/cube.obj", material = {albedo = "portrait", roughness = f32(0.8)}},
            {id = "pyramid", name = "Pyramid", path = "models/pyramid.obj", material = {albedo = "checkerboard", roughness = f32(0.28), metallic = f32(0.75)}},
        },
        textures = []TextureDesc{
            {id = "portrait", name = "Portrait", path = "textures/2.png", usage = .albedo, source = .file},
            {id = "checkerboard", name = "Checkerboard", usage = .albedo, source = .checkerboard, width = 512, height = 512, tile_size = 32},
            {id = "stone.albedo", name = "Stone Albedo", path = "textures/stone/albedo.png", usage = .albedo, source = .file},
            {id = "stone.normal", name = "Stone Normal", path = "textures/stone/normal.png", usage = .normal, source = .file},
            {id = "stone.roughness", name = "Stone Roughness", path = "textures/stone/roughness.png", usage = .roughness, source = .file},
        },
    }
    bytes, encode_error := json.marshal(manifest, {
        pretty = true, use_spaces = true, spaces = 2, use_enum_names = true,
    })
    if encode_error != nil do return "Could not encode the base asset catalog."
    defer delete(bytes)

    // Exclusive creation also protects a catalog created since the failed read.
    file, create_error := os.open(path, {.Write, .Create, .Excl})
    if create_error == os.General_Error.Exist do return ""
    if create_error != nil do return "Cannot create the base asset catalog."
    count, write_error := os.write(file, bytes)
    sync_error := os.sync(file)
    close_error := os.close(file)
    if write_error != nil || sync_error != nil || close_error != nil || count != len(bytes) {
        os.remove(path)
        return "Cannot write the base asset catalog."
    }
    return ""
}

assets_init :: proc(path: string) -> (message: string) {
    assert(!g_assets.active)
    mem.dynamic_arena_init(&g_assets.arena)
    g_assets.active = true
    defer if message != "" do assets_destroy()
    allocator := mem.dynamic_arena_allocator(&g_assets.arena)
    g_assets.catalog_path = strings.clone(path, allocator) or_else panic("Catalog path allocation failed")
    data, error := os.read_entire_file(path, context.temp_allocator)
    if error == os.General_Error.Not_Exist {
        if create_error := assets_create_base_catalog(path); create_error != "" do return create_error
        data, error = os.read_entire_file(path, context.temp_allocator)
    }
    if error != nil do return "Cannot read asset catalog."
    g_assets.catalog_text = strings.clone(string(data)) or_else panic("Catalog snapshot allocation failed")
    if !json.is_valid(data, .JSON, true) do return "Invalid asset catalog JSON."
    manifest: AssetManifest
    decode_error := json.unmarshal(data, &manifest, allocator = allocator)
    if decode_error != nil || manifest.version != 1 {
        fmt.eprintln("Asset catalog:", decode_error)
        return "Invalid asset catalog/version."
    }
    append(&g_assets.meshes, MeshAsset{}) // Zero is an invalid handle.
    append(&g_assets.textures, TextureAsset{})
    append(&g_assets.environments, EnvironmentAsset{})
    for desc in manifest.environments {
        if desc.id == "" || desc.path == "" || assets_environment(desc.id) != 0 {
            return "Empty/duplicate environment ID or missing HDR path."
        }
        h := EnvironmentHandle(len(g_assets.environments))
        append(&g_assets.environments, EnvironmentAsset{desc = desc, label = assets_label(desc.name, desc.id)})
        g_assets.environment_ids[desc.id] = h
    }
    if len(g_assets.environments) == 1 {
        // Compatibility with catalogs created before environments were registered.
        desc := EnvironmentDesc{id = "autumn_field_puresky", name = "Autumn Field Pure Sky", path = "textures/environments/autumn_field_puresky_4k.hdr"}
        append(&g_assets.environments, EnvironmentAsset{desc = desc, label = assets_label(desc.name, desc.id)})
        g_assets.environment_ids[desc.id] = EnvironmentHandle(1)
    }
    g_assets.default_environment = assets_environment(manifest.default_environment) if manifest.default_environment != "" else EnvironmentHandle(1)
    if !assets_environment_valid(g_assets.default_environment) do return "Unknown default environment ID."
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
        mesh, mesh_error := assets_load_mesh(desc)
        if mesh_error != "" {
            fmt.eprintln("Model", desc.id, ":", mesh_error)
            return "Failed to import model."
        }
        material, slots, names, material_ok := assets_model_materials(desc, mesh)
        if !material_ok {
            mesh_destroy(mesh)
            return "Invalid model default material reference."
        }
        bounds := mesh_compute_bounds(mesh)
        if !bounds.valid {
            mesh_destroy(mesh)
            return "Model has no geometry."
        }
        handle := MeshHandle(len(g_assets.meshes))
        append(&g_assets.meshes, MeshAsset{
            desc = desc, label = assets_label(desc.name, desc.id), data = mesh, bounds = bounds,
            material = material, material_slots = slots, material_names = names,
        })
        g_assets.mesh_ids[desc.id] = handle
    }
    assets_json_init()
    return ""
}

// Return owned RGBA8 pixels to the startup uploader, including generated assets.
assets_try_texture_pixels :: proc(desc: TextureDesc, allocator := context.allocator) ->
(pixels: []u8, width, height: u32, message: string) {
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

    // stb_image decodes PNG and JPEG. 16-bit PNGs load at full precision and
    // are rounded to 8 bits (stb's own reduction truncates).
    path := strings.clone_to_cstring(desc.path, context.temp_allocator) or_else panic("Texture path allocation failed")
    image_width, image_height, image_channels: c.int
    wide := bool(stbi.is_16_bit(path))
    decoded: rawptr
    if wide {
        decoded = stbi.load_16(path, &image_width, &image_height, &image_channels, 4)
    } else {
        decoded = stbi.load(path, &image_width, &image_height, &image_channels, 4)
    }
    if decoded == nil {
        return nil, 0, 0, "Could not decode the texture. Choose a valid PNG or JPEG."
    }
    defer stbi.image_free(decoded)
    if image_width <= 0 || image_height <= 0 || u64(image_width) * u64(image_height) > u64(image.MAX_DIMENSIONS) {
        return nil, 0, 0, "Unsupported texture dimensions."
    }

    width, height = u32(image_width), u32(image_height)
    pixels = make([]u8, int(width * height) * 4, allocator)
    if wide {
        source := ([^]u16)(decoded)
        for i in 0..<len(pixels) do pixels[i] = u8((u32(source[i]) + 128) / 257)
    } else {
        copy(pixels, ([^]u8)(decoded)[:len(pixels)])
    }
    if channel, has_channel := desc.settings.channel.?; has_channel {
        if channel < 0 || channel > 3 do return nil, 0, 0, "Invalid texture channel."
        for pixel in 0..<int(width * height) {
            value := pixels[pixel * 4 + channel]
            pixels[pixel * 4 + 0] = value
            pixels[pixel * 4 + 1] = value
            pixels[pixel * 4 + 2] = value
            pixels[pixel * 4 + 3] = 255
        }
    }
    if desc.settings.flip_green {
        for pixel in 0..<int(width * height) do pixels[pixel * 4 + 1] = 255 - pixels[pixel * 4 + 1]
    }
    return
}

DecodedTexture :: struct {
    pixels: []u8, // From runtime.heap_allocator(); the caller deletes them.
    width, height: u32,
    message: string, // Empty on success.
}

// Decoding PNG/JPEG is most of the cost of loading textures, so a batch
// decodes on one thread per texture.
assets_decode_textures :: proc(descs: []TextureDesc, results: []DecodedTexture) {
    assert(len(descs) == len(results))
    Job :: struct {desc: ^TextureDesc, result: ^DecodedTexture}
    decode :: proc(job: Job) {
        // The heap allocator is thread-safe; each thread has its own temp allocator.
        result := job.result
        result.pixels, result.width, result.height, result.message =
            assets_try_texture_pixels(job.desc^, runtime.heap_allocator())
    }
    threads := make([]^thread.Thread, len(descs), context.temp_allocator)
    for &desc, i in descs {
        threads[i] = thread.create_and_start_with_poly_data(Job{&desc, &results[i]}, decode)
    }
    thread.join_multiple(..threads)
    for t in threads do thread.destroy(t)
}

// Textures to decode at once: one per core, which also bounds the memory
// held by decoded pixels waiting for upload.
assets_decode_batch_size :: proc() -> int {
    return clamp(os.get_processor_core_count(), 1, 16)
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
    g_asset_marshalers[typeid_of(EnvironmentHandle)] = assets_marshal_environment
    g_asset_unmarshalers[typeid_of(MeshHandle)] = assets_unmarshal_mesh
    g_asset_unmarshalers[typeid_of(TextureHandle)] = assets_unmarshal_texture
    g_asset_unmarshalers[typeid_of(EnvironmentHandle)] = assets_unmarshal_environment
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

assets_marshal_environment :: proc(w: io.Writer, value: any, options: ^json.Marshal_Options) -> json.Marshal_Error {
    h := value.(EnvironmentHandle)
    if h != 0 && !assets_environment_valid(h) do return json.Marshal_Data_Error.Unsupported_Type
    return json.marshal_to_writer(w, assets_environment_id(h), options)
}

assets_unmarshal_environment :: proc(parser: ^json.Parser, value: any) -> json.Unmarshal_Error {
    token := json.parse_value(parser) or_return
    id, ok := token.(string)
    if !ok do return json.Unmarshal_Data_Error.Invalid_Data
    handle := assets_environment(id)
    if id != "" && handle == 0 do return json.Unmarshal_Data_Error.Invalid_Data
    (^EnvironmentHandle)(value.data)^ = handle
    return nil
}
