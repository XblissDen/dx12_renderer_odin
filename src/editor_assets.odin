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
    status: string, // Always in status_buffer, so it outlives the step that set it.
    status_buffer: [512]u8,

    // Removing a model or a texture from the catalog, confirmed first.
    remove_model: bool,
    remove_mesh: MeshHandle,
    remove_texture: TextureHandle,
    remove_confirm, remove_pending: bool,
}

editor_import_status :: proc(format: string, args: ..any) {
    state := &g_editor_import
    state.status = fmt.bprintf(state.status_buffer[:], format, ..args)
}

g_editor_import := EditorImport{model = true, flip_v = true, remove_model = true}

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
            if asset.hidden || asset.removed || asset.desc.usage != usage do continue
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
    ui_next_window(788, 16, 440, 540)
    if ui_begin_panel("Assets") {
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
                editor_import_status("")
            } else if count < 0 {
                editor_import_status("File selection failed.")
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
            // In TextureUsage order; `data` is internal.
            names := [6]cstring{"Albedo", "Normal", "Roughness", "Metallic", "Emissive", "Occlusion"}
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
        ui_separator()
        debug_ui_text("Remove from catalog")
        editor_draw_asset_removal()
        ui_separator()
        if ui_button("Close") do state.open = false
        ui_end_disabled()
        if state.status != "" do debug_ui_text(state.status)
    }
    ui_end_panel()
}

// Runs the import or removal the panel asked for, outside the UI frame.
editor_process_asset_import :: proc() {
    state := &g_editor_import
    if state.remove_pending {
        state.remove_pending = false
        state.remove_confirm = false
        editor_finish_edit()
        mesh := state.remove_mesh if state.remove_model else 0
        texture := state.remove_texture if !state.remove_model else 0
        message := assets_remove(&g_scene, mesh, texture)
        if message == "" {
            // Undo steps could bring back an entity using the removed asset.
            editor_clear_history()
            if !assets_mesh_valid(g_editor_model_to_add) do g_editor_model_to_add = 0
            for &handle in state.maps do if !assets_texture_valid(handle) do handle = 0
            state.remove_mesh, state.remove_texture = 0, 0
            message = "Removed from the catalog."
        }
        editor_import_status("%s", message)
    }
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
    // A successful glTF import can still carry a note (e.g. skipped primitives).
    // Copied: import errors are formatted in memory the import frees.
    if model != 0 {
        g_editor_model_to_add = model
        editor_import_status("Model imported. Use Add Model in the Scene panel.%s%s", "\n" if error != "" else "", error)
    } else if texture != 0 {
        editor_import_status("Texture imported and available in material pickers.")
    } else {
        editor_import_status("%s", error)
    }
}

// Remove-from-catalog section of the Assets panel.
editor_draw_asset_removal :: proc() {
    state := &g_editor_import
    // "##..." gives the dropdown and the confirm button, both shown as
    // "Remove", distinct ImGui IDs.
    if ui_begin_combo("Remove##kind", "Model" if state.remove_model else "Texture") {
        if ui_selectable("Model", state.remove_model) do state.remove_model, state.remove_confirm = true, false
        if ui_selectable("Texture", !state.remove_model) do state.remove_model, state.remove_confirm = false, false
        ui_end_combo()
    }
    if state.remove_model {
        if editor_model_picker("Model##remove", &state.remove_mesh) do state.remove_confirm = false
    } else {
        preview: cstring = "Select texture"
        if assets_texture_valid(state.remove_texture) do preview = g_assets.textures[state.remove_texture].label
        if ui_begin_combo("Texture##remove", preview) {
            for i in 1..<len(g_assets.textures) {
                asset := &g_assets.textures[i]
                if asset.hidden || asset.removed do continue
                ui_push_id(i32(i))
                if ui_selectable(fmt.ctprintf("%s (%v)", asset.label, asset.desc.usage), state.remove_texture == TextureHandle(i)) {
                    state.remove_texture = TextureHandle(i)
                    state.remove_confirm = false
                }
                ui_pop_id()
            }
            ui_end_combo()
        }
    }

    mesh := state.remove_mesh if state.remove_model else 0
    texture := state.remove_texture if !state.remove_model else 0
    textures, refusal := assets_plan_removal(&g_scene, mesh, texture)
    if refusal != "" {
        debug_ui_text(refusal)
    } else if !state.remove_confirm {
        if ui_button("Remove...") do state.remove_confirm = true
    } else {
        label := g_assets.meshes[mesh].label if mesh != 0 else g_assets.textures[texture].label
        extra := fmt.tprintf(" and %d of its textures", len(textures)) if mesh != 0 && len(textures) > 0 else ""
        debug_ui_text(fmt.tprintf("Remove \"%s\"%s? Files the importer copied are", label, extra))
        debug_ui_text("deleted, undo history is cleared, and saved scenes")
        debug_ui_text("that use it will no longer load.")
        if ui_button("Remove##confirm") do state.remove_pending = true
        ui_same_line()
        if ui_button("Cancel") do state.remove_confirm = false
    }
}

g_editor_model_to_add: MeshHandle

editor_model_picker :: proc(label: cstring, selected: ^MeshHandle) -> bool {
    preview: cstring = "Select model"
    if assets_mesh_valid(selected^) do preview = g_assets.meshes[selected^].label
    changed := false
    if ui_begin_combo(label, preview) {
        for i in 1..<len(g_assets.meshes) {
            // Parts are added with their model (as its node tree).
            if g_assets.meshes[i].removed || g_assets.meshes[i].part_of != 0 do continue
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
            // Occlusion keeps its strength for when a map is chosen again.
            if field == .Material_Occlusion_Map do value.strength = current.strength
            editor_commit_asset(scene, index, field, value)
        }
        for i in 1..<len(g_assets.textures) {
            asset := &g_assets.textures[i]
            if asset.hidden || asset.removed || asset.desc.usage != usage do continue
            ui_push_id(i32(i))
            if ui_selectable(asset.label, enabled && current.texture == TextureHandle(i)) {
                strength := current.strength if current.strength > 0 else f32(1)
                value := EditorAssetValue{texture = TextureHandle(i)}
                if field != .Material_Albedo_Texture do value.enabled = true
                if field == .Material_Normal_Map do value.strength = strength
                if field == .Material_Occlusion_Map do value.strength = min(strength, 1)
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
    editor_texture_picker(scene, index, .Material_Emissive_Map, "Emissive map", .emissive)
    editor_texture_picker(scene, index, .Material_Occlusion_Map, "Occlusion map", .occlusion)
}

// Add Model brings a glTF model with several nodes in as its node tree:
// one entity per node, under an empty entity named after the model.
// Otherwise (or with this off) the model is one entity.
g_editor_add_node_tree := true

editor_model_has_tree :: proc(model: MeshHandle) -> bool {
    return assets_mesh_valid(model) && len(g_assets.meshes[model].nodes) > 1
}

editor_add_model :: proc(scene: ^Scene, model: MeshHandle) {
    if !assets_mesh_valid(model) do return
    editor_finish_edit()
    asset := &g_assets.meshes[model]
    name, ok := scene_store_owned_name(asset.desc.name if asset.desc.name != "" else asset.desc.id)
    if !ok do return
    // Three units in front of the camera, centered on the model's bounds.
    transform := Transform{scale = {1, 1, 1}}
    camera := camera_find_active(scene)
    if camera >= 0 {
        transform.position = scene.transforms[camera].position + camera_forward(&scene.cameras[camera]) * 3 - (asset.bounds.minimum + asset.bounds.maximum) * 0.5
    }
    if !g_editor_add_node_tree || !editor_model_has_tree(model) {
        snapshot := EditorEntitySnapshot{name = name, transform = transform, mesh_renderer = MeshRenderer{mesh = model}, material = asset.material, material_slots = asset.material_slots}
        editor_create_entity(scene, snapshot, g_editor_selected)
        return
    }

    // The root, then the nodes in order (parents before children), as one
    // undo step. All or nothing: if the entity slots run out, the entities
    // made so far are removed again.
    commands := make([dynamic]EditorCommand, context.temp_allocator)
    entities := make([]Entity, len(asset.nodes), context.temp_allocator)
    root, root_ok := editor_create_entity_command(scene, EditorEntitySnapshot{name = name, transform = transform}, g_editor_selected)
    if !root_ok do return
    append(&commands, root)
    for node, i in asset.nodes {
        node_name, name_ok := scene_store_owned_name(node.name)
        snapshot := EditorEntitySnapshot{
            name = node_name if name_ok else "",
            transform = node.transform,
            parent = entities[node.parent] if node.parent >= 0 else root.entity,
        }
        if node.part != 0 {
            snapshot.mesh_renderer = MeshRenderer{mesh = node.part}
            snapshot.material = asset.material
            snapshot.material_slots = asset.material_slots
        }
        command, created := editor_create_entity_command(scene, snapshot, Entity(-1))
        if !created {
            for j := len(commands) - 1; j >= 0; j -= 1 do editor_remove_created_entity(scene, commands[j].entity)
            return
        }
        append(&commands, command)
        entities[i] = command.entity
    }
    editor_push_commands(commands[:], root.entity)
    editor_select(root.entity)
}
