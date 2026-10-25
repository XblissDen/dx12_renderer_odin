package main

import alg "core:math/linalg"
import "core:math"

MAX_ENTITIES :: 1024
MAX_LIGHTS :: 16
// Material slots one entity can use: one per submesh material of its model
// (Sponza needs 25). Slot 0 lives in Scene.materials, the rest in MaterialSlots.
MAX_MODEL_MATERIALS :: 32

MaterialSlots :: struct {
    extra: [MAX_MODEL_MATERIALS - 1]Material,
    // Total slots including slot 0; zero means one.
    count: int,
}

Entity :: distinct int

Transform :: struct{
    position: alg.Vector3f32,
    // Euler angles in radians, applied as roll (Z), then pitch (X), then yaw (Y).
    rotation: alg.Vector3f32,
    // Spin around the Y axis in radians per second.
    rotation_speed: f32,
    scale: alg.Vector3f32,
}

PointLight :: struct{
    color: [3]f32,
    intensity: f32,
    orbit_radius: f32,
    orbit_angle: f32,
    orbit_speed: f32,
    orbit_enabled: bool,
}

DirectionalLight :: struct{
    direction: alg.Vector3f32,
    color: [3]f32,
    intensity: f32,
}

Material :: struct{
    tint: [3]f32,
    texture: TextureHandle,
    unlit: bool,
    roughness: f32,
    metallic: f32,

    normal_texture: TextureHandle,
    normal_strength: f32,
    uv_scale: f32,

    roughness_texture: TextureHandle,
    use_roughness_map: bool,

    metallic_texture: TextureHandle,
    use_metallic_map: bool,

    // Light the surface gives off: color times strength, times the map's
    // (sRGB) color when one is used. Zero strength means none.
    emissive: [3]f32,
    emissive_strength: f32,
    emissive_texture: TextureHandle,
    use_emissive_map: bool,

    // Baked ambient occlusion from the map's red channel, multiplied with
    // SSAO; strength blends from none (0) to the full map (1).
    occlusion_texture: TextureHandle,
    use_occlusion_map: bool,
    occlusion_strength: f32,

    // Cutout: pixels whose albedo alpha is below alpha_cutoff are not drawn.
    alpha_mask: bool,
    alpha_cutoff: f32,
    // Blended (glass, thin cloth): drawn after opaque surfaces, back to front,
    // covering them by albedo alpha times (1 - transparency). Takes precedence
    // over alpha_mask. Stored as transparency so that zero is opaque.
    alpha_blend: bool,
    transparency: f32,
    // Drawn without back-face culling; back faces are lit from their side.
    double_sided: bool,
}

// Ranges of the emission, occlusion, cutout and blending values. NaN fails
// every test.
material_effects_valid :: proc(material: Material) -> bool {
    for channel in material.emissive {
        if !(channel >= 0) do return false
    }
    return material.emissive_strength >= 0 &&
           material.occlusion_strength >= 0 && material.occlusion_strength <= 1 &&
           material.alpha_cutoff >= 0 && material.alpha_cutoff <= 1 &&
           material.transparency >= 0 && material.transparency <= 1
}

MeshRenderer :: struct {
    mesh: MeshHandle,
}

Scene :: struct{
    entity_count: int,
    alive: [MAX_ENTITIES]bool,
    names: [MAX_ENTITIES]string,

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
    material_slots: [MAX_ENTITIES]MaterialSlots,

    directional_lights: [MAX_ENTITIES]DirectionalLight,
    has_directional_light: [MAX_ENTITIES]bool,
}

g_scene: Scene

transform_rotation_matrix :: proc(rotation: alg.Vector3f32) -> alg.Matrix4f32 {
    return alg.matrix4_rotate_f32(rotation.y, {0, 1, 0}) *
           alg.matrix4_rotate_f32(rotation.x, {1, 0, 0}) *
           alg.matrix4_rotate_f32(rotation.z, {0, 0, 1})
}

transform_matrix :: proc(transform: Transform) -> alg.Matrix4f32 {
    return alg.matrix4_translate_f32(transform.position) *
           transform_rotation_matrix(transform.rotation) *
           alg.matrix4_scale_f32(transform.scale)
}

// Positive axes keep triangle winding, culling, and picking consistent.
transform_scale_valid :: proc(scale: alg.Vector3f32) -> bool {
    return scale.x > 0 && scale.y > 0 && scale.z > 0
}

scene_clear_entity_slot :: proc(scene: ^Scene, index: int) {
    scene.names[index] = ""
    scene.alive[index] = false

    scene.transforms[index] = {}
    scene.has_transform[index] = false

    scene.mesh_renderers[index] = {}
    scene.has_mesh_renderer[index] = false

    scene.materials[index] = {}
    scene.has_material[index] = false
    scene.material_slots[index] = {}

    scene.point_lights[index] = {}
    scene.has_point_light[index] = false

    scene.directional_lights[index] = {}
    scene.has_directional_light[index] = false

    scene.cameras[index] = {}
    scene.has_camera[index] = false
}

scene_entity_is_alive :: proc(scene: ^Scene, entity: Entity) -> bool {
    index := int(entity)

    return index >= 0 &&
           index < scene.entity_count &&
           scene.alive[index]
}

scene_create_entity :: proc(scene: ^Scene, name := "") -> Entity {
    assert(scene.entity_count < MAX_ENTITIES)

    entity := Entity(scene.entity_count)

    scene_clear_entity_slot(scene, int(entity))
    scene.names[int(entity)] = name
    scene.alive[int(entity)] = true
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

scene_material_count :: proc(scene: ^Scene, index: int) -> int {
    return max(scene.material_slots[index].count, 1)
}

// Material slot `slot` of an entity. Slots the entity does not have (e.g.
// after switching to a model with more materials) fall back to slot 0.
scene_material :: proc(scene: ^Scene, index, slot: int) -> ^Material {
    if slot <= 0 || slot >= scene_material_count(scene, index) {
        return &scene.materials[index]
    }
    return &scene.material_slots[index].extra[slot - 1]
}

// Slot 0 plus the extra slots, e.g. a model asset's default materials.
scene_set_materials :: proc(scene: ^Scene, entity: Entity, material: Material, slots: MaterialSlots) {
    scene_add_material(scene, entity, material)
    scene.material_slots[int(entity)] = slots
}

scene_add_material :: proc(scene: ^Scene, entity: Entity, material: Material){
    index := int(entity)
    scene.materials[index] = material
    if scene.materials[index].texture == 0 do scene.materials[index].texture = g_assets.white
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

    textures := [3]TextureHandle{
        assets_texture("portrait"),
        assets_texture("checkerboard"),
        assets_texture("portrait"),
    }

    meshes := [3]MeshHandle{
        assets_mesh("cube"),
        assets_mesh("pyramid"),
        assets_mesh("cube"),
    }

    roughnesses := [3]f32{0.85, 0.28, 0.15}
    metallics   := [3]f32{0.0, 0.75, 0.0}

    object_names := [3]string{
        "Cube (left)",
        "Pyramid",
        "Cube (right)",
    }

    for i in 0..<len(positions){
        entity := scene_create_entity(&g_scene, object_names[i])

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

    ground_entity := scene_create_entity(&g_scene, "Ground")

    scene_add_transform(&g_scene, ground_entity, Transform{
        position = {0, -4.5, 0},
        scale = 8.0,
    })
    scene_add_mesh_renderer(&g_scene, ground_entity, MeshRenderer{
        mesh = assets_mesh("cube"),
    })
    scene_add_material(&g_scene, ground_entity, Material{
        tint = {1, 1, 1},
        texture = assets_texture("stone.albedo"),
        roughness = 1.0,
        roughness_texture = assets_texture("stone.roughness"),
        use_roughness_map = true,
        metallic = 0.0,

        normal_texture = assets_texture("stone.normal"),
        normal_strength = 1.0,
        uv_scale = 4.0
    })

    sun_entity := scene_create_entity(&g_scene, "Sun")

    scene_add_directional_light(&g_scene, sun_entity, DirectionalLight{
        direction = alg.normalize(alg.Vector3f32{0.6, -0.5, 0.4}),
        color = {1.0, 0.95, 0.85},
        intensity = 0.8,
    })

    light_entity := scene_create_entity(&g_scene, "Warm point light")

    scene_add_transform(&g_scene, light_entity, Transform{position = {2, 1.5, 0}, scale = 0.2,})
    scene_add_point_light(&g_scene, light_entity, PointLight{
        color = {0.9, 0.55, 0.4},
        intensity = 3.0,
        orbit_radius = 2.0,
        orbit_speed = 0.6,
        orbit_enabled = true,
    })
    scene_add_mesh_renderer(&g_scene, light_entity, MeshRenderer{
    mesh = assets_mesh("cube"),
    })
    scene_add_material(&g_scene, light_entity, Material{
        tint = g_scene.point_lights[int(light_entity)].color,
        texture = assets_texture("checkerboard"),
        unlit = true,
    })

    second_light_entity := scene_create_entity(&g_scene, "Cool point light")

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
        orbit_enabled = true,
    })

    scene_add_mesh_renderer(&g_scene, second_light_entity, MeshRenderer{
    mesh = assets_mesh("cube"),
    })
    scene_add_material(&g_scene, second_light_entity, Material{
        tint = g_scene.point_lights[int(second_light_entity)].color,
        texture = assets_texture("checkerboard"),
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

    if model := assets_mesh("barrel"); model != 0 {
        bounds := g_assets.meshes[model].bounds
        _ = scene_spawn_model(&g_scene, model, {position = {1, -0.5 - bounds.minimum.y * 1.5, 1.5}, scale = 1.5})
    }

    entity := scene_spawn_model(
        &g_scene,
        assets_mesh("barrel"),
        Transform{
            position = {1, 0, 2},
            scale = 1,
        },
    )
}

scene_spawn_model :: proc(scene: ^Scene, mesh: MeshHandle, transform: Transform) -> Entity {
    if !assets_mesh_valid(mesh) || scene.entity_count >= MAX_ENTITIES do return Entity(-1)
    asset := &g_assets.meshes[mesh]
    entity := scene_create_entity(scene, asset.desc.name if asset.desc.name != "" else asset.desc.id)
    scene_add_transform(scene, entity, transform)
    scene_add_mesh_renderer(scene, entity, {mesh = mesh})
    scene_set_materials(scene, entity, asset.material, asset.material_slots)
    return entity
}

scene_update :: proc(scene: ^Scene, dt: f32){
    for i in 0..<scene.entity_count{
        if !scene.alive[i] {
            continue
        }

        if scene.has_transform[i]{
            scene.transforms[i].rotation.y += scene.transforms[i].rotation_speed * dt
        }

        if scene.has_transform[i] && scene.has_point_light[i]{
            light := &scene.point_lights[i]
            if light.orbit_enabled{
                light.orbit_angle += light.orbit_speed * dt

                scene.transforms[i].position.x = math.cos(light.orbit_angle) * light.orbit_radius
                scene.transforms[i].position.z = math.sin(light.orbit_angle) * light.orbit_radius
            }
            
            if scene.has_material[i] {
                scene.materials[i].tint = light.color
            }
        }

        if scene.has_transform[i] && scene.has_camera[i]{
            camera_update(&scene.cameras[i], &scene.transforms[i], dt)
        }
    }
}