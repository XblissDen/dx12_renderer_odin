package main

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
    transform := Transform{scale = 1}
    camera := camera_find_active(scene)
    if camera >= 0 {
        transform.position = scene.transforms[camera].position + camera_forward(&scene.cameras[camera]) * 3 - (asset.bounds.minimum + asset.bounds.maximum) * 0.5
    }
    source := g_editor_selected
    snapshot := EditorMeshSnapshot{name = name, transform = transform, mesh_renderer = {mesh = model}, material = asset.material}
    entity := Entity(slot)
    if !editor_restore_created_mesh(scene, entity, snapshot) do return
    editor_push_command({kind = .Create_Mesh, entity = entity, source_entity = source, mesh_snapshot = snapshot})
    g_editor_selected = entity
}