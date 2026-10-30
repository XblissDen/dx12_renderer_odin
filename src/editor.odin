package main

import "core:fmt"
import "core:math"
import "core:slice"
import win32 "core:sys/windows"

// The selection can hold any number of entities. g_editor_selected is the
// primary one, which the Inspector shows and the gizmo sits on; it is always
// selected itself, or -1 when nothing is.
g_editor_selected: Entity = Entity(-1)
g_editor_selection: [MAX_ENTITIES]bool
// Where a Shift+click range in the entity list starts.
g_editor_selection_anchor: Entity = Entity(-1)
// The entity whose material slot g_editor_material_slot refers to.
g_editor_material_entity := -1
g_editor_file_status: string

editor_is_selected :: proc(entity: Entity) -> bool {
    return int(entity) >= 0 && int(entity) < MAX_ENTITIES && g_editor_selection[int(entity)]
}

editor_clear_selection :: proc() {
    g_editor_selection = {}
    g_editor_selected = Entity(-1)
}

// Selects only `entity` (nothing, for -1).
editor_select :: proc(entity: Entity) {
    editor_clear_selection()
    editor_add_to_selection(entity)
}

// Adds `entity` to the selection as the primary.
editor_add_to_selection :: proc(entity: Entity) {
    if int(entity) < 0 || int(entity) >= MAX_ENTITIES do return
    g_editor_selection[int(entity)] = true
    g_editor_selected = entity
    g_editor_selection_anchor = entity
}

// Ctrl+click: adds an entity, or removes one already selected.
editor_toggle_selection :: proc(entity: Entity) {
    if !editor_is_selected(entity) {
        editor_add_to_selection(entity)
        return
    }
    g_editor_selection[int(entity)] = false
    g_editor_selection_anchor = entity
    if g_editor_selected == entity do g_editor_selected = editor_first_selected()
}

editor_first_selected :: proc() -> Entity {
    for selected, i in g_editor_selection do if selected do return Entity(i)
    return Entity(-1)
}

editor_selection_count :: proc() -> int {
    count := 0
    for selected in g_editor_selection do if selected do count += 1
    return count
}

// Drops entities that no longer exist (deleted, or their creation undone),
// moving the primary to another selected entity if it was one of them.
editor_prune_selection :: proc(scene: ^Scene) {
    for i in 0..<MAX_ENTITIES {
        if g_editor_selection[i] && !scene_entity_is_alive(scene, Entity(i)) do g_editor_selection[i] = false
    }
    if !editor_is_selected(g_editor_selected) do g_editor_selected = editor_first_selected()
}

// The entities the Scene panel lists: models and lights (not the camera).
editor_listed :: proc(scene: ^Scene, index: int) -> bool {
    return scene.alive[index] && (scene.has_mesh_renderer[index] || scene.has_directional_light[index] ||
        scene.has_point_light[index] || scene.has_spot_light[index])
}

// Entities whose children the Scene panel hides.
g_editor_collapsed: [MAX_ENTITIES]bool

EditorListRow :: struct {
    index, depth: int,
    has_children: bool,
}

// The Scene panel's rows: each listed entity followed by its children
// (unless collapsed), siblings in index order. A child of an unlisted
// entity is shown as a root.
editor_list_rows :: proc(scene: ^Scene) -> []EditorListRow {
    first_child := make([]int, scene.entity_count, context.temp_allocator)
    next_sibling := make([]int, scene.entity_count, context.temp_allocator)
    is_root := make([]bool, scene.entity_count, context.temp_allocator)
    slice.fill(first_child, -1)
    slice.fill(next_sibling, -1)
    // Backwards, so that pushing onto each list leaves it in index order.
    for i := scene.entity_count - 1; i >= 0; i -= 1 {
        if !editor_listed(scene, i) do continue
        parent, ok := scene_parent(scene, i)
        if ok && editor_listed(scene, parent) {
            next_sibling[i] = first_child[parent]
            first_child[parent] = i
        } else {
            is_root[i] = true
        }
    }

    rows := make([dynamic]EditorListRow, context.temp_allocator)
    add_row :: proc(rows: ^[dynamic]EditorListRow, first_child, next_sibling: []int, index, depth: int) {
        append(rows, EditorListRow{index, depth, first_child[index] >= 0})
        if g_editor_collapsed[index] do return
        for child := first_child[index]; child >= 0; child = next_sibling[child] {
            add_row(rows, first_child, next_sibling, child, depth + 1)
        }
    }
    for root, i in is_root do if root do add_row(&rows, first_child, next_sibling, i, 0)
    return rows[:]
}

// Shift+click in the list: every row from the anchor's to `entity`'s.
editor_select_range :: proc(rows: []EditorListRow, entity: Entity) {
    anchor_row, entity_row := -1, -1
    for row, i in rows {
        if row.index == int(g_editor_selection_anchor) do anchor_row = i
        if row.index == int(entity) do entity_row = i
    }
    // The anchor is gone, or hidden under a collapsed parent.
    if anchor_row < 0 {
        editor_select(entity)
        return
    }
    g_editor_selection = {}
    for row in rows[min(anchor_row, entity_row):max(anchor_row, entity_row) + 1] {
        g_editor_selection[row.index] = true
    }
    g_editor_selected = entity
}

// Dropping an entity on a row (or on the unparent row, -1) makes it that
// row's child. A selected entity takes the rest of the selection along.
editor_drop_on :: proc(scene: ^Scene, dragged, parent: int) {
    dragged_only := []int{dragged}
    entities := editor_selected_tops(scene) if editor_is_selected(Entity(dragged)) else dragged_only
    if editor_set_parents(scene, entities, parent, g_editor_selected) == 0 && parent >= 0 {
        g_editor_file_status = "Can't parent there (a loop, or the sun)."
    }
}

// Ctrl+A: every listed entity, keeping the primary if there is one.
editor_select_all :: proc(scene: ^Scene) {
    editor_finish_edit()
    for i in 0..<scene.entity_count {
        if editor_listed(scene, i) do g_editor_selection[i] = true
    }
    if !editor_is_selected(g_editor_selected) do g_editor_selected = editor_first_selected()
}

// Whether any selected entity passes `test`, for enabling buttons.
editor_any_selected :: proc(scene: ^Scene, test: proc(scene: ^Scene, entity: Entity) -> bool) -> bool {
    for selected, i in g_editor_selection do if selected && test(scene, Entity(i)) do return true
    return false
}

editor_draw_scene :: proc(scene: ^Scene){
    editor_prune_selection(scene)
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
            !editor_any_selected(scene, editor_can_duplicate_mesh),
        )

        if ui_button("Duplicate Selected") {
            editor_duplicate_selected(scene)
        }

        ui_end_disabled()

        if editor_find_available_mesh_slot(scene) < 0 {
            debug_ui_text("No reusable slots (undo history may retain deleted IDs).")
        }

        ui_begin_disabled(
            !editor_any_selected(scene, editor_can_delete_mesh),
        )

        if ui_button("Delete Selected") {
            editor_delete_selected(scene)
        }

        ui_end_disabled()

        ui_separator()

        _, _, can_focus := editor_selection_sphere(scene)
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
                editor_clear_selection()
                renderer_update_post_title()
            }
        }

        debug_ui_text(SCENE_FILE_PATH)

        if len(g_editor_file_status) > 0 {
            debug_ui_text(g_editor_file_status)
        }

        ui_separator()

        debug_ui_text("Ctrl+click toggles, Shift+click a range.")
        debug_ui_text("Drag one onto another to parent it.")
        label_buffer: [128]u8
        dropped: i32

        rows := editor_list_rows(scene)
        for row in rows {
            i := row.index
            name := scene.names[i]
            if len(name) == 0{
                name = "Entity"
            }

            // The hidden suffix makes each selectable entry's ID unique
            label := fmt.bprintf(label_buffer[:127], "%s###entity_%d", name, i,)
            label_buffer[len(label)] = 0

            open := !g_editor_collapsed[i]
            clicked := ui_tree_row(cstring(raw_data(label_buffer[:])), editor_is_selected(Entity(i)), i32(row.depth), row.has_children, &open)
            g_editor_collapsed[i] = !open
            ui_drag_entity(i32(i), fmt.ctprintf("%s", name))
            if ui_drop_entity(&dropped) do editor_drop_on(scene, int(dropped), i)

            if clicked {
                editor_finish_edit()
                if key_down(win32.VK_CONTROL) {
                    editor_toggle_selection(Entity(i))
                } else if key_down(win32.VK_SHIFT) {
                    editor_select_range(rows, Entity(i))
                } else {
                    editor_select(Entity(i))
                }
            }
        }

        // Clicking it does nothing; it is only somewhere to drop.
        ui_selectable("(drop here to unparent)###unparent", false)
        if ui_drop_entity(&dropped) do editor_drop_on(scene, int(dropped), -1)
    }

    ui_end_panel()
}

// Picks the entity's parent from those it can go under; the entity keeps
// its place in the world.
editor_draw_parent_controls :: proc(scene: ^Scene, index: int) {
    if !scene_parentable(scene, index) do return

    parent := int(editor_value(scene, index, .Parent)[0])
    entity_name :: proc(scene: ^Scene, index: int) -> cstring {
        return fmt.ctprintf("%s", scene.names[index] if len(scene.names[index]) > 0 else "Entity")
    }
    if ui_begin_combo("Parent", entity_name(scene, parent) if parent >= 0 else "(none)") {
        if ui_selectable("(none)", parent < 0) {
            editor_set_parents(scene, {index}, -1, Entity(index))
        }
        for candidate in 0..<scene.entity_count {
            if !editor_listed(scene, candidate) || !scene_can_parent(scene, index, candidate) do continue
            ui_push_id(i32(candidate))
            if ui_selectable(entity_name(scene, candidate), candidate == parent) {
                editor_set_parents(scene, {index}, candidate, Entity(index))
            }
            ui_pop_id()
        }
        ui_end_combo()
    }
    if parent >= 0 do debug_ui_text("The transform is relative to the parent.")
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
    editor_checkbox(scene, index, .Point_Cast_Shadows, "Cast shadows")
    if light.cast_shadows {
        editor_shadow_status(index, g_renderer.point_shadow_entities[:], "point lights")
    }
    editor_checkbox(scene, index, .Point_Orbit_Enabled, "Orbit enabled")

    if light.orbit_enabled {
        editor_drag_number(
            scene, index, .Point_Orbit_Radius, "Orbit radius", 0.05, 0.0, 20.0,
        )

        editor_drag_vector(scene, index, .Point_Orbit_Center, "Orbit center", 0.05)

        editor_drag_number(
            scene, index, .Point_Orbit_Speed, "Orbit (degrees/s)",
            1.0, -180.0, 180.0,
            degrees = true,
        )

        debug_ui_text("The orbit sets Position; the move gizmo (W)")
        debug_ui_text("moves the whole orbit (its center).")
    }
}

// Whether a shadow-casting light got one of the shadow slots this frame.
editor_shadow_status :: proc(index: int, slots: []int, kind: string) {
    has_slot := false
    for entity in slots do has_slot ||= entity == index
    text_buffer: [96]u8
    debug_ui_text("Shadow: on" if has_slot else fmt.bprintf(text_buffer[:],
        "Shadow: off (only the %d nearest %s get one)", len(slots), kind))
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
        editor_shadow_status(index, g_renderer.spot_shadow_entities[:], "spot lights")
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
            if count := editor_selection_count(); count > 1 {
                debug_ui_text(fmt.bprintf(text_buffer[:], "%d selected. Fields edit only this one;", count))
                debug_ui_text("the gizmo moves, rotates and scales them all.")
            }
            debug_ui_text("Drag values; Ctrl+click to type.")
            ui_separator()

            ui_push_id(i32(index))

            if scene.has_transform[index] {
                transform := &scene.transforms[index]

                if !scene.has_camera[index] {
                    editor_draw_gizmo_controls()
                    ui_separator()
                }

                editor_draw_parent_controls(scene, index)

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
