package main

import "core:fmt"
import "core:math"
import alg "core:math/linalg"

g_editor_selected: Entity = Entity(-1)
g_editor_file_status: string

editor_draw_scene :: proc(scene: ^Scene){
    ui_next_window(16, 462, 260, 240)

    if ui_begin_panel("Scene"){
        if ui_button("Save Scene"){
            _, g_editor_file_status = scene_save_to_file(
                scene,
                SCENE_FILE_PATH
            )
        }

        if ui_button("Load Scene"){
            ok, message := scene_load_from_file(SCENE_FILE_PATH)
            g_editor_file_status = message

            if ok{
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
                g_editor_selected = Entity(i)
            }
        }
    }

    ui_end_panel()
}

editor_draw_material_controls :: proc(scene: ^Scene, index: int){
    if !scene.has_material[index]{
        return
    }

    material := &scene.materials[index]

    ui_separator()
    debug_ui_text("Material")

    editor_edit_linear_color("Tint", &material.tint)

    if material.roughness_texture == .Stone_Roughness{
        ui_checkbox("Use roughness map", &material.use_roughness_map)
    }

    ui_slider_float("Roughness", &material.roughness, 0.08, 1.0)

    if material.use_roughness_map{
        debug_ui_text("Roughness multiplies the texture's values.")
    }

    ui_slider_float("Metallic", &material.metallic, 0.0, 1.0)

    if material.normal_texture == .Stone_Normal{
        ui_slider_float("Normal strength", &material.normal_strength, 0.0, 2.0,)
    }

    ui_drag_float("UV tiling", &material.uv_scale, 0.1, 0.1, 32.0)
}

editor_edit_linear_color :: proc(
    label: cstring,
    color: ^[3]f32,
) -> bool {
    picker_color: [3]f32

    for channel in 0..<3 {
        picker_color[channel] = math.pow(
            clamp(color^[channel], 0.0, 1.0),
            1.0 / 2.2,
        )
    }

    if ui_color_edit3(label, &picker_color) {
        for channel in 0..<3 {
            color^[channel] = math.pow(
                clamp(picker_color[channel], 0.0, 1.0),
                2.2,
            )
        }
        return true
    }

    return false
}

editor_draw_point_light_controls :: proc(scene: ^Scene, index: int) {
    light := &scene.point_lights[index]

    ui_separator()
    debug_ui_text("Point light")

    editor_edit_linear_color("Light color", &light.color)
    ui_slider_float("Intensity", &light.intensity, 0.0, 20.0)

    ui_checkbox("Orbit enabled", &light.orbit_enabled)

    if light.orbit_enabled {
        ui_drag_float(
            "Orbit radius",
            &light.orbit_radius,
            0.05,
            0.0,
            20.0,
        )

        ui_drag_float(
            "Orbit height",
            &scene.transforms[index].position.y,
            0.05,
            0.0,
            0.0,
        )

        speed_degrees := math.to_degrees(light.orbit_speed)
        if ui_drag_float(
            "Orbit (degrees/s)",
            &speed_degrees,
            1.0,
            -180.0,
            180.0,
        ) {
            light.orbit_speed = math.to_radians(speed_degrees)
        }

        debug_ui_text("Disable orbit to edit Position manually.")
    }
}

editor_draw_directional_light_controls :: proc(scene: ^Scene, index: int) {
    light := &scene.directional_lights[index]

    ui_separator()
    debug_ui_text("Directional light")

    editor_edit_linear_color("Light color", &light.color)
    ui_slider_float("Intensity", &light.intensity, 0.0, 10.0)

    direction := light.direction
    if ui_drag_float3("Direction", &direction, 0.02) {
        if alg.dot(direction, direction) > 0.00000001 {
            light.direction = alg.normalize(direction)
        }
    }

    debug_ui_text("Direction points along the light rays.")
    debug_ui_text("Negative Y sends light downward.")
}

editor_draw_inspector :: proc(scene: ^Scene) {
    ui_next_window(392, 16, 380, 560)

    if ui_begin_panel("Inspector") {
        index := int(g_editor_selected)

        if index >= 0 && index < scene.entity_count {
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

                ui_begin_disabled(orbiting)
                ui_drag_float3("Position", &transform.position, 0.05)
                ui_end_disabled()

                rotation_degrees := math.to_degrees(transform.rotation)
                if ui_drag_float(
                    "Y rotation",
                    &rotation_degrees,
                    1.0,
                    0.0,
                    0.0,
                ) {
                    transform.rotation = math.to_radians(rotation_degrees)
                }

                ui_drag_float(
                    "Uniform scale",
                    &transform.scale,
                    0.02,
                    0.05,
                    100.0,
                )

                spin_degrees := math.to_degrees(transform.rotation_speed)
                if ui_drag_float(
                    "Spin (degrees/s)",
                    &spin_degrees,
                    1.0,
                    -180.0,
                    180.0,
                ) {
                    transform.rotation_speed = math.to_radians(spin_degrees)
                }
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