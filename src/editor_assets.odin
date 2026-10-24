package main

import "core:fmt"
import "core:os"

EditorImport :: struct {
    open, pending: bool,
    model: bool,
    path: [4096]u8,
    name: [256]u8,
    usage: TextureUsage,
    flip_v, flip_green: bool,
    maps: [4]TextureHandle,
    status: string,
}

g_editor_import := EditorImport{model = true, flip_v = true}

editor_import_text :: proc(buffer: []u8) -> string {
    return string(cstring(raw_data(buffer)))
}

editor_import_map :: proc(label: cstring, selected: ^TextureHandle, usage: TextureUsage) {
    preview: cstring = "None"
    if assets_texture_valid(selected^) do preview = g_assets.textures[selected^].label
    if ui_begin_combo(label, preview) {
        if ui_selectable("None", selected^ == 0) do selected^ = 0
        for i in 1..<len(g_assets.textures) {
            asset := &g_assets.textures[i]
            if asset.hidden || asset.desc.usage != usage do continue
            ui_push_id(i32(i))
            if ui_selectable(asset.label, selected^ == TextureHandle(i)) do selected^ = TextureHandle(i)
            ui_pop_id()
        }
        ui_end_combo()
    }
}

editor_draw_import_panel :: proc() {
    state := &g_editor_import
    if !state.open do return
    ui_next_window(788, 16, 440, 430)
    if ui_begin_panel("Asset import") {
        ui_begin_disabled(state.pending)
        if ui_begin_combo("Type", "Model (OBJ, glTF)" if state.model else "Texture (PNG, JPEG)") {
            if ui_selectable("Model (OBJ, glTF)", state.model) {
                state.model = true
                state.path = {}
                state.name = {}
            }
            if ui_selectable("Texture (PNG, JPEG)", !state.model) {
                state.model = false
                state.path = {}
                state.name = {}
            }
            ui_end_combo()
        }
        if ui_button("Choose file...") {
            count := window_open_asset_file(state.model, state.path[:])
            if count > 0 {
                state.name = {}
                stem := os.stem(editor_import_text(state.path[:]))
                if len(stem) >= len(state.name) do stem = "Imported asset"
                copy(state.name[:len(state.name)-1], transmute([]u8)stem)
                state.status = ""
            } else if count < 0 {
                state.status = "File selection failed."
            }
        }
        path := editor_import_text(state.path[:])
        debug_ui_text(os.base(path) if path != "" else "Choose a model or texture file.")
        ui_input_text("Name", raw_data(state.name[:]), uint(len(state.name)))
        if state.model && assets_is_gltf_path(path) {
            debug_ui_text("Materials and textures come from the glTF file.")
            debug_ui_text("Its buffers and images must sit next to it.")
        } else if state.model {
            ui_checkbox("Flip V (Blender OBJ)", &state.flip_v)
            debug_ui_text("Optional default material: import textures first.")
            editor_import_map("Albedo", &state.maps[0], .albedo)
            editor_import_map("Normal", &state.maps[1], .normal)
            editor_import_map("Roughness", &state.maps[2], .roughness)
            editor_import_map("Metallic", &state.maps[3], .metallic)
        } else {
            names := [4]cstring{"Albedo", "Normal", "Roughness", "Metallic"}
            if ui_begin_combo("Usage", names[int(state.usage)]) {
                for name, i in names {
                    if ui_selectable(name, int(state.usage) == i) do state.usage = TextureUsage(i)
                }
                ui_end_combo()
            }
            if state.usage == .normal do ui_checkbox("Invert normal green channel", &state.flip_green)
        }
        ui_begin_disabled(path == "")
        if ui_button("Import") do state.pending = true
        ui_end_disabled()
        if ui_button("Close") do state.open = false
        ui_end_disabled()
        if state.status != "" do debug_ui_text(state.status)
    }
    ui_end_panel()
}

editor_process_asset_import :: proc() {
    state := &g_editor_import
    if !state.pending do return
    state.pending = false
    editor_finish_edit()
    material := AssetMaterial{
        albedo = assets_texture_id(state.maps[0]),
        normal = assets_texture_id(state.maps[1]),
        roughness_map = assets_texture_id(state.maps[2]),
        metallic_map = assets_texture_id(state.maps[3]),
    }
    model, texture, error := assets_import({
        model = state.model,
        path = editor_import_text(state.path[:]),
        name = editor_import_text(state.name[:]),
        usage = state.usage,
        flip_v = state.flip_v,
        flip_green = state.flip_green,
        material = material,
    })
    // A successful glTF import can still carry a note (e.g. alpha drawn opaque).
    state.status = error
    if model != 0 {
        g_editor_model_to_add = model
        state.status = "Model imported. Use Add Model in the Scene panel."
        @(static) note_buffer: [512]u8
        if error != "" do state.status = fmt.bprintf(note_buffer[:], "%s\n%s", state.status, error)
    } else if texture != 0 {
        state.status = "Texture imported and available in material pickers."
    }
}

g_editor_model_to_add: MeshHandle

editor_model_picker :: proc(label: cstring, selected: ^MeshHandle) -> bool {
    preview: cstring = "Select model"
    if assets_mesh_valid(selected^) do preview = g_assets.meshes[selected^].label
    changed := false
    if ui_begin_combo(label, preview) {
        for i in 1..<len(g_assets.meshes) {
            ui_push_id(i32(i))
            if ui_selectable(g_assets.meshes[i].label, selected^ == MeshHandle(i)) {
                selected^ = MeshHandle(i)
                changed = true
            }
            ui_pop_id()
        }
        ui_end_combo()
    }
    return changed
}

editor_texture_picker :: proc(scene: ^Scene, index: int, field: EditorField, label: cstring, usage: TextureUsage) {
    current := editor_asset_value(scene, index, field)
    enabled := current.enabled if field != .Material_Albedo_Texture else true
    preview: cstring = "None"
    if enabled && assets_texture_valid(current.texture) do preview = g_assets.textures[current.texture].label
    if ui_begin_combo(label, preview) {
        empty_selected := current.texture == g_assets.white if field == .Material_Albedo_Texture else !enabled
        if ui_selectable("White" if field == .Material_Albedo_Texture else "None", empty_selected) {
            value := EditorAssetValue{texture = current.texture}
            if field == .Material_Albedo_Texture do value.texture = g_assets.white
            editor_commit_asset(scene, index, field, value)
        }
        for i in 1..<len(g_assets.textures) {
            asset := &g_assets.textures[i]
            if asset.hidden || asset.desc.usage != usage do continue
            ui_push_id(i32(i))
            if ui_selectable(asset.label, enabled && current.texture == TextureHandle(i)) {
                strength := current.strength if current.strength > 0 else f32(1)
                value := EditorAssetValue{texture = TextureHandle(i)}
                if field != .Material_Albedo_Texture do value.enabled = true
                if field == .Material_Normal_Map do value.strength = strength
                editor_commit_asset(scene, index, field, value)
            }
            ui_pop_id()
        }
        ui_end_combo()
    }
}

editor_draw_mesh_controls :: proc(scene: ^Scene, index: int) {
    if !scene.has_mesh_renderer[index] do return
    ui_separator()
    debug_ui_text("Mesh")
    handle := scene.mesh_renderers[index].mesh
    if editor_model_picker("Asset", &handle) do editor_commit_asset(scene, index, .Mesh_Asset, {mesh = handle})
}

editor_draw_texture_controls :: proc(scene: ^Scene, index: int) {
    editor_texture_picker(scene, index, .Material_Albedo_Texture, "Albedo", .albedo)
    editor_texture_picker(scene, index, .Material_Normal_Map, "Normal map", .normal)
    editor_texture_picker(scene, index, .Material_Roughness_Map, "Roughness map", .roughness)
    editor_texture_picker(scene, index, .Material_Metallic_Map, "Metallic map", .metallic)
}

editor_add_model :: proc(scene: ^Scene, model: MeshHandle) {
    if !assets_mesh_valid(model) do return
    editor_finish_edit()
    slot := editor_find_available_mesh_slot(scene)
    if slot < 0 do return
    asset := &g_assets.meshes[model]
    name, ok := scene_store_owned_name(asset.desc.name if asset.desc.name != "" else asset.desc.id)
    if !ok do return
    transform := Transform{scale = {1, 1, 1}}
    camera := camera_find_active(scene)
    if camera >= 0 {
        transform.position = scene.transforms[camera].position + camera_forward(&scene.cameras[camera]) * 3 - (asset.bounds.minimum + asset.bounds.maximum) * 0.5
    }
    source := g_editor_selected
    snapshot := EditorMeshSnapshot{name = name, transform = transform, mesh_renderer = {mesh = model}, material = asset.material, material_slots = asset.material_slots}
    entity := Entity(slot)
    if !editor_restore_created_mesh(scene, entity, snapshot) do return
    editor_push_command({kind = .Create_Mesh, entity = entity, source_entity = source, mesh_snapshot = snapshot})
    g_editor_selected = entity
}
