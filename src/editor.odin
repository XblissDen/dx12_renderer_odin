package main

import "core:fmt"
import "core:math"

g_editor_selected: Entity = Entity(-1)
// The entity whose material slot g_editor_material_slot refers to.
g_editor_material_entity := -1
g_editor_file_status: string

editor_draw_scene :: proc(scene: ^Scene){
    ui_next_window(16, 462, 300, 360)

    if ui_begin_panel("Scene"){
        if ui_button("Assets...") do g_editor_import.open = true
        editor_model_picker("New model", &g_editor_model_to_add)
        ui_begin_disabled(!assets_mesh_valid(g_editor_model_to_add) || editor_find_available_mesh_slot(scene) < 0)
        if ui_button("Add Model") do editor_add_model(scene, g_editor_model_to_add)
        ui_end_disabled()
        ui_begin_disabled(editor_find_available_mesh_slot(scene) < 0 || scene_local_light_count(scene) >= MAX_LIGHTS)
        if ui_button("Add Point Light") do editor_add_point_light(scene)
        ui_same_line()
        if ui_button("Add Spot Light") do editor_add_spot_light(scene)
        ui_end_disabled()
        if scene_local_light_count(scene) >= MAX_LIGHTS {
            ui_same_line()
            debug_ui_text("(limit reached)")
        }
        ui_separator()
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

        _, _, can_focus := editor_selection_bounds(scene)
        ui_begin_disabled(!can_focus)
        if ui_button("Focus Selected") {
            editor_focus_selected(scene)
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

            if !scene.has_mesh_renderer[i] && !scene.has_directional_light[i] && !scene.has_point_light[i] && !scene.has_spot_light[i] {
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

    ui_separator()
    debug_ui_text("Material")

    // Multi-material models (glTF): choose which submesh material to edit.
    if g_editor_material_entity != index {
        g_editor_material_entity = index
        g_editor_material_slot = 0
    }
    slot_count := scene_material_count(scene, index)
    g_editor_material_slot = clamp(g_editor_material_slot, 0, slot_count - 1)
    if slot_count > 1 {
        names := &g_assets.meshes[scene.mesh_renderers[index].mesh].material_names
        preview := names[g_editor_material_slot]
        if preview == nil do preview = "Material"
        if ui_begin_combo("Slot", preview) {
            for slot in 0..<slot_count {
                label := names[slot] if names[slot] != nil else "Material"
                ui_push_id(i32(slot))
                if ui_selectable(label, slot == g_editor_material_slot) {
                    editor_finish_edit()
                    g_editor_material_slot = slot
                }
                ui_pop_id()
            }
            ui_end_combo()
        }
    }

    material := editor_material(scene, index)

    editor_draw_texture_controls(scene, index)
    editor_color(scene, index, .Material_Tint, "Tint")

    editor_slider(
        scene, index, .Material_Roughness, "Roughness", 0.08, 1.0,
    )

    if material.use_roughness_map {
        debug_ui_text("Roughness multiplies the texture's values.")
    }

    editor_slider(
        scene, index, .Material_Metallic, "Metallic", 0.0, 1.0,
    )
    if material.use_metallic_map {
        debug_ui_text("Metallic multiplies the map; 1 = original.")
    }

    if material.normal_strength > 0 {
        editor_slider(
            scene, index, .Material_Normal_Strength,
            "Normal strength", 0.01, 2.0,
        )
    }

    editor_drag_number(
        scene, index, .Material_UV_Scale, "UV tiling", 0.1, 0.1, 32.0,
    )

    editor_color(scene, index, .Material_Emissive, "Emission")
    editor_drag_number(
        scene, index, .Material_Emissive_Strength, "Emission strength", 0.05, 0.0, 100.0,
    )
    if material.use_emissive_map && (material.emissive == {} || material.emissive_strength == 0) {
        debug_ui_text("Set an emission color and strength to see the map.")
    }

    if material.use_occlusion_map {
        editor_slider(
            scene, index, .Material_Occlusion_Strength, "Occlusion strength", 0.0, 1.0,
        )
    }

    // How albedo alpha is used: ignored, cut out below a cutoff, or blended.
    alpha_modes := [3]cstring{"Opaque", "Cutout", "Blend"}
    alpha_mode := int(editor_value(scene, index, .Material_Alpha_Mode)[0])
    if ui_begin_combo("Alpha", alpha_modes[alpha_mode]) {
        for name, mode in alpha_modes {
            if ui_selectable(name, mode == alpha_mode) {
                editor_commit_value(scene, index, .Material_Alpha_Mode, {f32(mode), 0, 0})
            }
        }
        ui_end_combo()
    }
    if material.alpha_blend {
        editor_slider(scene, index, .Material_Opacity, "Opacity", 0.0, 1.0)
    } else if material.alpha_mask {
        editor_slider(scene, index, .Material_Alpha_Cutoff, "Alpha cutoff", 0.0, 1.0)
    }
    editor_checkbox(scene, index, .Material_Double_Sided, "Double-sided")
}

editor_draw_point_light_controls :: proc(scene: ^Scene, index: int) {
    light := &scene.point_lights[index]

    ui_separator()
    debug_ui_text("Point light")

    editor_color(scene, index, .Point_Color, "Light color")
    editor_slider(scene, index, .Point_Intensity, "Intensity", 0.0, 20.0)
    editor_drag_number(scene, index, .Point_Range, "Range", 0.05, 0.1, 1000.0)
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

editor_draw_spot_light_controls :: proc(scene: ^Scene, index: int) {
    ui_separator()
    debug_ui_text("Spot light")

    editor_color(scene, index, .Spot_Color, "Light color")
    editor_slider(scene, index, .Spot_Intensity, "Intensity", 0.0, 50.0)
    editor_drag_number(scene, index, .Spot_Range, "Range", 0.05, 0.1, 1000.0)
    editor_drag_number(scene, index, .Spot_Inner_Angle, "Inner angle", 0.5, 0.0, 89.0, degrees = true)
    editor_drag_number(scene, index, .Spot_Outer_Angle, "Outer angle", 0.5, 1.0, 89.0, degrees = true)
    editor_checkbox(scene, index, .Spot_Cast_Shadows, "Cast shadows")
    if scene.spot_lights[index].cast_shadows {
        has_slot := false
        for entity in g_renderer.spot_shadow_entities do has_slot ||= entity == index
        text_buffer: [96]u8
        debug_ui_text("Shadow: on" if has_slot else fmt.bprintf(text_buffer[:],
            "Shadow: off (only the %d nearest shadowed spots get one)", SPOT_SHADOW_COUNT))
    }
    debug_ui_text("Aim it with Rotation or the rotate gizmo (E):")
    debug_ui_text("it shines along the marker's base (local -Y).")
}

editor_draw_directional_light_controls :: proc(scene: ^Scene, index: int) {
    ui_separator()
    debug_ui_text("Directional light")

    if hdri_sun, ok := renderer_hdri_sun(); ok {
        text_buffer: [128]u8
        debug_ui_text("Driven by the HDRI's sun. Clear \"Sun from HDRI\"")
        debug_ui_text("in Renderer controls to edit these values.")
        debug_ui_text(fmt.bprintf(
            text_buffer[:], "Intensity %.2f | Direction %.2f %.2f %.2f",
            hdri_sun.intensity, hdri_sun.direction.x, hdri_sun.direction.y, hdri_sun.direction.z,
        ))
        return
    }

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

                if !scene.has_camera[index] {
                    editor_draw_gizmo_controls()
                    ui_separator()
                }

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

                editor_drag_vector(
                    scene, index, .Rotation, "Rotation (degrees)", 1.0,
                    degrees = true,
                )
                editor_drag_vector(scene, index, .Scale, "Scale", 0.02)

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

            editor_draw_mesh_controls(scene, index)

            if scene.has_point_light[index] {
                editor_draw_point_light_controls(scene, index)
            }

            if scene.has_spot_light[index] {
                editor_draw_spot_light_controls(scene, index)
            }

            if scene.has_directional_light[index] {
                editor_draw_directional_light_controls(scene, index)
            }

            // A light's marker material follows the light; it is not edited.
            if scene.has_material[index] && !scene.has_point_light[index] && !scene.has_spot_light[index] {
                editor_draw_material_controls(scene, index)
            }

            ui_pop_id()
        } else {
            debug_ui_text("Select an entity in the Scene panel.")
        }
    }

    ui_end_panel()
}
