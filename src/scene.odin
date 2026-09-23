package main

import alg "core:math/linalg"
import "core:math"

MAX_ENTITIES :: 16

Entity :: distinct int

Transform :: struct{
    position: alg.Vector3f32,
    rotation: f32,
    rotation_speed: f32,
}

PointLight :: struct{
    color: [3]f32,
    orbit_radius: f32,
    orbit_angle: f32,
    orbit_speed: f32,
}

Material :: struct{
    tint: [3]f32,
}

Scene :: struct{
    entity_count: int,

    transforms: [MAX_ENTITIES]Transform,
    has_transform: [MAX_ENTITIES]bool,

    has_mesh_renderer: [MAX_ENTITIES]bool,

    point_lights: [MAX_ENTITIES]PointLight,
    has_point_light: [MAX_ENTITIES]bool,

    cameras: [MAX_ENTITIES]Camera,
    has_camera: [MAX_ENTITIES]bool,

    materials: [MAX_ENTITIES]Material,
    has_material: [MAX_ENTITIES]bool,
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

scene_add_point_light :: proc(scene: ^Scene, entity: Entity, light: PointLight){
    index := int(entity)
    scene.point_lights[index] = light
    scene.has_point_light[index] = true
}

scene_add_camera :: proc(scene: ^Scene, entity: Entity, camera: Camera){
    index := int(entity)
    scene.cameras[index] = camera
    scene.has_camera[index] = true
}

scene_add_material :: proc(scene: ^Scene, entity: Entity, material: Material){
    index := int(entity)
    scene.materials[index] = material
    scene.has_material[index] = true
}

scene_init :: proc(){
    positions := [3]alg.Vector3f32{
        {-2, 0, 0},
        {0, 0, 0},
        {2, 0, 0}
    }

    tints := [3][3]f32{
        {1.0, 0.35, 0.35},
        {0.35, 1.0, 0.35},
        {0.35, 0.55, 1.0},
    }

    for i in 0..<len(positions){
        entity := scene_create_entity(&g_scene)

        scene_add_transform(&g_scene, entity, Transform{position = positions[i], rotation_speed = 0.6})
        scene_add_mesh_renderer(&g_scene, entity)
        scene_add_material(&g_scene, entity, Material{
            tint = tints[i],
        })
    }

    light_entity := scene_create_entity(&g_scene)

    scene_add_transform(&g_scene, light_entity, Transform{position = {2, 1.5, 0},})
    scene_add_point_light(&g_scene, light_entity, PointLight{
        color = {1, 1, 1},
        orbit_radius = 2.0,
        orbit_speed = 0.6,
    })

    camera_entity := scene_create_entity(&g_scene)

    scene_add_transform(&g_scene, camera_entity, Transform{
        position = {0, 0, -3},
    })

    scene_add_camera(&g_scene, camera_entity, Camera{
        yaw = math.PI * 0.5,
        pitch = 0,
        speed = 3.0,
        sensitivity = 0.003,
    })
}

scene_update :: proc(scene: ^Scene, dt: f32){
    for i in 0..<scene.entity_count{
        if scene.has_transform[i]{
            scene.transforms[i].rotation += scene.transforms[i]. rotation_speed * dt
        }

        if scene.has_transform[i] && scene.has_point_light[i]{
            light := &scene.point_lights[i]
            light.orbit_angle += light.orbit_speed * dt

            scene.transforms[i].position.x = math.cos(light.orbit_angle) * light.orbit_radius
            scene.transforms[i].position.z = math.sin(light.orbit_angle) * light.orbit_radius
        }

        if scene.has_transform[i] && scene.has_camera[i]{
            camera_update(&scene.cameras[i], &scene.transforms[i], dt)
        }
    }
}