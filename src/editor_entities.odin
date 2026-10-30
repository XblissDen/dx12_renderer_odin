package main

import "core:fmt"
import "core:math"
import alg "core:math/linalg"
import "core:slice"

editor_find_available_mesh_slot :: proc(scene: ^Scene) -> int {
    for i in 0..<scene.entity_count {
        if scene.alive[i] {
            continue
        }
        if editor_is_selected(Entity(i)) {
            continue
        }
        if editor_slot_referenced_by_history(i) {
            continue
        }

        return i
    }

    if scene.entity_count < MAX_ENTITIES {
        return scene.entity_count
    }

    return -1
}

// Whether one more point or spot light fits (they share MAX_LIGHTS); if not,
// says so in the Scene panel.
editor_light_fits :: proc(scene: ^Scene) -> bool {
    if scene_local_light_count(scene) < MAX_LIGHTS do return true
    // The status outlives this frame's temporary allocations.
    @(static) message: [64]u8
    g_editor_file_status = fmt.bprintf(message[:], "At most %d point and spot lights are supported.", MAX_LIGHTS)
    return false
}

editor_can_duplicate_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    index := int(entity)
    is_light := index >= 0 && (scene.has_point_light[index] || scene.has_spot_light[index])
    return editor_find_available_mesh_slot(scene) >= 0 &&
           editor_can_delete_mesh(scene, entity) &&
           (!is_light || scene_local_light_count(scene) < MAX_LIGHTS)
}

editor_mesh_snapshot :: proc(scene: ^Scene, index: int) -> EditorMeshSnapshot {
    snapshot := EditorMeshSnapshot{
        name = scene.names[index],
        transform = scene.transforms[index],
        material = scene.materials[index],
        material_slots = scene.material_slots[index],
    }
    if scene.has_mesh_renderer[index] do snapshot.mesh_renderer = scene.mesh_renderers[index]
    if scene.has_point_light[index] do snapshot.point_light = scene.point_lights[index]
    if scene.has_spot_light[index] do snapshot.spot_light = scene.spot_lights[index]
    // The link itself, even to a parent deleted a moment ago in the same step.
    if scene.has_parent[index] do snapshot.parent = scene.parents[index]
    return snapshot
}

// Adds the snapshot's components to an entity slot that is (being made) alive.
editor_add_snapshot_components :: proc(scene: ^Scene, entity: Entity, snapshot: EditorMeshSnapshot) {
    scene_add_transform(scene, entity, snapshot.transform)
    if mesh_renderer, ok := snapshot.mesh_renderer.?; ok {
        scene_add_mesh_renderer(scene, entity, mesh_renderer)
        scene_set_materials(scene, entity, snapshot.material, snapshot.material_slots)
    }
    if light, ok := snapshot.point_light.?; ok do scene_add_point_light(scene, entity, light)
    if light, ok := snapshot.spot_light.?; ok do scene_add_spot_light(scene, entity, light)
    if parent, ok := snapshot.parent.?; ok do scene_set_parent(scene, int(entity), int(parent))
}

editor_restore_created_mesh :: proc(
    scene: ^Scene,
    entity: Entity,
    snapshot: EditorMeshSnapshot,
) -> bool {
    index := int(entity)

    if index < 0 || index >= MAX_ENTITIES {
        return false
    }
    if (snapshot.point_light != nil || snapshot.spot_light != nil) && !editor_light_fits(scene) {
        return false
    }

    if index == scene.entity_count {
        // The snapshot is being restored to a new high-water slot.
        _ = scene_create_entity(scene, snapshot.name)
    } else if index < scene.entity_count && !scene.alive[index] {
        // Redo or duplication into a reusable hole.
        scene_clear_entity_slot(scene, index)
        scene.names[index] = snapshot.name
        scene.alive[index] = true
    } else {
        return false
    }

    editor_add_snapshot_components(scene, entity, snapshot)
    return true
}

editor_remove_created_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    if !editor_can_delete_mesh(scene, entity) {
        return false
    }

    // Keep entity_count as the high-water mark. The hole may be reused
    // after the creation command leaves undo/redo history.
    scene_clear_entity_slot(scene, int(entity))
    return true
}

// Creates an entity from a snapshot; the caller pushes the returned command.
editor_create_entity_command :: proc(scene: ^Scene, snapshot: EditorMeshSnapshot, source: Entity) -> (EditorCommand, bool) {
    slot := editor_find_available_mesh_slot(scene)
    if slot < 0 {
        g_editor_file_status = "No reusable entity slots are available."
        return {}, false
    }
    created := Entity(slot)
    if !editor_restore_created_mesh(scene, created, snapshot) {
        return {}, false
    }
    return EditorCommand{
        kind = .Create_Mesh,
        entity = created,
        mesh_snapshot = snapshot,
        source_entity = source,
    }, true
}

// Creates an entity from a snapshot as one undoable step and selects it.
editor_create_entity :: proc(scene: ^Scene, snapshot: EditorMeshSnapshot, source: Entity) -> bool {
    command := editor_create_entity_command(scene, snapshot, source) or_return
    editor_push_command(command)
    editor_select(command.entity)
    return true
}

// The selected entities and all their descendants, parents before children.
editor_selected_subtrees :: proc(scene: ^Scene) -> []int {
    Item :: struct {index, depth: int}
    items := make([dynamic]Item, context.temp_allocator)
    for i in 0..<scene.entity_count {
        if !scene.alive[i] do continue
        in_subtree := editor_is_selected(Entity(i))
        depth := 0
        current := i
        for _ in 0..<MAX_ENTITIES {
            parent := scene_parent(scene, current) or_break
            in_subtree ||= editor_is_selected(Entity(parent))
            depth += 1
            current = parent
        }
        if in_subtree do append(&items, Item{i, depth})
    }
    slice.stable_sort_by(items[:], proc(a, b: Item) -> bool {return a.depth < b.depth})
    order := make([]int, len(items), context.temp_allocator)
    for item, i in items do order[i] = item.index
    return order
}

// Copies every selected model and light (not the sun or camera) with its
// descendants as one undoable step, and selects the copies. Each copy sits
// beside its source, under the same parent; copied children go under the
// copied parent.
editor_duplicate_selected :: proc(scene: ^Scene) {
    editor_finish_edit()

    commands := make([dynamic]EditorCommand, context.temp_allocator)
    copies := make(map[int]Entity, context.temp_allocator)
    tops := make([dynamic]Entity, context.temp_allocator)
    subtrees := editor_selected_subtrees(scene)
    in_subtrees := make(map[int]bool, context.temp_allocator)
    for index in subtrees do in_subtrees[index] = true
    primary := Entity(-1)
    for index in subtrees {
        source := Entity(index)
        if !editor_can_delete_mesh(scene, source) {
            continue
        }
        parent, has_parent := scene_parent(scene, index)
        top := !has_parent || !in_subtrees[parent]
        parent_copy, parent_copied := copies[parent]
        // Under a parent that could not be copied: left out with it.
        if !top && !parent_copied do continue

        source_name := scene.names[index]
        if len(source_name) == 0 {
            source_name = "Mesh"
        }

        formatted_name := fmt.aprintf("%s (copy)", source_name)
        defer delete(formatted_name)

        owned_name, name_ok := scene_store_owned_name(formatted_name)
        if !name_ok {
            g_editor_file_status = "Could not allocate duplicate name."
            break
        }

        snapshot := editor_mesh_snapshot(scene, index)
        snapshot.name = owned_name

        if top {
            // Make the copy easier to distinguish from its source: 1.5 world
            // units along X. An orbiting light's position follows its orbit,
            // so start it further along instead.
            offset := alg.mul(alg.matrix4_inverse_f32(scene_parent_matrix(scene, index)), alg.Vector4f32{1.5, 0, 0, 0})
            snapshot.transform.position += offset.xyz
            if light, ok := &snapshot.point_light.?; ok && light.orbit_enabled {
                light.orbit_angle += math.PI / 4
            }
        } else {
            snapshot.parent = parent_copy
        }

        // Stops at the entity or light limit; the copies made so far stay.
        // Undoing selects the sources of the top copies only.
        command := editor_create_entity_command(scene, snapshot, source if top else Entity(-1)) or_break
        append(&commands, command)
        copies[index] = command.entity
        if top {
            append(&tops, command.entity)
            if source == g_editor_selected || primary < 0 do primary = command.entity
        }
    }

    editor_push_commands(commands[:], primary)
    if len(commands) == 0 do return
    editor_clear_selection()
    for entity in tops do editor_add_to_selection(entity)
    g_editor_selected = primary
}

// Gives each entity a new parent (-1: none) as one undoable step, keeping it
// where it is in the world. Entities that cannot take that parent (it is
// themselves or one of their descendants) are left alone. Returns how many
// changed.
editor_set_parents :: proc(scene: ^Scene, entities: []int, parent: int, primary: Entity) -> int {
    editor_finish_edit()

    edits := make([dynamic]EditorFieldEdit, context.temp_allocator)
    changed := 0
    for index in entities {
        before_parent := editor_value(scene, index, .Parent)
        if int(before_parent[0]) == parent || !scene_can_parent(scene, index, parent) do continue

        world := scene_world_matrix(scene, index)
        old_space := scene_parent_matrix(scene, index)
        position_field := editor_position_field(scene, index)
        fields := [4]EditorField{.Parent, position_field, .Rotation, .Scale}
        before: [4][3]f32
        for field, i in fields do before[i] = editor_value(scene, index, field)

        scene_set_parent(scene, index, parent)
        to_new_space := alg.matrix4_inverse_f32(scene_parent_matrix(scene, index))
        local := transform_from_matrix(to_new_space * world)
        if position_field == .Point_Orbit_Center {
            // The orbit's center moves into the new space; the light follows.
            center := scene.point_lights[index].orbit_center
            moved := alg.mul(to_new_space * old_space, alg.Vector4f32{center.x, center.y, center.z, 1})
            editor_apply_value(scene, Entity(index), .Point_Orbit_Center, moved.xyz)
        } else {
            editor_apply_value(scene, Entity(index), .Position, local.position)
        }
        editor_apply_value(scene, Entity(index), .Rotation, local.rotation)
        editor_apply_value(scene, Entity(index), .Scale, local.scale)

        for field, i in fields {
            append(&edits, EditorFieldEdit{Entity(index), field, before[i], editor_value(scene, index, field)})
        }
        changed += 1
    }
    editor_push_field_edits(edits[:], primary)
    return changed
}

// The selected entities with no selected ancestor: reparenting those keeps
// the rest of the selection under them.
editor_selected_tops :: proc(scene: ^Scene) -> []int {
    tops := make([dynamic]int, context.temp_allocator)
    outer: for selected, index in g_editor_selection {
        if !selected do continue
        current := index
        for _ in 0..<MAX_ENTITIES {
            parent := scene_parent(scene, current) or_break
            if editor_is_selected(Entity(parent)) do continue outer
            current = parent
        }
        append(&tops, index)
    }
    return tops[:]
}

// A white point light (marker: a small cube) three units in front of the
// camera.
editor_add_point_light :: proc(scene: ^Scene) {
    intensity: f32 = 3
    editor_add_light(scene, "cube", "Point light", PointLight{
        color = {1, 1, 1},
        intensity = intensity,
        range = light_default_range(intensity),
        cast_shadows = true,
        orbit_radius = 2,
        orbit_speed = 0.6,
    }, nil)
}

// A white spot light (marker: a small pyramid, base along the beam) three
// units in front of the camera, shining straight down.
editor_add_spot_light :: proc(scene: ^Scene) {
    editor_add_light(scene, "pyramid", "Spot light", nil, SpotLight{
        color = {1, 1, 1},
        intensity = 10,
        range = 15,
        inner_angle = math.to_radians(f32(20)),
        outer_angle = math.to_radians(f32(30)),
        cast_shadows = true,
    })
}

// Creates a light entity, with an unlit marker in the light's color, as one
// undoable step.
editor_add_light :: proc(scene: ^Scene, marker_id, name: string, point: Maybe(PointLight), spot: Maybe(SpotLight)) {
    editor_finish_edit()
    marker := assets_mesh(marker_id)
    if !assets_mesh_valid(marker) {
        @(static) message: [96]u8
        g_editor_file_status = fmt.bprintf(message[:], "The light marker needs the \"%s\" model in the catalog.", marker_id)
        return
    }
    if !editor_light_fits(scene) do return
    owned_name, name_ok := scene_store_owned_name(name)
    if !name_ok {
        g_editor_file_status = "Could not allocate the light's name."
        return
    }

    transform := Transform{scale = {0.2, 0.2, 0.2}}
    camera := camera_find_active(scene)
    if camera >= 0 {
        transform.position = scene.transforms[camera].position + camera_forward(&scene.cameras[camera]) * 3
    }
    // The same marker material as the scene's starting lights; scene_update
    // keeps its tint at the light's color.
    marker_material := Material{
        tint = {1, 1, 1},
        texture = assets_texture("checkerboard"),
        unlit = true,
        uv_scale = 1,
    }
    if !assets_texture_valid(marker_material.texture) do marker_material.texture = g_assets.white

    editor_create_entity(scene, EditorMeshSnapshot{
        name = owned_name,
        transform = transform,
        mesh_renderer = MeshRenderer{mesh = marker},
        material = marker_material,
        point_light = point,
        spot_light = spot,
    }, g_editor_selected)
}

// Models, point and spot lights, and empty entities. The sun (the renderer
// needs exactly one) and the camera stay.
editor_can_delete_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    if !scene_entity_is_alive(scene, entity) {
        return false
    }

    index := int(entity)

    return scene.has_transform[index] &&
           scene.has_mesh_renderer[index] == scene.has_material[index] &&
           !scene.has_directional_light[index] &&
           !scene.has_camera[index]
}

editor_delete_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    if !editor_can_delete_mesh(scene, entity) {
        return false
    }

    scene.alive[int(entity)] = false
    return true
}

editor_restore_deleted_mesh :: proc(
    scene: ^Scene,
    entity: Entity,
    snapshot: EditorMeshSnapshot,
) -> bool {
    index := int(entity)

    if index < 0 || index >= scene.entity_count ||
       scene.alive[index] {
        return false
    }
    if (snapshot.point_light != nil || snapshot.spot_light != nil) && !editor_light_fits(scene) {
        return false
    }

    scene_clear_entity_slot(scene, index)
    scene.names[index] = snapshot.name

    editor_add_snapshot_components(scene, entity, snapshot)

    scene.alive[index] = true
    return true
}

// Deletes every selected model and light, with its descendants, as one
// undoable step. The sun and camera cannot be deleted and stay selected.
editor_delete_selected :: proc(scene: ^Scene) {
    editor_finish_edit()

    primary := g_editor_selected
    commands := make([dynamic]EditorCommand, context.temp_allocator)
    // Parents first: undoing restores in reverse, children before parents,
    // and their links come back with them.
    for index in editor_selected_subtrees(scene) {
        entity := Entity(index)
        if !editor_can_delete_mesh(scene, entity) {
            continue
        }

        snapshot := editor_mesh_snapshot(scene, index)
        if !editor_delete_mesh(scene, entity) {
            continue
        }

        append(&commands, EditorCommand{
            kind = .Delete_Mesh,
            entity = entity,
            mesh_snapshot = snapshot,
        })
        g_editor_selection[index] = false
    }

    editor_push_commands(commands[:], primary)
    editor_prune_selection(scene)
}
