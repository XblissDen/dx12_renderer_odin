package main

import "core:fmt"
import "core:math"

g_editor_selected: Entity = Entity(-1)

editor_draw_scene :: proc(scene: ^Scene){
    ui_next_window(16, 462, 260, 240)

    if ui_begin_panel("Scene"){
        label_buffer: [128]u8

        for i in 0..<scene.entity_count{
            if !scene.has_transform[i] || !scene.has_mesh_renderer[i] || scene.has_point_light[i]{
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

    picker_tint: [3]f32
    for channel in 0..<3{
        picker_tint[channel] = math.pow(clamp(material.tint[channel], 0.0, 1.0), 1.0 / 2.2)
    }

    if ui_color_edit3("Tint", &picker_tint) {
        for channel in 0..<3 {
            material.tint[channel] = math.pow(
                clamp(picker_tint[channel], 0.0, 1.0),
                2.2,
            )
        }
    }

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

editor_draw_inspector :: proc(scene: ^Scene){
    ui_next_window(392, 16, 380, 520)

    if ui_begin_panel("Inspector"){
        index := int(g_editor_selected)

        if index >= 0 &&
        index < scene.entity_count &&
        scene.has_transform[index] &&
        scene.has_mesh_renderer[index] &&
        !scene.has_point_light[index]{

            text_buffer: [128]u8
            debug_ui_text(fmt.bprintf(text_buffer[:], "%s | Entity %d", scene.names[index], index))
            debug_ui_text("Drag values; Ctrl+click to type.")
            ui_separator()

            ui_push_id(i32(index))

            transform := &scene.transforms[index]

            ui_drag_float3("Position", &transform.position, 0.05)

            rotation_degrees := math.to_degrees(transform.rotation)
            if ui_drag_float("Y rotation", &rotation_degrees, 1.0, 0.0, 0.0){
                transform.rotation = math.to_radians(rotation_degrees)
            }

            ui_drag_float("Uniform scale", &transform.scale, 0.02, 0.05, 100.0)

            spin_degrees := math.to_degrees(transform.rotation_speed)
            if ui_drag_float("Spin (degrees/s)", &spin_degrees, 1.0, -180.0, 180.0){
                transform.rotation_speed = math.to_radians(spin_degrees)
            }

            debug_ui_text("Set spin to 0 to stop automatic rotation.")

            editor_draw_material_controls(scene, index)
            
            ui_pop_id()
        } else{
            debug_ui_text("Select an object in the Scene panel.")
        }
    }

    ui_end_panel()

}