package main

// Inspector widgets bound to one EditorField of an entity: each shows the
// field's value, applies changes through editor_apply_value (which clamps
// them), and turns a drag into a single undo step with editor_track_edit.

import "core:math"

editor_slider :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    label: cstring,
    minimum, maximum: f32,
) {
    before := editor_value(scene, index, field)
    value := before[0]

    changed := ui_slider_float(label, &value, minimum, maximum)
    if changed {
        changed = editor_apply_value(
            scene, Entity(index), field, {value, 0, 0},
        )
    }

    editor_track_edit(scene, index, field, before, changed)
}

editor_drag_number :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    label: cstring,
    speed, minimum, maximum: f32,
    degrees := false,
) {
    before := editor_value(scene, index, field)
    value := before[0]

    if degrees {
        value = math.to_degrees(value)
    }

    changed := ui_drag_float(label, &value, speed, minimum, maximum)
    if changed {
        if degrees {
            value = math.to_radians(value)
        }

        changed = editor_apply_value(
            scene, Entity(index), field, {value, 0, 0},
        )
    }

    editor_track_edit(scene, index, field, before, changed)
}

editor_drag_vector :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    label: cstring,
    speed: f32,
    degrees := false,
) {
    before := editor_value(scene, index, field)
    value := before

    if degrees {
        value = {math.to_degrees(value.x), math.to_degrees(value.y), math.to_degrees(value.z)}
    }

    changed := ui_drag_float3(label, &value, speed)
    if changed {
        if degrees {
            value = {math.to_radians(value.x), math.to_radians(value.y), math.to_radians(value.z)}
        }

        changed = editor_apply_value(scene, Entity(index), field, value)
    }

    editor_track_edit(scene, index, field, before, changed)
}

editor_checkbox :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    label: cstring,
) {
    before := editor_value(scene, index, field)
    value := before[0] != 0

    changed := ui_checkbox(label, &value)
    if changed {
        changed = editor_apply_value(
            scene, Entity(index), field, editor_bool_value(value),
        )
    }

    editor_track_edit(scene, index, field, before, changed)
}

editor_color :: proc(
    scene: ^Scene,
    index: int,
    field: EditorField,
    label: cstring,
) {
    before := editor_value(scene, index, field)
    value := before

    changed := debug_ui_linear_color(label, &value)
    if changed {
        changed = editor_apply_value(scene, Entity(index), field, value)
    }

    editor_track_edit(scene, index, field, before, changed)
}