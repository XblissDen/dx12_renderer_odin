package main

import "core:fmt"

editor_can_duplicate_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    return scene.entity_count < MAX_ENTITIES &&
           editor_can_delete_mesh(scene, entity)
}

editor_restore_created_mesh :: proc(
    scene: ^Scene,
    entity: Entity,
    snapshot: EditorMeshSnapshot,
) -> bool {
    // Our current ECS creates entities by appending to its active range.
    if int(entity) != scene.entity_count ||
       scene.entity_count >= MAX_ENTITIES {
        return false
    }

    restored := scene_create_entity(scene, snapshot.name)
    scene_add_transform(scene, restored, snapshot.transform)
    scene_add_mesh_renderer(scene, restored, snapshot.mesh_renderer)
    scene_add_material(scene, restored, snapshot.material)

    return true
}

editor_remove_created_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    index := int(entity)

    if index != scene.entity_count - 1 ||
       !editor_can_delete_mesh(scene, entity) {
        return false
    }

    scene_clear_entity_slot(scene, index)
    scene.entity_count -= 1

    return true
}

editor_duplicate_selected :: proc(scene: ^Scene) {
    editor_finish_edit()

    source := g_editor_selected
    if !editor_can_duplicate_mesh(scene, source) {
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

    snapshot := EditorMeshSnapshot{
        name = owned_name,
        transform = scene.transforms[index],
        mesh_renderer = scene.mesh_renderers[index],
        material = scene.materials[index],
    }

    // Make the copy easier to distinguish from its source.
    snapshot.transform.position.x += 1.5

    created := Entity(scene.entity_count)
    if !editor_restore_created_mesh(scene, created, snapshot) {
        return
    }

    editor_push_command(EditorCommand{
        kind = .Create_Mesh,
        entity = created,
        mesh_snapshot = snapshot,
        source_entity = source,
    })

    g_editor_selected = created
}

editor_can_delete_mesh :: proc(scene: ^Scene, entity: Entity) -> bool {
    if !scene_entity_is_alive(scene, entity) {
        return false
    }

    index := int(entity)

    return scene.has_transform[index] &&
           scene.has_mesh_renderer[index] &&
           scene.has_material[index] &&
           !scene.has_point_light[index] &&
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

    scene_clear_entity_slot(scene, index)
    scene.names[index] = snapshot.name

    scene_add_transform(scene, entity, snapshot.transform)
    scene_add_mesh_renderer(scene, entity, snapshot.mesh_renderer)
    scene_add_material(scene, entity, snapshot.material)

    scene.alive[index] = true
    return true
}

editor_delete_selected :: proc(scene: ^Scene) {
    editor_finish_edit()

    entity := g_editor_selected
    if !editor_can_delete_mesh(scene, entity) {
        return
    }

    index := int(entity)
    snapshot := EditorMeshSnapshot{
        name = scene.names[index],
        transform = scene.transforms[index],
        mesh_renderer = scene.mesh_renderers[index],
        material = scene.materials[index],
    }

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