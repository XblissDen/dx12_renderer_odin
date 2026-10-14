package main

import alg "core:math/linalg"
import "core:math"

MAX_EDITOR_HISTORY :: 128

EditorField :: enum {
    Position,
    Y_Rotation,
    Uniform_Scale,
    Spin,

    Material_Tint,
    Material_Roughness,
    Material_Metallic,
    Material_Normal_Strength,
    Material_UV_Scale,
    Material_Use_Roughness_Map,

    Point_Color,
    Point_Intensity,
    Point_Orbit_Enabled,
    Point_Orbit_Radius,
    Point_Orbit_Height,
    Point_Orbit_Speed,

    Sun_Color,
    Sun_Intensity,
    Sun_Direction,

    Mesh_Asset,
    Material_Albedo_Texture,
    Material_Normal_Map,
    Material_Roughness_Map,
}

EditorCommandKind :: enum {
    Edit_Field,
    Create_Mesh,
    Delete_Mesh
}

EditorMeshSnapshot :: struct {
    name: string,
    transform: Transform,
    mesh_renderer: MeshRenderer,
    material: Material,
}

EditorCommand :: struct {
    kind: EditorCommandKind,

    entity: Entity,
    field: EditorField,

    // Position uses all three values.
    // Scalar properties use the first value.
    //Mesh/albedo:   {asset ID, 0, 0}
    //Normal map:    {asset ID, strength, 0}
    //Roughness map: {asset ID, enabled, 0}
    before: [3]f32,
    after: [3]f32,

    mesh_snapshot: EditorMeshSnapshot,
    source_entity: Entity,
}

g_editor_history: [MAX_EDITOR_HISTORY]EditorCommand
g_editor_history_count: int

// Number of commands currently applied.
// Commands from cursor to count are available for redo.
g_editor_history_cursor: int

g_editor_pending_edit: EditorCommand
g_editor_pending_active: bool
g_editor_pending_changed: bool

editor_bool_value :: proc(value: bool) -> [3]f32 {
    if value {
        return {1, 0, 0}
    }
    return {0, 0, 0}
}

editor_field_exists :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
) -> bool {
    if !scene_entity_is_alive(scene, Entity(index)) {
        return false
    }

    switch field {
        case .Position, .Y_Rotation, .Uniform_Scale, .Spin:
            return scene.has_transform[index]

        case .Material_Tint,
             .Material_Roughness,
             .Material_Metallic,
             .Material_Normal_Strength,
             .Material_UV_Scale,
             .Material_Use_Roughness_Map,
             .Material_Albedo_Texture,
             .Material_Normal_Map,
             .Material_Roughness_Map:
            return scene.has_material[index]

        case .Point_Orbit_Height:
            return scene.has_point_light[index] &&
                   scene.has_transform[index]

        case .Point_Color,
             .Point_Intensity,
             .Point_Orbit_Enabled,
             .Point_Orbit_Radius,
             .Point_Orbit_Speed:
            return scene.has_point_light[index]

        case .Sun_Color, .Sun_Intensity, .Sun_Direction:
            return scene.has_directional_light[index]

        case .Mesh_Asset:
            return scene.has_mesh_renderer[index]
    }

    return false
}

editor_value :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
) -> [3]f32 {
    if !editor_field_exists(scene, index, field) {
        return {}
    }

    switch field {
        case .Position:
            return scene.transforms[index].position
        case .Y_Rotation:
            return {scene.transforms[index].rotation, 0, 0}
        case .Uniform_Scale:
            return {scene.transforms[index].scale, 0, 0}
        case .Spin:
            return {scene.transforms[index].rotation_speed, 0, 0}

        case .Material_Tint:
            return scene.materials[index].tint
        case .Material_Roughness:
            return {scene.materials[index].roughness, 0, 0}
        case .Material_Metallic:
            return {scene.materials[index].metallic, 0, 0}
        case .Material_Normal_Strength:
            return {scene.materials[index].normal_strength, 0, 0}
        case .Material_UV_Scale:
            return {scene.materials[index].uv_scale, 0, 0}
        case .Material_Use_Roughness_Map:
            return editor_bool_value(scene.materials[index].use_roughness_map)
        case .Material_Albedo_Texture:
            return {f32(u32(scene.materials[index].texture)), 0, 0}
        case .Material_Normal_Map:
            return {
                f32(u32(scene.materials[index].normal_texture)),
                scene.materials[index].normal_strength,
                0,
            }
        case .Material_Roughness_Map:
            enabled := editor_bool_value(
                scene.materials[index].use_roughness_map,
            )
            return {
                f32(u32(scene.materials[index].roughness_texture)),
                enabled[0],
                0,
            }
        case .Mesh_Asset:
            return {f32(u32(scene.mesh_renderers[index].mesh)), 0, 0}

        case .Point_Color:
            return scene.point_lights[index].color
        case .Point_Intensity:
            return {scene.point_lights[index].intensity, 0, 0}
        case .Point_Orbit_Enabled:
            return editor_bool_value(scene.point_lights[index].orbit_enabled)
        case .Point_Orbit_Radius:
            return {scene.point_lights[index].orbit_radius, 0, 0}
        case .Point_Orbit_Height:
            return {scene.transforms[index].position.y, 0, 0}
        case .Point_Orbit_Speed:
            return {scene.point_lights[index].orbit_speed, 0, 0}

        case .Sun_Color:
            return scene.directional_lights[index].color
        case .Sun_Intensity:
            return {scene.directional_lights[index].intensity, 0, 0}
        case .Sun_Direction:
            return scene.directional_lights[index].direction
    }

    return {}
}

editor_apply_value :: proc(
    scene: ^Scene,
    entity: Entity,
    field: EditorField,
    value: [3]f32,
) -> bool {
    index := int(entity)
    if !editor_field_exists(scene, index, field) {
        return false
    }

    switch field {
        case .Position:
            scene.transforms[index].position = value
        case .Y_Rotation:
            scene.transforms[index].rotation = value[0]
        case .Uniform_Scale:
            scene.transforms[index].scale = value[0]
        case .Spin:
            scene.transforms[index].rotation_speed = value[0]

        case .Material_Tint:
            scene.materials[index].tint = value
        case .Material_Roughness:
            scene.materials[index].roughness = value[0]
        case .Material_Metallic:
            scene.materials[index].metallic = value[0]
        case .Material_Normal_Strength:
            scene.materials[index].normal_strength = value[0]
        case .Material_UV_Scale:
            scene.materials[index].uv_scale = value[0]
        case .Material_Use_Roughness_Map:
            scene.materials[index].use_roughness_map = value[0] != 0
        case .Material_Albedo_Texture:
            asset, ok := editor_decode_asset_index(value[0], TEXTURE_COUNT)
            if !ok || !texture_asset_is_albedo(Texture_Asset(u32(asset))) {
                return false
            }
            scene.materials[index].texture = Texture_Asset(u32(asset))

        case .Material_Normal_Map:
            asset, ok := editor_decode_asset_index(value[0], TEXTURE_COUNT)
            if !ok || !(value[1] >= 0) {
                return false
            }

            texture := Texture_Asset(u32(asset))
            if value[1] > 0 && texture != .Stone_Normal {
                return false
            }

            scene.materials[index].normal_texture = texture
            scene.materials[index].normal_strength = value[1]

        case .Material_Roughness_Map:
            asset, ok := editor_decode_asset_index(value[0], TEXTURE_COUNT)
            if !ok || (value[1] != 0 && value[1] != 1) {
                return false
            }

            texture := Texture_Asset(u32(asset))
            enabled := value[1] != 0
            if enabled && texture != .Stone_Roughness {
                return false
            }

            scene.materials[index].roughness_texture = texture
            scene.materials[index].use_roughness_map = enabled

        case .Mesh_Asset:
            asset, ok := editor_decode_asset_index(value[0], MESH_COUNT)
            if !ok {
                return false
            }
            scene.mesh_renderers[index].mesh = Mesh_Asset(u32(asset))

        case .Point_Color:
            scene.point_lights[index].color = value
        case .Point_Intensity:
            scene.point_lights[index].intensity = value[0]
        case .Point_Orbit_Enabled:
            scene.point_lights[index].orbit_enabled = value[0] != 0
        case .Point_Orbit_Radius:
            scene.point_lights[index].orbit_radius = value[0]
        case .Point_Orbit_Height:
            scene.transforms[index].position.y = value[0]
        case .Point_Orbit_Speed:
            scene.point_lights[index].orbit_speed = value[0]

        case .Sun_Color:
            scene.directional_lights[index].color = value
        case .Sun_Intensity:
            scene.directional_lights[index].intensity = value[0]
        case .Sun_Direction:
            direction := alg.Vector3f32(value)
            if alg.dot(direction, direction) <= 0.00000001 {
                return false
            }
            scene.directional_lights[index].direction = alg.normalize(direction)
    }

    return true
}

editor_push_command :: proc(command: EditorCommand) {
    if command.kind == .Edit_Field && command.before == command.after {
        return
    }

    // An edit after undo starts a new branch and discards the redo commands.
    g_editor_history_count = g_editor_history_cursor

    if g_editor_history_count == MAX_EDITOR_HISTORY {
        for i in 1..<g_editor_history_count {
            g_editor_history[i - 1] = g_editor_history[i]
        }
        g_editor_history_count -= 1
    }

    g_editor_history[g_editor_history_count] = command
    g_editor_history_count += 1
    g_editor_history_cursor = g_editor_history_count
}

editor_finish_edit :: proc() {
    if !g_editor_pending_active {
        return
    }

    if g_editor_pending_changed {
        editor_push_command(g_editor_pending_edit)
    }

    g_editor_pending_active = false
    g_editor_pending_changed = false
}

editor_track_edit :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    before: [3]f32,
    changed: bool,
) {
    // Call immediately after the corresponding ImGui widget.
    activated := ui_item_activated()
    deactivated := ui_item_deactivated()

    matching := g_editor_pending_active &&
                g_editor_pending_edit.entity == Entity(index) &&
                g_editor_pending_edit.field == field

    if activated || (changed && !matching) {
        editor_finish_edit()

        g_editor_pending_edit = EditorCommand{
            entity = Entity(index),
            field = field,
            before = before,
            after = before,
        }
        g_editor_pending_active = true
        g_editor_pending_changed = false
    }

    matching = g_editor_pending_active &&
               g_editor_pending_edit.entity == Entity(index) &&
               g_editor_pending_edit.field == field

    if matching {
        if changed {
            g_editor_pending_edit.after = editor_value(
                scene, index, field,
            )
            g_editor_pending_changed = true
        }

        if deactivated {
            // Read the final value, including a possible cancelled edit.
            if g_editor_pending_changed {
                g_editor_pending_edit.after = editor_value(
                    scene, index, field,
                )
            }
            editor_finish_edit()
        }
    }
}

editor_finish_idle_edit :: proc() {
    if g_editor_pending_active && !ui_any_item_active() {
        editor_finish_edit()
    }
}

editor_slot_referenced_by_history :: proc(slot: int) -> bool {
    // Only applied commands survive after a new action.
    // Redo commands are discarded when the next command is pushed.
    for i in 0..<g_editor_history_cursor {
        command := g_editor_history[i]

        if int(command.entity) == slot {
            return true
        }

        // Undoing a duplicate selects its original source, too.
        if command.kind == .Create_Mesh &&
           int(command.source_entity) == slot {
            return true
        }
    }

    return false
}

editor_undo :: proc(scene: ^Scene) {
    editor_finish_edit()

    if g_editor_history_cursor == 0 {
        return
    }

    command := g_editor_history[g_editor_history_cursor - 1]
    applied := false

    switch command.kind {
        case .Edit_Field:
            applied = editor_apply_value(
                scene, command.entity, command.field, command.before,
            )
            if applied {
                g_editor_selected = command.entity
            }

        case .Create_Mesh:
            applied = editor_remove_created_mesh(scene, command.entity)
            if applied {
                g_editor_selected = command.source_entity
            }

        case .Delete_Mesh:
            applied = editor_restore_deleted_mesh(
                scene, command.entity, command.mesh_snapshot,
            )
            if applied {
                g_editor_selected = command.entity
            }
    }

    if applied {
        g_editor_history_cursor -= 1
    }
}

editor_redo :: proc(scene: ^Scene) {
    editor_finish_edit()

    if g_editor_history_cursor >= g_editor_history_count {
        return
    }

    command := g_editor_history[g_editor_history_cursor]
    applied := false

    switch command.kind {
        case .Edit_Field:
            applied = editor_apply_value(
                scene, command.entity, command.field, command.after,
            )

        case .Create_Mesh:
            applied = editor_restore_created_mesh(
                scene, command.entity, command.mesh_snapshot,
            )

        case .Delete_Mesh:
            applied = editor_delete_mesh(scene, command.entity)
    }

    if applied {
        g_editor_history_cursor += 1

        if command.kind == .Delete_Mesh {
            g_editor_selected = Entity(-1)
        } else {
            g_editor_selected = command.entity
        }
    }
}

editor_decode_asset_index :: proc(
    value: f32,
    count: int,
) -> (index: int, ok: bool) {
    if !(value >= 0 && value < f32(count)) || value != math.floor(value) {
        return 0, false
    }
    return int(value), true
}

// Dropdown selections are discrete actions, unlike a multi-frame slider drag.
editor_commit_value :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    value: [3]f32,
) -> bool {
    if !editor_field_exists(scene, index, field) {
        return false
    }

    editor_finish_edit()

    before := editor_value(scene, index, field)
    if before == value || !editor_apply_value(scene, Entity(index), field, value) {
        return false
    }

    editor_push_command(EditorCommand{
        kind = .Edit_Field,
        entity = Entity(index),
        field = field,
        before = before,
        after = editor_value(scene, index, field),
    })
    return true
}

editor_clear_history :: proc() {
    g_editor_history_count = 0
    g_editor_history_cursor = 0
    g_editor_pending_active = false
    g_editor_pending_changed = false
}