package main

import "core:fmt"
import "core:math"

g_editor_selected: Entity = Entity(-1)
g_editor_file_status: string

editor_draw_scene :: proc(scene: ^Scene){
    ui_next_window(16, 462, 300, 360)

    if ui_begin_panel("Scene"){
        // Undo/Redo
        ui_begin_disabled(
            g_editor_history_cursor == 0 && !g_editor_pending_changed,
        )
        if ui_button("Undo") {
            editor_undo(scene)
        }
        ui_end_disabled()

        ui_begin_disabled(
            g_editor_pending_changed ||
            g_editor_history_cursor >= g_editor_history_count,
        )
        if ui_button("Redo") {
            editor_redo(scene)
        }
        ui_end_disabled()

        history_buffer: [64]u8
        debug_ui_text(fmt.bprintf(
            history_buffer[:],
            "Undo: %d | Redo: %d",
            g_editor_history_cursor,
            g_editor_history_count - g_editor_history_cursor,
        ))

        ui_begin_disabled(
            !editor_can_duplicate_mesh(scene, g_editor_selected),
        )

        if ui_button("Duplicate Selected") {
            editor_duplicate_selected(scene)
        }

        ui_end_disabled()

        if editor_find_available_mesh_slot(scene) < 0 {
            debug_ui_text("No reusable slots (undo history may retain deleted IDs).")
        }

        ui_begin_disabled(
            !editor_can_delete_mesh(scene, g_editor_selected),
        )

        if ui_button("Delete Selected") {
            editor_delete_selected(scene)
        }

        ui_end_disabled()

        ui_separator()

        // Save/Load
        if ui_button("Save Scene"){
            editor_finish_edit()
            _, g_editor_file_status = scene_save_to_file(
                scene,
                SCENE_FILE_PATH
            )
        }

        if ui_button("Load Scene"){
            ok, message := scene_load_from_file(SCENE_FILE_PATH)
            g_editor_file_status = message

            if ok{
                editor_clear_history()
                g_editor_selected = Entity(-1)
                renderer_update_post_title()
            }
        }

        debug_ui_text(SCENE_FILE_PATH)

        if len(g_editor_file_status) > 0 {
            debug_ui_text(g_editor_file_status)
        }

        ui_separator()

        label_buffer: [128]u8

        for i in 0..<scene.entity_count{
            if !scene.alive[i] {
                continue
            }

            if !scene.has_mesh_renderer[i] && !scene.has_directional_light[i] && !scene.has_point_light[i]{
                continue
            }

            name := scene.names[i]
            if len(name) == 0{
                name = "Entity"
            }

            // The hidden suffix makes each selectable entry's ID unique
            label := fmt.bprintf(label_buffer[:127], "%s###entity_%d", name, i,)
            label_buffer[len(label)] = 0

            if ui_selectable(cstring(raw_data(label_buffer[:])), g_editor_selected == Entity(i)){
                editor_finish_edit()
                g_editor_selected = Entity(i)
            }
        }
    }

    ui_end_panel()
}

editor_draw_material_controls :: proc(scene: ^Scene, index: int) {
    if !scene.has_material[index] {
        return
    }

    material := &scene.materials[index]

    ui_separator()
    debug_ui_text("Material")

    editor_color(scene, index, .Material_Tint, "Tint")

    if material.roughness_texture == .Stone_Roughness {
        editor_checkbox(
            scene, index, .Material_Use_Roughness_Map, "Use roughness map",
        )
    }

    editor_slider(
        scene, index, .Material_Roughness, "Roughness", 0.08, 1.0,
    )

    if material.use_roughness_map {
        debug_ui_text("Roughness multiplies the texture's values.")
    }

    editor_slider(
        scene, index, .Material_Metallic, "Metallic", 0.0, 1.0,
    )

    if material.normal_texture == .Stone_Normal {
        editor_slider(
            scene, index, .Material_Normal_Strength, "Normal strength", 0.0, 2.0,
        )
    }

    editor_drag_number(
        scene, index, .Material_UV_Scale, "UV tiling", 0.1, 0.1, 32.0,
    )
}

editor_draw_point_light_controls :: proc(scene: ^Scene, index: int) {
    light := &scene.point_lights[index]

    ui_separator()
    debug_ui_text("Point light")

    editor_color(scene, index, .Point_Color, "Light color")
    editor_slider(scene, index, .Point_Intensity, "Intensity", 0.0, 20.0)
    editor_checkbox(scene, index, .Point_Orbit_Enabled, "Orbit enabled")

    if light.orbit_enabled {
        editor_drag_number(
            scene, index, .Point_Orbit_Radius, "Orbit radius", 0.05, 0.0, 20.0,
        )

        editor_drag_number(
            scene, index, .Point_Orbit_Height, "Orbit height", 0.05, 0.0, 0.0,
        )

        editor_drag_number(
            scene, index, .Point_Orbit_Speed, "Orbit (degrees/s)",
            1.0, -180.0, 180.0,
            degrees = true,
        )

        debug_ui_text("Disable orbit to edit Position manually.")
    }
}

editor_draw_directional_light_controls :: proc(scene: ^Scene, index: int) {
    ui_separator()
    debug_ui_text("Directional light")

    editor_color(scene, index, .Sun_Color, "Light color")
    editor_slider(scene, index, .Sun_Intensity, "Intensity", 0.0, 10.0)
    editor_drag_vector(scene, index, .Sun_Direction, "Direction", 0.02)

    debug_ui_text("Direction points along the light rays.")
    debug_ui_text("Negative Y sends light downward.")
}

editor_draw_inspector :: proc(scene: ^Scene) {
    ui_next_window(392, 16, 380, 560)

    if ui_begin_panel("Inspector") {
        index := int(g_editor_selected)

        if scene_entity_is_alive(scene, g_editor_selected) {
            text_buffer: [128]u8
            debug_ui_text(fmt.bprintf(
                text_buffer[:],
                "%s | Entity %d",
                scene.names[index],
                index,
            ))
            debug_ui_text("Drag values; Ctrl+click to type.")
            ui_separator()

            ui_push_id(i32(index))

            if scene.has_transform[index] {
                transform := &scene.transforms[index]

                orbiting := scene.has_point_light[index] &&
                            scene.point_lights[index].orbit_enabled

                before_position := editor_value(scene, index, .Position)

                ui_begin_disabled(orbiting)
                position_changed := ui_drag_float3(
                    "Position", &transform.position, 0.05,
                )
                editor_track_edit(
                    scene, index, .Position, before_position, position_changed,
                )
                ui_end_disabled()

                before_rotation := editor_value(scene, index, .Y_Rotation)
                rotation_degrees := math.to_degrees(transform.rotation)
                rotation_changed := ui_drag_float(
                    "Y rotation",
                    &rotation_degrees,
                    1.0,
                    0.0,
                    0.0,
                )
                if rotation_changed {
                    transform.rotation = math.to_radians(rotation_degrees)
                }
                editor_track_edit(
                    scene, index, .Y_Rotation, before_rotation, rotation_changed,
                )

                before_scale := editor_value(scene, index, .Uniform_Scale)

                scale_changed := ui_drag_float(
                    "Uniform scale",
                    &transform.scale,
                    0.02,
                    0.05,
                    100.0,
                )
                editor_track_edit(
                    scene, index, .Uniform_Scale, before_scale, scale_changed,
                )

                before_spin := editor_value(scene, index, .Spin)
                spin_degrees := math.to_degrees(transform.rotation_speed)

                spin_changed := ui_drag_float(
                    "Spin (degrees/s)",
                    &spin_degrees,
                    1.0,
                    -180.0,
                    180.0,
                )
                if spin_changed {
                    transform.rotation_speed = math.to_radians(spin_degrees)
                }
                editor_track_edit(
                    scene, index, .Spin, before_spin, spin_changed,
                )
            }

            if scene.has_point_light[index] {
                editor_draw_point_light_controls(scene, index)
            }

            if scene.has_directional_light[index] {
                editor_draw_directional_light_controls(scene, index)
            }

            if scene.has_material[index] && !scene.has_point_light[index] {
                editor_draw_material_controls(scene, index)
            }

            ui_pop_id()
        } else {
            debug_ui_text("Select an entity in the Scene panel.")
        }
    }

    ui_end_panel()
}