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
    Material_Emissive,
    Material_Emissive_Strength,
    Material_Occlusion_Strength,
    Material_Alpha_Mode, // 0 opaque, 1 cutout, 2 blend
    Material_Opacity,    // Shown as 1 - transparency.
    Material_Alpha_Cutoff,
    Material_Double_Sided,

    Point_Color,
    Point_Intensity,
    Point_Orbit_Enabled,
    Point_Orbit_Radius,
    Point_Orbit_Center,
    Point_Orbit_Speed,
    Point_Range,
    Point_Cast_Shadows,

    Spot_Color,
    Spot_Intensity,
    Spot_Range,
    Spot_Inner_Angle,
    Spot_Outer_Angle,
    Spot_Cast_Shadows,

    Sun_Color,
    Sun_Intensity,
    Sun_Direction,

    Mesh_Asset,
    Material_Albedo_Texture,
    Material_Normal_Map,
    Material_Roughness_Map,
    Material_Metallic_Map,
    Material_Emissive_Map,
    Material_Occlusion_Map,

    // The parent's index in the first value; -1 for none.
    Parent,
}

EditorCommandKind :: enum {
    Edit_Field,
    Create_Mesh,
    Delete_Mesh,
    Edit_Asset,
    // One step made of several: field edits of several entities (a gizmo
    // drag on a multiple selection), or several creations or deletions.
    Edit_Fields,
    Group,
}

// One field change within an Edit_Fields command.
EditorFieldEdit :: struct {
    entity: Entity,
    field: EditorField,
    before, after: [3]f32,
}

EditorAssetValue :: struct {
    mesh: MeshHandle,
    texture: TextureHandle,
    strength: f32,
    enabled: bool,
}

// An entity the editor creates or deletes: a model, a point or spot light
// with its marker mesh, or an empty one (a group, such as a glTF node without
// geometry).
EditorMeshSnapshot :: struct {
    name: string,
    transform: Transform,
    // With a mesh, the entity also gets the materials.
    mesh_renderer: Maybe(MeshRenderer),
    material: Material,
    material_slots: MaterialSlots,
    point_light: Maybe(PointLight),
    spot_light: Maybe(SpotLight),
    // Restored as a link even while the parent is not alive yet: undoing a
    // deleted subtree restores the children before their parents.
    parent: Maybe(Entity),
}

// The Inspector edits one material slot at a time; each undo step records
// which one, and undo/redo select it again before applying.
g_editor_material_slot: int

editor_material :: proc(scene: ^Scene, index: int) -> ^Material {
    return scene_material(scene, index, g_editor_material_slot)
}

EditorCommand :: struct {
    kind: EditorCommandKind,

    entity: Entity,
    field: EditorField,

    // Vector fields use all three values and scalar ones the first; asset
    // references use the typed payload below.
    before: [3]f32,
    after: [3]f32,
    asset_before, asset_after: EditorAssetValue,

    mesh_snapshot: EditorMeshSnapshot,
    // Material slot for material fields (see g_editor_material_slot).
    material_slot: int,
    source_entity: Entity,

    // Heap-allocated parts of Edit_Fields and Group commands, freed when the
    // command leaves the history. `entity` is then the primary selection.
    edits: []EditorFieldEdit,
    group: []EditorCommand,
}

g_editor_history: [MAX_EDITOR_HISTORY]EditorCommand
g_editor_history_count: int

// Number of commands currently applied; those from the cursor to the count
// can be redone.
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
             .Material_Emissive,
             .Material_Emissive_Strength,
             .Material_Occlusion_Strength,
             .Material_Alpha_Mode,
             .Material_Opacity,
             .Material_Alpha_Cutoff,
             .Material_Double_Sided,
             .Material_Albedo_Texture,
             .Material_Normal_Map,
             .Material_Roughness_Map,
             .Material_Metallic_Map,
             .Material_Emissive_Map,
             .Material_Occlusion_Map:
            return scene.has_material[index]

        case .Point_Orbit_Center:
            return scene.has_point_light[index] &&
                   scene.has_transform[index]

        case .Point_Color,
             .Point_Intensity,
             .Point_Orbit_Enabled,
             .Point_Orbit_Radius,
             .Point_Orbit_Speed,
             .Point_Range,
             .Point_Cast_Shadows:
            return scene.has_point_light[index]

        case .Spot_Color,
             .Spot_Intensity,
             .Spot_Range,
             .Spot_Inner_Angle,
             .Spot_Outer_Angle,
             .Spot_Cast_Shadows:
            return scene.has_spot_light[index]

        case .Sun_Color, .Sun_Intensity, .Sun_Direction:
            return scene.has_directional_light[index]

        case .Mesh_Asset:
            return scene.has_mesh_renderer[index]

        case .Parent:
            return scene_parentable(scene, index)
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
            return editor_material(scene, index).tint
        case .Material_Roughness:
            return {editor_material(scene, index).roughness, 0, 0}
        case .Material_Metallic:
            return {editor_material(scene, index).metallic, 0, 0}
        case .Material_Normal_Strength:
            return {editor_material(scene, index).normal_strength, 0, 0}
        case .Material_UV_Scale:
            return {editor_material(scene, index).uv_scale, 0, 0}
        case .Material_Use_Roughness_Map:
            return editor_bool_value(editor_material(scene, index).use_roughness_map)
        case .Material_Emissive:
            return editor_material(scene, index).emissive
        case .Material_Emissive_Strength:
            return {editor_material(scene, index).emissive_strength, 0, 0}
        case .Material_Occlusion_Strength:
            return {editor_material(scene, index).occlusion_strength, 0, 0}
        case .Material_Alpha_Mode:
            material := editor_material(scene, index)
            return {2 if material.alpha_blend else 1 if material.alpha_mask else 0, 0, 0}
        case .Material_Opacity:
            return {1 - editor_material(scene, index).transparency, 0, 0}
        case .Material_Alpha_Cutoff:
            return {editor_material(scene, index).alpha_cutoff, 0, 0}
        case .Material_Double_Sided:
            return editor_bool_value(editor_material(scene, index).double_sided)
        case .Material_Albedo_Texture, .Material_Normal_Map, .Material_Roughness_Map, .Material_Metallic_Map,
             .Material_Emissive_Map, .Material_Occlusion_Map, .Mesh_Asset:
            panic("Use typed asset history for asset references")

        case .Point_Color:
            return scene.point_lights[index].color
        case .Point_Intensity:
            return {scene.point_lights[index].intensity, 0, 0}
        case .Point_Orbit_Enabled:
            return editor_bool_value(scene.point_lights[index].orbit_enabled)
        case .Point_Orbit_Radius:
            return {scene.point_lights[index].orbit_radius, 0, 0}
        case .Point_Orbit_Center:
            return scene.point_lights[index].orbit_center
        case .Point_Orbit_Speed:
            return {scene.point_lights[index].orbit_speed, 0, 0}
        case .Point_Range:
            return {scene.point_lights[index].range, 0, 0}
        case .Point_Cast_Shadows:
            return editor_bool_value(scene.point_lights[index].cast_shadows)
        case .Spot_Color:
            return scene.spot_lights[index].color
        case .Spot_Intensity:
            return {scene.spot_lights[index].intensity, 0, 0}
        case .Spot_Range:
            return {scene.spot_lights[index].range, 0, 0}
        case .Spot_Inner_Angle:
            return {scene.spot_lights[index].inner_angle, 0, 0}
        case .Spot_Outer_Angle:
            return {scene.spot_lights[index].outer_angle, 0, 0}
        case .Spot_Cast_Shadows:
            return editor_bool_value(scene.spot_lights[index].cast_shadows)

        case .Sun_Color:
            return scene.directional_lights[index].color
        case .Sun_Intensity:
            return {scene.directional_lights[index].intensity, 0, 0}
        case .Sun_Direction:
            return scene.directional_lights[index].direction

        case .Parent:
            parent, ok := scene_parent(scene, index)
            return {f32(parent) if ok else -1, 0, 0}
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
            editor_material(scene, index).tint = value
        case .Material_Roughness:
            editor_material(scene, index).roughness = value[0]
        case .Material_Metallic:
            editor_material(scene, index).metallic = value[0]
        case .Material_Normal_Strength:
            editor_material(scene, index).normal_strength = value[0]
        case .Material_UV_Scale:
            editor_material(scene, index).uv_scale = value[0]
        case .Material_Use_Roughness_Map:
            editor_material(scene, index).use_roughness_map = value[0] != 0
        case .Material_Emissive:
            editor_material(scene, index).emissive = value
        case .Material_Emissive_Strength:
            editor_material(scene, index).emissive_strength = max(value[0], 0)
        case .Material_Occlusion_Strength:
            editor_material(scene, index).occlusion_strength = clamp(value[0], 0, 1)
        case .Material_Alpha_Mode:
            editor_material(scene, index).alpha_mask = value[0] == 1
            editor_material(scene, index).alpha_blend = value[0] == 2
        case .Material_Opacity:
            editor_material(scene, index).transparency = 1 - clamp(value[0], 0, 1)
        case .Material_Alpha_Cutoff:
            editor_material(scene, index).alpha_cutoff = clamp(value[0], 0, 1)
        case .Material_Double_Sided:
            editor_material(scene, index).double_sided = value[0] != 0
        case .Material_Albedo_Texture, .Material_Normal_Map, .Material_Roughness_Map, .Material_Metallic_Map,
             .Material_Emissive_Map, .Material_Occlusion_Map, .Mesh_Asset:
            return false

        case .Point_Color:
            scene.point_lights[index].color = value
        case .Point_Intensity:
            scene.point_lights[index].intensity = value[0]
        case .Point_Orbit_Enabled:
            light := &scene.point_lights[index]
            // Start the orbit where the light is instead of jumping onto it.
            if value[0] != 0 && !light.orbit_enabled && scene.has_transform[index] {
                light.orbit_center = orbit_center_through(light^, scene.transforms[index].position)
            }
            light.orbit_enabled = value[0] != 0
        case .Point_Orbit_Radius:
            scene.point_lights[index].orbit_radius = value[0]
        case .Point_Orbit_Center:
            scene.point_lights[index].orbit_center = value
        case .Point_Orbit_Speed:
            scene.point_lights[index].orbit_speed = value[0]
        case .Point_Range:
            scene.point_lights[index].range = max(value[0], 0.1)
        case .Point_Cast_Shadows:
            scene.point_lights[index].cast_shadows = value[0] != 0
        case .Spot_Color:
            scene.spot_lights[index].color = value
        case .Spot_Intensity:
            scene.spot_lights[index].intensity = max(value[0], 0)
        case .Spot_Range:
            scene.spot_lights[index].range = max(value[0], 0.1)
        // The inner angle stays within the outer one.
        case .Spot_Inner_Angle:
            light := &scene.spot_lights[index]
            light.inner_angle = clamp(value[0], 0, light.outer_angle)
        case .Spot_Outer_Angle:
            light := &scene.spot_lights[index]
            light.outer_angle = clamp(value[0], max(light.inner_angle, math.to_radians(f32(1))), SPOT_MAX_ANGLE)
        case .Spot_Cast_Shadows:
            scene.spot_lights[index].cast_shadows = value[0] != 0

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

        // Only the link; editor_set_parents also keeps the world placement.
        case .Parent:
            parent := int(value[0])
            if !scene_can_parent(scene, index, parent) do return false
            scene_set_parent(scene, index, parent)
    }

    return true
}

editor_push_command :: proc(command: EditorCommand) {
    if command.kind == .Edit_Field && command.before == command.after {
        return
    }
    if command.kind == .Edit_Asset && command.asset_before == command.asset_after do return

    // An edit after undo starts a new branch and discards the redo commands.
    for i in g_editor_history_cursor..<g_editor_history_count do editor_free_command(&g_editor_history[i])
    g_editor_history_count = g_editor_history_cursor

    if g_editor_history_count == MAX_EDITOR_HISTORY {
        editor_free_command(&g_editor_history[0])
        for i in 1..<g_editor_history_count {
            g_editor_history[i - 1] = g_editor_history[i]
        }
        g_editor_history_count -= 1
    }

    g_editor_history[g_editor_history_count] = command
    g_editor_history_count += 1
    g_editor_history_cursor = g_editor_history_count
}

editor_free_command :: proc(command: ^EditorCommand) {
    delete(command.edits)
    delete(command.group)
    command.edits = nil
    command.group = nil
}

// Pushes several creations or deletions as one undo step; `primary` becomes
// the primary selection when the step is undone or redone.
editor_push_commands :: proc(commands: []EditorCommand, primary: Entity) {
    switch len(commands) {
        case 0:
        case 1: editor_push_command(commands[0])
        case:
            group := make([]EditorCommand, len(commands))
            copy(group, commands)
            editor_push_command(EditorCommand{kind = .Group, entity = primary, group = group})
    }
}

// Pushes field edits of several entities as one undo step, leaving out those
// that did not change.
editor_push_field_edits :: proc(edits: []EditorFieldEdit, primary: Entity) {
    changed := make([dynamic]EditorFieldEdit, 0, len(edits))
    for edit in edits do if edit.before != edit.after do append(&changed, edit)
    if len(changed) <= 1 {
        for edit in changed {
            editor_push_command(EditorCommand{kind = .Edit_Field, entity = edit.entity, field = edit.field, before = edit.before, after = edit.after})
        }
        delete(changed)
        return
    }
    editor_push_command(EditorCommand{kind = .Edit_Fields, entity = primary, edits = changed[:]})
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

// Turns a widget's frame-by-frame changes into one undo step: the step starts
// when the widget activates (or first changes) with `before`, and is pushed
// when it deactivates. Call right after the widget, which it queries.
editor_track_edit :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    before: [3]f32,
    changed: bool,
) {
    activated := ui_item_activated()
    deactivated := ui_item_deactivated()

    matching := g_editor_pending_active &&
                g_editor_pending_edit.entity == Entity(index) &&
                g_editor_pending_edit.field == field &&
                g_editor_pending_edit.material_slot == g_editor_material_slot

    if activated || (changed && !matching) {
        editor_finish_edit()

        g_editor_pending_edit = EditorCommand{
            entity = Entity(index),
            field = field,
            before = before,
            after = before,
            material_slot = g_editor_material_slot,
        }
        g_editor_pending_active = true
        g_editor_pending_changed = false
    }

    matching = g_editor_pending_active &&
               g_editor_pending_edit.entity == Entity(index) &&
               g_editor_pending_edit.field == field &&
               g_editor_pending_edit.material_slot == g_editor_material_slot

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

// Whether an undo step could bring back or select the entity in `slot`, so
// the slot must not be reused yet. Redo steps do not count: the next push,
// which reusing the slot makes, discards them.
editor_slot_referenced_by_history :: proc(slot: int) -> bool {
    for i in 0..<g_editor_history_cursor {
        command := g_editor_history[i]

        if editor_command_references(command, slot) {
            return true
        }
    }

    return false
}

editor_command_references :: proc(command: EditorCommand, slot: int) -> bool {
    if int(command.entity) == slot do return true
    // Undoing a duplicate selects its original source, too.
    if command.kind == .Create_Mesh && int(command.source_entity) == slot do return true
    if parent, ok := command.mesh_snapshot.parent.?; ok && int(parent) == slot do return true
    // A reparenting names the parents in its values.
    if command.kind == .Edit_Field && command.field == .Parent &&
       (int(command.before[0]) == slot || int(command.after[0]) == slot) {
        return true
    }
    for edit in command.edits {
        if int(edit.entity) == slot do return true
        if edit.field == .Parent && (int(edit.before[0]) == slot || int(edit.after[0]) == slot) do return true
    }
    for part in command.group do if editor_command_references(part, slot) do return true
    return false
}

editor_undo :: proc(scene: ^Scene) {
    editor_finish_edit()

    if g_editor_history_cursor == 0 {
        return
    }

    command := g_editor_history[g_editor_history_cursor - 1]
    if editor_apply_command(scene, command, redo = false) {
        g_editor_history_cursor -= 1
        editor_select_command(command, redo = false)
    }
}

editor_redo :: proc(scene: ^Scene) {
    editor_finish_edit()

    if g_editor_history_cursor >= g_editor_history_count {
        return
    }

    command := g_editor_history[g_editor_history_cursor]
    if editor_apply_command(scene, command, redo = true) {
        g_editor_history_cursor += 1
        editor_select_command(command, redo = true)
    }
}

// Undoes (or redoes) one history step. A group is all or nothing: when a
// part fails (a light past the limit), the parts already done are reverted.
editor_apply_command :: proc(scene: ^Scene, command: EditorCommand, redo: bool) -> bool {
    g_editor_material_slot = command.material_slot
    g_editor_material_entity = int(command.entity)

    switch command.kind {
        case .Edit_Asset:
            return editor_apply_asset(scene, int(command.entity), command.field, command.asset_after if redo else command.asset_before)
        case .Edit_Field:
            return editor_apply_value(scene, command.entity, command.field, command.after if redo else command.before)
        case .Edit_Fields:
            // The edited entities all exist whenever this step is next in line.
            count := len(command.edits)
            for k in 0..<count {
                edit := command.edits[k if redo else count - 1 - k]
                editor_apply_value(scene, edit.entity, edit.field, edit.after if redo else edit.before)
            }
            return true
        case .Create_Mesh:
            if redo do return editor_restore_created_mesh(scene, command.entity, command.mesh_snapshot)
            return editor_remove_created_mesh(scene, command.entity)
        case .Delete_Mesh:
            if redo do return editor_delete_mesh(scene, command.entity)
            return editor_restore_deleted_mesh(scene, command.entity, command.mesh_snapshot)
        case .Group:
            count := len(command.group)
            for k in 0..<count {
                if editor_apply_command(scene, command.group[k if redo else count - 1 - k], redo) do continue
                for j := k - 1; j >= 0; j -= 1 {
                    editor_apply_command(scene, command.group[j if redo else count - 1 - j], !redo)
                }
                return false
            }
            return true
    }
    return false
}

// Selects what an undone or redone step touched: the edited entities, an
// undone duplicate's source, or nothing after a redone deletion.
editor_select_command :: proc(command: EditorCommand, redo: bool) {
    editor_clear_selection()
    editor_add_command_selection(command, redo)
    primary := command.entity
    // An undone group of duplicates: the primary copy's source.
    for part in command.group {
        if !redo && part.kind == .Create_Mesh && part.entity == command.entity do primary = part.source_entity
    }
    if editor_is_selected(primary) do g_editor_selected = primary
}

editor_add_command_selection :: proc(command: EditorCommand, redo: bool) {
    switch command.kind {
        case .Edit_Asset, .Edit_Field: editor_add_to_selection(command.entity)
        case .Edit_Fields: for edit in command.edits do editor_add_to_selection(edit.entity)
        case .Create_Mesh: editor_add_to_selection(command.entity if redo else command.source_entity)
        case .Delete_Mesh: if !redo do editor_add_to_selection(command.entity)
        case .Group: for part in command.group do editor_add_command_selection(part, redo)
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
        material_slot = g_editor_material_slot,
    })
    return true
}

editor_clear_history :: proc() {
    for i in 0..<g_editor_history_count do editor_free_command(&g_editor_history[i])
    g_editor_history_count = 0
    g_editor_history_cursor = 0
    g_editor_pending_active = false
    g_editor_pending_changed = false
}

editor_asset_value :: proc(scene: ^Scene, index: int, field: EditorField) -> EditorAssetValue {
    #partial switch field {
        case .Mesh_Asset: return {mesh = scene.mesh_renderers[index].mesh}
        case .Material_Albedo_Texture: return {texture = editor_material(scene, index).texture}
        case .Material_Normal_Map: return {texture = editor_material(scene, index).normal_texture, strength = editor_material(scene, index).normal_strength, enabled = editor_material(scene, index).normal_strength > 0}
        case .Material_Roughness_Map: return {texture = editor_material(scene, index).roughness_texture, enabled = editor_material(scene, index).use_roughness_map}
        case .Material_Metallic_Map: return {texture = editor_material(scene, index).metallic_texture, enabled = editor_material(scene, index).use_metallic_map}
        case .Material_Emissive_Map: return {texture = editor_material(scene, index).emissive_texture, enabled = editor_material(scene, index).use_emissive_map}
        case .Material_Occlusion_Map: return {texture = editor_material(scene, index).occlusion_texture, strength = editor_material(scene, index).occlusion_strength, enabled = editor_material(scene, index).use_occlusion_map}
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
            editor_material(scene, index).texture = value.texture
        case .Material_Normal_Map:
            if !assets_optional_texture_valid(value.texture) || !(value.strength >= 0) || value.enabled != (value.strength > 0) do return false
            if value.strength > 0 && !texture_asset_is_normal(value.texture) do return false
            editor_material(scene, index).normal_texture = value.texture
            editor_material(scene, index).normal_strength = value.strength
        case .Material_Roughness_Map:
            if !assets_optional_texture_valid(value.texture) || (value.enabled && !texture_asset_is_roughness(value.texture)) do return false
            editor_material(scene, index).roughness_texture = value.texture
            editor_material(scene, index).use_roughness_map = value.enabled
        case .Material_Metallic_Map:
            if !assets_optional_texture_valid(value.texture) || (value.enabled && !texture_asset_is_metallic(value.texture)) do return false
            editor_material(scene, index).metallic_texture = value.texture
            editor_material(scene, index).use_metallic_map = value.enabled
        case .Material_Emissive_Map:
            if !assets_optional_texture_valid(value.texture) || (value.enabled && !texture_asset_is_emissive(value.texture)) do return false
            editor_material(scene, index).emissive_texture = value.texture
            editor_material(scene, index).use_emissive_map = value.enabled
        case .Material_Occlusion_Map:
            if !assets_optional_texture_valid(value.texture) || (value.enabled && !texture_asset_is_occlusion(value.texture)) do return false
            if !(value.strength >= 0 && value.strength <= 1) do return false
            editor_material(scene, index).occlusion_texture = value.texture
            editor_material(scene, index).use_occlusion_map = value.enabled
            editor_material(scene, index).occlusion_strength = value.strength
        case: return false
    }
    return true
}

editor_commit_asset :: proc(scene: ^Scene, index: int, field: EditorField, value: EditorAssetValue) -> bool {
    if !editor_field_exists(scene, index, field) do return false
    editor_finish_edit()
    before := editor_asset_value(scene, index, field)
    if before == value || !editor_apply_asset(scene, index, field, value) do return false
    editor_push_command({kind = .Edit_Asset, entity = Entity(index), field = field, asset_before = before, asset_after = editor_asset_value(scene, index, field), material_slot = g_editor_material_slot})
    return true
}