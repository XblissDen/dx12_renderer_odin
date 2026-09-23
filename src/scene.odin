package main

import alg "core:math/linalg"

MAX_ENTITIES :: 16

Entity :: distinct int

Transform :: struct{
    position: alg.Vector3f32,
    rotation: f32,
    rotation_speed: f32,
}

Scene :: struct{
    entity_count: int,

    transforms: [MAX_ENTITIES]Transform,
    has_transform: [MAX_ENTITIES]bool,

    has_mesh_renderer: [MAX_ENTITIES]bool,
}

g_scene: Scene

scene_create_entity :: proc(scene: ^Scene) -> Entity{
    assert(scene.entity_count < MAX_ENTITIES)

    entity := Entity(scene.entity_count)
    scene.entity_count += 1
    return entity
}

scene_add_transform :: proc(scene: ^Scene, entity: Entity, transform: Transform){
    index := int(entity)
    scene.transforms[index] = transform
    scene.has_transform[index] = true
}

scene_add_mesh_renderer:: proc(scene: ^Scene, entity: Entity){
    scene.has_mesh_renderer[int(entity)] = true
}

scene_init :: proc(){
    positions := [3]alg.Vector3f32{
        {-2, 0, 0},
        {0, 0, 0},
        {2, 0, 0}
    }

    for position in positions{
        entity := scene_create_entity(&g_scene)

        scene_add_transform(&g_scene, entity, Transform{position = position, rotation_speed = 0.6})
        scene_add_mesh_renderer(&g_scene, entity)
    }
}

scene_update :: proc(scene: ^Scene, dt: f32){
    for i in 0..<scene.entity_count{
        if scene.has_transform[i]{
            scene.transforms[i].rotation += scene.transforms[i]. rotation_speed * dt
        }
    }
}