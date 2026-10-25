package main

import "core:fmt"
import "core:math"

editor_find_available_mesh_slot :: proc(scene: ^Scene) -> int {
    for i in 0..<scene.entity_count {
        if scene.alive[i] {
            continue
        }
        if g_editor_selected == Entity(i) {
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

// Live point lights; the renderer takes at most MAX_LIGHTS.
scene_point_light_count :: proc(scene: ^Scene) -> int {
    count := 0
    for i in 0..<scene.entity_count {
        if scene.alive[i] && scene.has_point_light[i] do count += 1
    }
    return count
}

// Whether one more point light fits; if not, says so in the Scene panel.
editor_point_light_fits :: proc(scene: ^Scene) -> bool {
    if scene_point_light_count(scene) < MAX_LIGHTS do return true
    // The status outlives this frame's temporary allocations.
    @(static) message: [64]u8
    g_editor_file_status = fmt.bprintf(message[:], "At most %d point lights are supported.", MAX_LIGHTS)
    return false
}

editor_can_duplicate_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    return editor_find_available_mesh_slot(scene) >= 0 &&
           editor_can_delete_mesh(scene, entity) &&
           (!scene.has_point_light[int(entity)] || scene_point_light_count(scene) < MAX_LIGHTS)
}

editor_mesh_snapshot :: proc(scene: ^Scene, index: int) -> EditorMeshSnapshot {
    snapshot := EditorMeshSnapshot{
        name = scene.names[index],
        transform = scene.transforms[index],
        mesh_renderer = scene.mesh_renderers[index],
        material = scene.materials[index],
        material_slots = scene.material_slots[index],
    }
    if scene.has_point_light[index] do snapshot.point_light = scene.point_lights[index]
    return snapshot
}

// Adds the snapshot's components to an entity slot that is (being made) alive.
editor_add_snapshot_components :: proc(scene: ^Scene, entity: Entity, snapshot: EditorMeshSnapshot) {
    scene_add_transform(scene, entity, snapshot.transform)
    scene_add_mesh_renderer(scene, entity, snapshot.mesh_renderer)
    scene_set_materials(scene, entity, snapshot.material, snapshot.material_slots)
    if light, ok := snapshot.point_light.?; ok do scene_add_point_light(scene, entity, light)
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
    if snapshot.point_light != nil && !editor_point_light_fits(scene) {
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

// Creates an entity from a snapshot as one undoable step and selects it.
editor_create_entity :: proc(scene: ^Scene, snapshot: EditorMeshSnapshot, source: Entity) -> bool {
    slot := editor_find_available_mesh_slot(scene)
    if slot < 0 {
        g_editor_file_status = "No reusable entity slots are available."
        return false
    }
    created := Entity(slot)
    if !editor_restore_created_mesh(scene, created, snapshot) {
        return false
    }
    editor_push_command(EditorCommand{
        kind = .Create_Mesh,
        entity = created,
        mesh_snapshot = snapshot,
        source_entity = source,
    })
    g_editor_selected = created
    return true
}

editor_duplicate_selected :: proc(scene: ^Scene) {
    editor_finish_edit()

    source := g_editor_selected
    if !editor_can_delete_mesh(scene, source) {
        return
    }

    index := int(source)
    source_name := scene.names[index]
    if len(source_name) == 0 {
        source_name = "Mesh"
    }

    formatted_name := fmt.aprintf("%s (copy)", source_name)
    defer delete(formatted_name)

    owned_name, name_ok := scene_store_owned_name(formatted_name)
    if !name_ok {
        g_editor_file_status = "Could not allocate duplicate name."
        return
    }

    snapshot := editor_mesh_snapshot(scene, index)
    snapshot.name = owned_name

    // Make the copy easier to distinguish from its source. An orbiting
    // light's position follows its orbit, so start it further along instead.
    snapshot.transform.position.x += 1.5
    if light, ok := &snapshot.point_light.?; ok && light.orbit_enabled {
        light.orbit_angle += math.PI / 4
    }

    editor_create_entity(scene, snapshot, source)
}

// A white point light with an unlit marker cube, three units in front of the
// camera.
editor_add_point_light :: proc(scene: ^Scene) {
    editor_finish_edit()
    marker := assets_mesh("cube")
    if !assets_mesh_valid(marker) {
        g_editor_file_status = "The light marker needs the \"cube\" model in the catalog."
        return
    }
    if !editor_point_light_fits(scene) do return
    name, name_ok := scene_store_owned_name("Point light")
    if !name_ok {
        g_editor_file_status = "Could not allocate the light's name."
        return
    }

    light := PointLight{color = {1, 1, 1}, intensity = 3, orbit_radius = 2, orbit_speed = 0.6}
    transform := Transform{scale = {0.2, 0.2, 0.2}}
    camera := camera_find_active(scene)
    if camera >= 0 {
        transform.position = scene.transforms[camera].position + camera_forward(&scene.cameras[camera]) * 3
    }
    // The same marker material as the scene's starting lights; scene_update
    // keeps its tint at the light's color.
    marker_material := Material{
        tint = light.color,
        texture = assets_texture("checkerboard"),
        unlit = true,
        uv_scale = 1,
    }
    if !assets_texture_valid(marker_material.texture) do marker_material.texture = g_assets.white

    editor_create_entity(scene, EditorMeshSnapshot{
        name = name,
        transform = transform,
        mesh_renderer = {mesh = marker},
        material = marker_material,
        point_light = light,
    }, g_editor_selected)
}

// Models and point lights. The sun (the renderer needs exactly one) and the
// camera stay.
editor_can_delete_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    if !scene_entity_is_alive(scene, entity) {
        return false
    }

    index := int(entity)

    return scene.has_transform[index] &&
           scene.has_mesh_renderer[index] &&
           scene.has_material[index] &&
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
    if snapshot.point_light != nil && !editor_point_light_fits(scene) {
        return false
    }

    scene_clear_entity_slot(scene, index)
    scene.names[index] = snapshot.name

    editor_add_snapshot_components(scene, entity, snapshot)

    scene.alive[index] = true
    return true
}

editor_delete_selected :: proc(scene: ^Scene) {
    editor_finish_edit()

    entity := g_editor_selected
    if !editor_can_delete_mesh(scene, entity) {
        return
    }

    snapshot := editor_mesh_snapshot(scene, int(entity))

    if !editor_delete_mesh(scene, entity) {
        return
    }

    editor_push_command(EditorCommand{
        kind = .Delete_Mesh,
        entity = entity,
        mesh_snapshot = snapshot,
    })

    g_editor_selected = Entity(-1)
}
