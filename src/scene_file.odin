package main

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import alg "core:math/linalg"

SCENE_FILE_PATH :: "scene.json"
SCENE_FILE_VERSION :: 8 // 7: extra material slots per entity. 8: emission, occlusion, cutouts.

ScenePostSettings :: struct{
    exposure: f32,
    bloom_threshold: f32,
    bloom_strength: f32,
    // Absent in older files, which decode as Reinhard and keep their look.
    tone_mapper: ToneMapper,
    // Absent in older files, which decode as FXAA.
    anti_aliasing: AntiAliasing,
}

SceneShadowSettings :: struct {
    bias_constant: f32,
    bias_slope: f32,
    // Absent (zero) in files saved before camera-fitted shadows.
    distance: f32,
}

// Version 6+ stores live entities only, each with its optional components.
SceneFileEntity :: struct {
    name: string,
    transform: Maybe(Transform),
    mesh_renderer: Maybe(MeshRenderer),
    material: Maybe(Material),
    // Version 7+: material slots 1 and up of multi-material models.
    extra_materials: []Material,
    point_light: Maybe(PointLight),
    directional_light: Maybe(DirectionalLight),
    camera: Maybe(Camera),
}

SceneFile :: struct {
    version: u32,
    entities: []SceneFileEntity,
    post_process: ScenePostSettings,
    environment: Maybe(EnvironmentSettings),
    shadow: Maybe(SceneShadowSettings),
    // Absent in files saved before SSAO; they load with the defaults.
    ambient_occlusion: Maybe(SceneAmbientOcclusionSettings),
}

SceneAmbientOcclusionSettings :: struct {
    enabled: bool,
    radius: f32,
    intensity: f32,
}

// Versions 1-5 stored the in-memory component arrays directly, with 16 slots,
// a Y-only rotation, and a uniform scale.
LEGACY_SCENE_MAX_ENTITIES :: 16

LegacyTransform :: struct {
    position: alg.Vector3f32,
    rotation: f32,
    rotation_speed: f32,
    scale: f32,
}

LegacySceneFile :: struct {
    scene: struct {
        entity_count: int,
        alive: [LEGACY_SCENE_MAX_ENTITIES]bool,
        names: [LEGACY_SCENE_MAX_ENTITIES]string,
        transforms: [LEGACY_SCENE_MAX_ENTITIES]LegacyTransform,
        has_transform: [LEGACY_SCENE_MAX_ENTITIES]bool,
        mesh_renderers: [LEGACY_SCENE_MAX_ENTITIES]MeshRenderer,
        has_mesh_renderer: [LEGACY_SCENE_MAX_ENTITIES]bool,
        point_lights: [LEGACY_SCENE_MAX_ENTITIES]PointLight,
        has_point_light: [LEGACY_SCENE_MAX_ENTITIES]bool,
        cameras: [LEGACY_SCENE_MAX_ENTITIES]Camera,
        has_camera: [LEGACY_SCENE_MAX_ENTITIES]bool,
        materials: [LEGACY_SCENE_MAX_ENTITIES]Material,
        has_material: [LEGACY_SCENE_MAX_ENTITIES]bool,
        directional_lights: [LEGACY_SCENE_MAX_ENTITIES]DirectionalLight,
        has_directional_light: [LEGACY_SCENE_MAX_ENTITIES]bool,
    },
}

// Loaded names are allocated here and stay alive with the active scene.
g_scene_file_arena: mem.Dynamic_Arena
g_scene_file_arena_active: bool

scene_file_destroy :: proc(){
    if g_scene_file_arena_active{
        mem.dynamic_arena_destroy(&g_scene_file_arena)
        g_scene_file_arena_active = false
    }
}

scene_store_owned_name :: proc(name: string) -> (result: string, ok: bool) {
    if !g_scene_file_arena_active {
        mem.dynamic_arena_init(&g_scene_file_arena)
        g_scene_file_arena_active = true
    }

    copied, error := strings.clone(
        name,
        mem.dynamic_arena_allocator(&g_scene_file_arena),
    )

    return copied, error == nil
}

scene_file_validate_material :: proc(material: Material) -> string {
    if !assets_texture_valid(material.texture) ||
       !assets_optional_texture_valid(material.normal_texture) ||
       !assets_optional_texture_valid(material.roughness_texture) ||
       !assets_optional_texture_valid(material.metallic_texture) ||
       !assets_optional_texture_valid(material.emissive_texture) ||
       !assets_optional_texture_valid(material.occlusion_texture) {
        return "Unknown texture asset."
    }
    if material.use_emissive_map && !texture_asset_is_emissive(material.emissive_texture) {
        return "Invalid emissive map assignment."
    }
    if material.use_occlusion_map && !texture_asset_is_occlusion(material.occlusion_texture) {
        return "Invalid occlusion map assignment."
    }
    if !material_effects_valid(material) {
        return "Invalid emission, occlusion or cutoff value."
    }
    if !texture_asset_is_albedo(material.texture) {
        return "Albedo needs a color texture."
    }
    if !(material.normal_strength >= 0) ||
       (material.normal_strength > 0 && !texture_asset_is_normal(material.normal_texture)) {
        return "Invalid normal map assignment."
    }
    if material.use_roughness_map && !texture_asset_is_roughness(material.roughness_texture) {
        return "Invalid roughness map assignment."
    }
    if material.use_metallic_map && !texture_asset_is_metallic(material.metallic_texture) {
        return "Invalid metallic map assignment."
    }
    if material.uv_scale <= 0 {
        return "UV scale must be positive."
    }
    return ""
}

scene_file_validate :: proc(scene: ^Scene) -> string{
    if scene.entity_count < 1 || scene.entity_count > MAX_ENTITIES{
        return "Invalid entity count."
    }

    camera_count, sun_count, point_count: int

    for i in 0..<scene.entity_count{
        if !scene.alive[i] {
            continue
        }

        if scene.has_camera[i]{
            if !scene.has_transform[i]{
                return "Camera needs a Transform."
            }

            camera_count += 1
        }

        if scene.has_directional_light[i]{
            direction := scene.directional_lights[i].direction
            if alg.dot(direction, direction) <= 0.00000001{
                return "Invalid sun direction."
            }

            sun_count += 1
        }

        if scene.has_point_light[i]{
            if !scene.has_transform[i]{
                return "Point light needs a Transform."
            }

            point_count += 1
        }

        if scene.has_mesh_renderer[i]{
            if !scene.has_transform[i] || !scene.has_material[i]{
                return "Mesh needs Transform and Material."
            }
            if !transform_scale_valid(scene.transforms[i].scale){
                return "Mesh scale must be positive on every axis."
            }
            if !assets_mesh_valid(scene.mesh_renderers[i].mesh) {
                return "Unknown mesh asset."
            }
        }

        if scene.has_material[i]{
            count := scene.material_slots[i].count
            if count < 0 || count > MAX_MODEL_MATERIALS {
                return "Invalid material slot count."
            }
            for slot in 0..<scene_material_count(scene, i) {
                if error := scene_file_validate_material(scene_material(scene, i, slot)^); error != "" {
                    return error
                }
            }
        }
    }

    // These match the current renderer's requirements.
    if camera_count != 1{
        return "Scene needs exactly one camera."
    }
    if sun_count != 1{
        return "Scene needs exactly one sun."
    }
    if point_count > MAX_LIGHTS{
        return "Too many point lights."
    }

    return ""
}

scene_save_to_file :: proc(scene: ^Scene, path: string) -> (ok: bool, message: string)  {
    validation := scene_file_validate(scene)
    if len(validation) > 0{
        return false, validation
    }
    if !renderer_environment_settings_valid(g_renderer.environment_settings) do return false, "Invalid environment settings."

    // Inactive slots are dropped, so entity indices are compacted on reload.
    entities := make([dynamic]SceneFileEntity, 0, scene.entity_count)
    defer delete(entities)

    for i in 0..<scene.entity_count {
        if !scene.alive[i] {
            continue
        }

        entity := SceneFileEntity{name = scene.names[i]}
        if scene.has_transform[i] do entity.transform = scene.transforms[i]
        if scene.has_mesh_renderer[i] do entity.mesh_renderer = scene.mesh_renderers[i]
        if scene.has_material[i] {
            entity.material = scene.materials[i]
            entity.extra_materials = scene.material_slots[i].extra[:scene_material_count(scene, i) - 1]
        }
        if scene.has_point_light[i] do entity.point_light = scene.point_lights[i]
        if scene.has_directional_light[i] do entity.directional_light = scene.directional_lights[i]
        if scene.has_camera[i] do entity.camera = scene.cameras[i]
        append(&entities, entity)
    }

    file := SceneFile{
        version = SCENE_FILE_VERSION,
        entities = entities[:],
        post_process = {
            exposure = g_renderer.post_exposure,
            bloom_threshold = g_renderer.post_threshold,
            bloom_strength = g_renderer.post_strength,
            tone_mapper = g_renderer.post_tone_mapper,
            anti_aliasing = g_renderer.post_anti_aliasing,
        },
        environment = g_renderer.environment_settings,
        shadow = SceneShadowSettings{
            bias_constant = g_renderer.shadow_bias_constant,
            bias_slope = g_renderer.shadow_bias_slope,
            distance = g_renderer.shadow_distance,
        },
        ambient_occlusion = SceneAmbientOcclusionSettings{
            enabled = g_renderer.ao_enabled,
            radius = g_renderer.ao_radius,
            intensity = g_renderer.ao_intensity,
        },
    }

    data, encode_error := json.marshal(file, json.Marshal_Options{
        spec = .JSON,
        pretty = true,
        use_spaces = true,
        spaces = 2,
        use_enum_names = true,
    })
    if encode_error != nil{
        return false, "Could not encode scene."
    }
    defer delete(data)

    write_error := os.write_entire_file(path,data)
    if write_error != nil{
        return false, "Could not write scene file."
    }

    return true, "Scene saved."
}

scene_load_from_file :: proc(path: string) -> (ok: bool, message: string){
    data, read_error := os.read_entire_file(path, context.allocator)
    defer delete(data)

    if read_error != nil{
        return false, "Could not read scene file."
    }
    if !json.is_valid(data, .JSON, true) do return false, "Invalid scene JSON."
    header: struct {version: u32}
    if json.unmarshal(data, &header) != nil || header.version < 1 || header.version > SCENE_FILE_VERSION {
        return false, "Unsupported scene-file version."
    }
    g_asset_read_legacy = header.version <= 2
    defer g_asset_read_legacy = false

    // Decode into separate storage before changing the active scene.
    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena)

    commited := false
    defer if !commited{
        mem.dynamic_arena_destroy(&arena)
    }

    file: SceneFile
    decode_error := json.unmarshal(
        data,
        &file,
        spec = .JSON,
        allocator = mem.dynamic_arena_allocator(&arena),
    )
    if decode_error != nil{
        return false, "Could not decode scene or resolve an asset ID."
    }

    if header.version <= 5 {
        legacy_entities, legacy_ok := scene_file_legacy_entities(
            data, header.version, mem.dynamic_arena_allocator(&arena),
        )
        if !legacy_ok {
            return false, "Could not decode scene or resolve an asset ID."
        }
        file.entities = legacy_entities
    }

    if len(file.entities) < 1 || len(file.entities) > MAX_ENTITIES {
        return false, "Invalid entity count."
    }

    // The scene is too large for the stack; stage it on the heap.
    staged := new(Scene)
    defer free(staged)

    for source in file.entities {
        entity := scene_create_entity(staged, source.name)
        index := int(entity)

        if transform, ok := source.transform.?; ok do scene_add_transform(staged, entity, transform)
        if mesh_renderer, ok := source.mesh_renderer.?; ok do scene_add_mesh_renderer(staged, entity, mesh_renderer)
        if point_light, ok := source.point_light.?; ok do scene_add_point_light(staged, entity, point_light)
        if directional_light, ok := source.directional_light.?; ok do scene_add_directional_light(staged, entity, directional_light)
        if camera, ok := source.camera.?; ok do scene_add_camera(staged, entity, camera)

        // Stored as-is, without scene_add_material's defaults, so validation
        // still rejects missing textures and invalid UV scales.
        if material, ok := source.material.?; ok {
            staged.materials[index] = material
            staged.has_material[index] = true
            if len(source.extra_materials) > MAX_MODEL_MATERIALS - 1 {
                return false, "An entity has too many material slots."
            }
            copy(staged.material_slots[index].extra[:], source.extra_materials)
            staged.material_slots[index].count = 1 + len(source.extra_materials)
        }
    }

    validation := scene_file_validate(staged)
    if len(validation) > 0 {
        return false, validation
    }

    post := file.post_process
    if post.exposure < 0.1 || post.exposure > 5.0 || post.bloom_threshold < 0.1 || post.bloom_threshold > 5.0 ||
        post.bloom_strength < 0.0 || post.bloom_strength > 2.0 ||
        post.tone_mapper > max(ToneMapper) || post.anti_aliasing > max(AntiAliasing) {
        return false, "Invalid post-process settings."
    }
    shadow := file.shadow.? or_else SceneShadowSettings{
        bias_constant = DEFAULT_SHADOW_BIAS_CONSTANT,
        bias_slope = DEFAULT_SHADOW_BIAS_SLOPE,
    }
    if shadow.distance == 0 do shadow.distance = DEFAULT_SHADOW_DISTANCE
    if !(shadow.bias_constant >= 0 && shadow.bias_constant <= MAX_SHADOW_BIAS) ||
       !(shadow.bias_slope >= 0 && shadow.bias_slope <= MAX_SHADOW_BIAS) ||
       !(shadow.distance >= MIN_SHADOW_DISTANCE && shadow.distance <= MAX_SHADOW_DISTANCE) {
        return false, "Invalid shadow settings."
    }
    ambient_occlusion := file.ambient_occlusion.? or_else SceneAmbientOcclusionSettings{
        enabled = true,
        radius = DEFAULT_AO_RADIUS,
        intensity = DEFAULT_AO_INTENSITY,
    }
    if !(ambient_occlusion.radius >= MIN_AO_RADIUS && ambient_occlusion.radius <= MAX_AO_RADIUS) ||
       !(ambient_occlusion.intensity >= 0 && ambient_occlusion.intensity <= MAX_AO_INTENSITY) {
        return false, "Invalid ambient occlusion settings."
    }
    environment, has_environment := file.environment.(EnvironmentSettings)
    defaults := renderer_default_environment_settings()
    if !has_environment {
        environment = defaults
    } else if header.version <= 4 {
        // Older environment settings always used HDRI lighting/backgrounds.
        // Seed the inactive color controls so switching modes is useful too.
        environment.ambient_mode = .HDRI
        environment.background_mode = .HDRI
        environment.ambient_color = defaults.ambient_color
        environment.ambient_intensity = defaults.ambient_intensity
        environment.background_color = defaults.background_color
    }
    if !renderer_environment_settings_valid(environment) do return false, "Invalid environment settings."

    for i in 0..<staged.entity_count{
        if staged.has_directional_light[i]{
            staged.directional_lights[i].direction = alg.normalize(
                staged.directional_lights[i].direction,
            )
       }
    }

    // Transfer ownership of the new allocations to the active scene.
    if error := renderer_set_environment(environment); error != "" do return false, error
    g_renderer.environment_pending = nil
    g_renderer.environment_status = ""
    scene_file_destroy()
    g_scene_file_arena = arena
    g_scene_file_arena_active = true
    g_scene = staged^

    g_renderer.post_exposure = post.exposure
    g_renderer.post_threshold = post.bloom_threshold
    g_renderer.post_strength = post.bloom_strength
    g_renderer.post_tone_mapper = post.tone_mapper
    g_renderer.post_anti_aliasing = post.anti_aliasing
    g_renderer.shadow_bias_constant = shadow.bias_constant
    g_renderer.shadow_bias_slope = shadow.bias_slope
    g_renderer.shadow_distance = shadow.distance
    g_renderer.ao_enabled = ambient_occlusion.enabled
    g_renderer.ao_radius = ambient_occlusion.radius
    g_renderer.ao_intensity = ambient_occlusion.intensity

    commited = true
    return true, "Scene loaded."
}

// Converts the version 1-5 component arrays into version 6 entity records.
scene_file_legacy_entities :: proc(
    data: []byte,
    version: u32,
    allocator: mem.Allocator,
) -> (entities: []SceneFileEntity, ok: bool) {
    legacy: LegacySceneFile
    if json.unmarshal(data, &legacy, spec = .JSON, allocator = allocator) != nil {
        return nil, false
    }

    scene := &legacy.scene
    if scene.entity_count < 1 || scene.entity_count > LEGACY_SCENE_MAX_ENTITIES {
        return nil, false
    }

    result := make([dynamic]SceneFileEntity, 0, scene.entity_count, allocator)
    for i in 0..<scene.entity_count {
        // Version 1 had no inactive slots.
        if version > 1 && !scene.alive[i] {
            continue
        }

        entity := SceneFileEntity{name = scene.names[i]}
        if scene.has_transform[i] {
            old := scene.transforms[i]
            entity.transform = Transform{
                position = old.position,
                rotation = {0, old.rotation, 0},
                rotation_speed = old.rotation_speed,
                scale = {old.scale, old.scale, old.scale},
            }
        }
        if scene.has_mesh_renderer[i] do entity.mesh_renderer = scene.mesh_renderers[i]
        if scene.has_material[i] do entity.material = scene.materials[i]
        if scene.has_point_light[i] do entity.point_light = scene.point_lights[i]
        if scene.has_directional_light[i] do entity.directional_light = scene.directional_lights[i]
        if scene.has_camera[i] do entity.camera = scene.cameras[i]
        append(&result, entity)
    }

    return result[:], true
}
