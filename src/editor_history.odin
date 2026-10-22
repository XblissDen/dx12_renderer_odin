package main

import alg "core:math/linalg"
import "core:math"

MAX_EDITOR_HISTORY :: 128
MIN_TRANSFORM_SCALE :: f32(0.01)

EditorField :: enum {
    Position,
    Rotation,
    Scale,
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
    Material_Metallic_Map,
}

EditorCommandKind :: enum {
    Edit_Field,
    Create_Mesh,
    Delete_Mesh,
    Edit_Asset,
}

EditorAssetValue :: struct {
    mesh: MeshHandle,
    texture: TextureHandle,
    strength: f32,
    enabled: bool,
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
    // Asset references use the typed payload below.
    before: [3]f32,
    after: [3]f32,
    asset_before, asset_after: EditorAssetValue,

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
        case .Position, .Rotation, .Scale, .Spin:
            return scene.has_transform[index]

        case .Material_Tint,
             .Material_Roughness,
             .Material_Metallic,
             .Material_Normal_Strength,
             .Material_UV_Scale,
             .Material_Use_Roughness_Map,
             .Material_Albedo_Texture,
             .Material_Normal_Map,
             .Material_Roughness_Map,
             .Material_Metallic_Map:
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
        case .Rotation:
            return scene.transforms[index].rotation
        case .Scale:
            return scene.transforms[index].scale
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
        case .Material_Albedo_Texture, .Material_Normal_Map, .Material_Roughness_Map, .Material_Metallic_Map, .Mesh_Asset:
            panic("Use typed asset history for asset references")

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
        case .Rotation:
            scene.transforms[index].rotation = value
        case .Scale:
            // Clamp instead of rejecting so dragging past zero stops at the minimum.
            scene.transforms[index].scale = {
                max(value.x, MIN_TRANSFORM_SCALE),
                max(value.y, MIN_TRANSFORM_SCALE),
                max(value.z, MIN_TRANSFORM_SCALE),
            }
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
        case .Material_Albedo_Texture, .Material_Normal_Map, .Material_Roughness_Map, .Material_Metallic_Map, .Mesh_Asset:
            return false

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
    if command.kind == .Edit_Asset && command.asset_before == command.asset_after do return

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
        case .Edit_Asset:
            applied = editor_apply_asset(scene, int(command.entity), command.field, command.asset_before)
            if applied do g_editor_selected = command.entity
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
        case .Edit_Asset:
            applied = editor_apply_asset(scene, int(command.entity), command.field, command.asset_after)
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

editor_asset_value :: proc(scene: ^Scene, index: int, field: EditorField) -> EditorAssetValue {
    #partial switch field {
        case .Mesh_Asset: return {mesh = scene.mesh_renderers[index].mesh}
        case .Material_Albedo_Texture: return {texture = scene.materials[index].texture}
        case .Material_Normal_Map: return {texture = scene.materials[index].normal_texture, strength = scene.materials[index].normal_strength, enabled = scene.materials[index].normal_strength > 0}
        case .Material_Roughness_Map: return {texture = scene.materials[index].roughness_texture, enabled = scene.materials[index].use_roughness_map}
        case .Material_Metallic_Map: return {texture = scene.materials[index].metallic_texture, enabled = scene.materials[index].use_metallic_map}
        case: panic("Not an asset field")
    }
}

editor_apply_asset :: proc(scene: ^Scene, index: int, field: EditorField, value: EditorAssetValue) -> bool {
    if !editor_field_exists(scene, index, field) do return false
    #partial switch field {
        case .Mesh_Asset:
            if !assets_mesh_valid(value.mesh) do return false
            scene.mesh_renderers[index].mesh = value.mesh
        case .Material_Albedo_Texture:
            if !texture_asset_is_albedo(value.texture) do return false
            scene.materials[index].texture = value.texture
        case .Material_Normal_Map:
            if !assets_optional_texture_valid(value.texture) || !(value.strength >= 0) || value.enabled != (value.strength > 0) do return false
            if value.strength > 0 && !texture_asset_is_normal(value.texture) do return false
            scene.materials[index].normal_texture = value.texture
            scene.materials[index].normal_strength = value.strength
        case .Material_Roughness_Map:
            if !assets_optional_texture_valid(value.texture) || (value.enabled && !texture_asset_is_roughness(value.texture)) do return false
            scene.materials[index].roughness_texture = value.texture
            scene.materials[index].use_roughness_map = value.enabled
        case .Material_Metallic_Map:
            if !assets_optional_texture_valid(value.texture) || (value.enabled && !texture_asset_is_metallic(value.texture)) do return false
            scene.materials[index].metallic_texture = value.texture
            scene.materials[index].use_metallic_map = value.enabled
        case: return false
    }
    return true
}

editor_commit_asset :: proc(scene: ^Scene, index: int, field: EditorField, value: EditorAssetValue) -> bool {
    if !editor_field_exists(scene, index, field) do return false
    editor_finish_edit()
    before := editor_asset_value(scene, index, field)
    if before == value || !editor_apply_asset(scene, index, field, value) do return false
    editor_push_command({kind = .Edit_Asset, entity = Entity(index), field = field, asset_before = before, asset_after = editor_asset_value(scene, index, field)})
    return true
}