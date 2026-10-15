package main

EDITOR_MESH_CHOICES := [MESH_COUNT]EditorChoice{
    {label = "Cube", value = {f32(u32(Mesh_Asset.Cube)), 0, 0}},
    {label = "Pyramid", value = {f32(u32(Mesh_Asset.Pyramid)), 0, 0}},
    {label = "Barrel", value = {f32(u32(Mesh_Asset.Barrel)), 0, 0}},
}

EDITOR_ALBEDO_CHOICES := [4]EditorChoice{
    {label = "Portrait", value = {f32(u32(Texture_Asset.Portrait)), 0, 0}},
    {label = "Checkerboard", value = {f32(u32(Texture_Asset.Checkerboard)), 0, 0}},
    {label = "Stone Albedo", value = {f32(u32(Texture_Asset.Stone_Albedo)), 0, 0}},
    {label = "Barrel Albedo", value = {f32(u32(Texture_Asset.Barrel_Albedo)), 0, 0}},
}

editor_draw_mesh_controls :: proc(scene: ^Scene, index: int) {
    if !scene.has_mesh_renderer[index] {
        return
    }

    ui_separator()
    debug_ui_text("Mesh")
    editor_combo(
        scene, index, .Mesh_Asset, "Asset", EDITOR_MESH_CHOICES[:],
    )
}

editor_draw_texture_controls :: proc(scene: ^Scene, index: int) {
    editor_combo(
        scene, index, .Material_Albedo_Texture,
        "Albedo", EDITOR_ALBEDO_CHOICES[:],
    )

    normal := editor_value(scene, index, .Material_Normal_Map)
    strength := normal[1]
    if strength <= 0 {
        strength = 1
    }

    normal_choices := [3]EditorChoice{
        {label = "None", value = {normal[0], 0, 0}},
        {
            label = "Stone Normal",
            value = {f32(u32(Texture_Asset.Stone_Normal)), strength, 0},
        },
        {
            label = "Barrel Normal",
            value = {f32(u32(Texture_Asset.Barrel_Normal)), strength, 0},
        },
    }
    editor_combo(
        scene, index, .Material_Normal_Map,
        "Normal map", normal_choices[:],
    )

    roughness := editor_value(scene, index, .Material_Roughness_Map)
    roughness_choices := [3]EditorChoice{
        {label = "None", value = {roughness[0], 0, 0}},
        {
            label = "Stone Roughness",
            value = {f32(u32(Texture_Asset.Stone_Roughness)), 1, 0},
        },
        {
            label = "Barrel Roughness",
            value = {f32(u32(Texture_Asset.Barrel_Roughness)), 1, 0},
        },
    }
    editor_combo(
        scene, index, .Material_Roughness_Map,
        "Roughness map", roughness_choices[:],
    )

    metallic := editor_value(scene, index, .Material_Metallic_Map)
    metallic_choices := [2]EditorChoice{
        {label = "None", value = {metallic[0], 0, 0}},
        {
            label = "Barrel Metallic",
            value = {f32(u32(Texture_Asset.Barrel_Metallic)), 1, 0},
        },
    }
    editor_combo(
        scene, index, .Material_Metallic_Map,
        "Metallic map", metallic_choices[:],
    )
}