package main

MAX_EDITOR_HISTORY :: 128

EditorTransformField :: enum {
    Position,
    Y_Rotation,
    Uniform_Scale,
    Spin,
}

EditorTransformCommand :: struct {
    entity: Entity,
    field: EditorTransformField,

    // Position uses all three values.
    // Scalar properties use the first value.
    before: [3]f32,
    after: [3]f32,
}

g_editor_history: [MAX_EDITOR_HISTORY]EditorTransformCommand
g_editor_history_count: int

// Number of commands currently applied.
// Commands from cursor to count are available for redo.
g_editor_history_cursor: int

g_editor_pending_edit: EditorTransformCommand
g_editor_pending_active: bool
g_editor_pending_changed: bool

editor_transform_value :: proc(
    scene: ^Scene,
    index: int,
    field: EditorTransformField,
) -> [3]f32 {
    transform := scene.transforms[index]

    switch field {
        case .Position:
            return transform.position
        case .Y_Rotation:
            return {transform.rotation, 0, 0}
        case .Uniform_Scale:
            return {transform.scale, 0, 0}
        case .Spin:
            return {transform.rotation_speed, 0, 0}
    }

    return {}
}

editor_apply_transform_value :: proc(
    scene: ^Scene,
    entity: Entity,
    field: EditorTransformField,
    value: [3]f32,
) -> bool {
    index := int(entity)

    if index < 0 || index >= scene.entity_count ||
       !scene.has_transform[index] {
        return false
    }

    transform := &scene.transforms[index]

    switch field {
        case .Position:
            transform.position = value
        case .Y_Rotation:
            transform.rotation = value[0]
        case .Uniform_Scale:
            transform.scale = value[0]
        case .Spin:
            transform.rotation_speed = value[0]
    }

    return true
}

editor_push_transform_command :: proc(command: EditorTransformCommand) {
    if command.before == command.after {
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

editor_finish_transform_edit :: proc() {
    if !g_editor_pending_active {
        return
    }

    if g_editor_pending_changed {
        editor_push_transform_command(g_editor_pending_edit)
    }

    g_editor_pending_active = false
    g_editor_pending_changed = false
}

editor_track_transform_edit :: proc(
    scene: ^Scene,
    index: int,
    field: EditorTransformField,
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
        editor_finish_transform_edit()

        g_editor_pending_edit = EditorTransformCommand{
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
            g_editor_pending_edit.after = editor_transform_value(
                scene, index, field,
            )
            g_editor_pending_changed = true
        }

        if deactivated {
            // Read the final value, including a possible cancelled edit.
            if g_editor_pending_changed {
                g_editor_pending_edit.after = editor_transform_value(
                    scene, index, field,
                )
            }
            editor_finish_transform_edit()
        }
    }
}

editor_finish_idle_transform_edit :: proc() {
    if g_editor_pending_active && !ui_any_item_active() {
        editor_finish_transform_edit()
    }
}

editor_undo_transform :: proc(scene: ^Scene) {
    editor_finish_transform_edit()

    if g_editor_history_cursor == 0 {
        return
    }

    command := g_editor_history[g_editor_history_cursor - 1]

    if editor_apply_transform_value(
        scene, command.entity, command.field, command.before,
    ) {
        g_editor_history_cursor -= 1
        g_editor_selected = command.entity
    }
}

editor_redo_transform :: proc(scene: ^Scene) {
    editor_finish_transform_edit()

    if g_editor_history_cursor >= g_editor_history_count {
        return
    }

    command := g_editor_history[g_editor_history_cursor]

    if editor_apply_transform_value(
        scene, command.entity, command.field, command.after,
    ) {
        g_editor_history_cursor += 1
        g_editor_selected = command.entity
    }
}

editor_clear_transform_history :: proc() {
    g_editor_history_count = 0
    g_editor_history_cursor = 0
    g_editor_pending_active = false
    g_editor_pending_changed = false
}