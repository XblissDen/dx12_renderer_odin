package main

import alg "core:math/linalg"
import "core:math"

MAX_ENTITIES :: 16
TEXTURE_COUNT :: 4
MESH_COUNT :: 2
MAX_LIGHTS :: 4

Texture_Asset :: enum u32{
    Portrait,
    Checkerboard,
    Stone_Albedo,
    Stone_Normal,
}

Mesh_Asset :: enum u32 {
    Cube, 
    Pyramid,
}

Entity :: distinct int

Transform :: struct{
    position: alg.Vector3f32,
    rotation: f32,
    rotation_speed: f32,
    scale: f32,
}

PointLight :: struct{
    color: [3]f32,
    intensity: f32,
    orbit_radius: f32,
    orbit_angle: f32,
    orbit_speed: f32,
}

DirectionalLight :: struct{
    direction: alg.Vector3f32,
    color: [3]f32,
    intensity: f32,
}

Material :: struct{
    tint: [3]f32,
    texture: Texture_Asset,
    unlit: bool,
    roughness: f32,
    metallic: f32,

    normal_texture: Texture_Asset,
    normal_strength, f32,
    uv_scale: f32,
}

MeshRenderer :: struct {
    mesh: Mesh_Asset,
}

Scene :: struct{
    entity_count: int,

    transforms: [MAX_ENTITIES]Transform,
    has_transform: [MAX_ENTITIES]bool,

    mesh_renderers: [MAX_ENTITIES]MeshRenderer,
    has_mesh_renderer: [MAX_ENTITIES]bool,

    point_lights: [MAX_ENTITIES]PointLight,
    has_point_light: [MAX_ENTITIES]bool,

    cameras: [MAX_ENTITIES]Camera,
    has_camera: [MAX_ENTITIES]bool,

    materials: [MAX_ENTITIES]Material,
    has_material: [MAX_ENTITIES]bool,

    directional_lights: [MAX_ENTITIES]DirectionalLight,
    has_directional_light: [MAX_ENTITIES]bool,
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

scene_add_mesh_renderer :: proc(scene: ^Scene, entity: Entity, mesh_renderer: MeshRenderer) {
    index := int(entity)
    scene.mesh_renderers[index] = mesh_renderer
    scene.has_mesh_renderer[index] = true
}

scene_add_point_light :: proc(scene: ^Scene, entity: Entity, light: PointLight){
    index := int(entity)
    scene.point_lights[index] = light
    scene.has_point_light[index] = true
}

scene_add_directional_light :: proc(
    scene: ^Scene,
    entity: Entity,
    light: DirectionalLight,
) {
    index := int(entity)
    scene.directional_lights[index] = light
    scene.has_directional_light[index] = true
}

scene_add_camera :: proc(scene: ^Scene, entity: Entity, camera: Camera){
    index := int(entity)
    scene.cameras[index] = camera
    scene.has_camera[index] = true
}

scene_add_material :: proc(scene: ^Scene, entity: Entity, material: Material){
    index := int(entity)
    scene.materials[index] = material
    if scene.materials[index].uv_scale == 0{
        scene.materials[index].uv_scale = 1.0
    }
    scene.has_material[index] = true
}

scene_init :: proc(){
    positions := [3]alg.Vector3f32{
        {-2, 0, 0},
        {0, 0, 0},
        {2, 0, 0}
    }

    tints := [3][3]f32{
        {1.0, 1.0, 1.0},
        {1.0, 1.0, 1.0},
        {1.0, 1.0, 1.0},
    }

    textures := [3]Texture_Asset{
        .Portrait,
        .Checkerboard,
        .Portrait,
    }

    meshes := [3]Mesh_Asset{
        .Cube,
        .Pyramid,
        .Cube,
    }

    roughnesses := [3]f32{0.85, 0.28, 0.15}
    metallics   := [3]f32{0.0, 0.75, 0.0}

    for i in 0..<len(positions){
        entity := scene_create_entity(&g_scene)

        scene_add_transform(&g_scene, entity, Transform{position = positions[i], rotation_speed = 0.6, scale = 1.0,})
        scene_add_mesh_renderer(&g_scene, entity, MeshRenderer{
            mesh = meshes[i],
        })
        scene_add_material(&g_scene, entity, Material{
            tint = tints[i],
            texture = textures[i],
            roughness = roughnesses[i],
            metallic = metallics[i],
        })
    }

    ground_entity := scene_create_entity(&g_scene)

    scene_add_transform(&g_scene, ground_entity, Transform{
        position = {0, -4.5, 0},
        scale = 8.0,
    })
    scene_add_mesh_renderer(&g_scene, ground_entity, MeshRenderer{
        mesh = .Cube,
    })
    scene_add_material(&g_scene, ground_entity, Material{
        tint = {1, 1, 1},
        texture = .Stone_Albedo,
        roughness = 0.9,
        metallic = 0.0,

        normal_texture = .Stone_Normal,
        normal_strength = 1.0,
        uv_scale = 4.0
    })

    sun_entity := scene_create_entity(&g_scene)

    scene_add_directional_light(&g_scene, sun_entity, DirectionalLight{
        direction = alg.normalize(alg.Vector3f32{0.6, -0.5, 0.4}),
        color = {1.0, 0.95, 0.85},
        intensity = 0.8,
    })

    light_entity := scene_create_entity(&g_scene)

    scene_add_transform(&g_scene, light_entity, Transform{position = {2, 1.5, 0}, scale = 0.2,})
    scene_add_point_light(&g_scene, light_entity, PointLight{
        color = {0.9, 0.55, 0.4},
        intensity = 3.0,
        orbit_radius = 2.0,
        orbit_speed = 0.6,
    })
    scene_add_mesh_renderer(&g_scene, light_entity, MeshRenderer{
    mesh = .Cube,
    })
    scene_add_material(&g_scene, light_entity, Material{
        tint = g_scene.point_lights[int(light_entity)].color,
        texture = .Checkerboard,
        unlit = true,
    })

    second_light_entity := scene_create_entity(&g_scene)

    scene_add_transform(&g_scene, second_light_entity, Transform{
        position = {-2, 1.5, 0},
        scale = 0.2,
    })

    scene_add_point_light(&g_scene, second_light_entity, PointLight{
        color = {0.3, 0.55, 1.0},
        intensity = 3.0,
        orbit_radius = 2.0,
        orbit_angle = math.PI,
        orbit_speed = 0.6,
    })

    scene_add_mesh_renderer(&g_scene, second_light_entity, MeshRenderer{
    mesh = .Cube,
    })
    scene_add_material(&g_scene, second_light_entity, Material{
        tint = g_scene.point_lights[int(second_light_entity)].color,
        texture = .Checkerboard,
        unlit = true,
    })

    camera_entity := scene_create_entity(&g_scene)

    scene_add_transform(&g_scene, camera_entity, Transform{
        position = {0, 0, -3},
        scale = 1.0,
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