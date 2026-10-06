package main

import "core:encoding/json"
import "core:mem"
import "core:os"
import alg "core:math/linalg"

SCENE_FILE_PATH :: "scene.json"
SCENE_FILE_VERSION :: 1

ScenePostSettings :: struct{
    exposure: f32,
    bloom_threshold: f32,
    bloom_strength: f32,
}

SceneFile :: struct {
    version: u32,
    scene: Scene,
    post_process: ScenePostSettings,
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

scene_file_validate :: proc(scene: ^Scene) -> string{
    if scene.entity_count < 1 || scene.entity_count > MAX_ENTITIES{
        return "Invalid entity count."
    }

    camera_count, sun_count, point_count: int

    for i in 0..<scene.entity_count{
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
            if scene.transforms[i].scale <= 0{
                return "Mesh scale must be positive."
            }
            if u32(scene.mesh_renderers[i].mesh) >= MESH_COUNT{
                return "Unknown mesh asset."
            }
        }

        if scene.has_material[i]{
            material := scene.materials[i]

            if u32(material.texture) >= TEXTURE_COUNT ||
                u32(material.normal_texture) >= TEXTURE_COUNT ||
                u32(material.roughness_texture) >= TEXTURE_COUNT {
                    return "Unknown texture asset."
            }

            if material.uv_scale <= 0{
                return "UV scale must be positive."
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

    file := SceneFile{
        version = SCENE_FILE_VERSION,
        scene = scene^,
        post_process = {
            exposure = g_renderer.post_exposure,
            bloom_threshold = g_renderer.post_threshold,
            bloom_strength = g_renderer.post_strength,
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
        return false, "Could not decode scene file."
    }

    if file.version != SCENE_FILE_VERSION{
        return false, "Unsupported scene-file version."
    }

    validation := scene_file_validate(&file.scene)
    if len(validation) > 0 {
        return false, validation
    }

    post := file.post_process
    if post.exposure < 0.1 || post.exposure > 5.0 || post.bloom_threshold < 0.1 || post.bloom_threshold > 5.0 ||
        post.bloom_strength < 0.0 || post.bloom_strength > 2.0 {
        return false, "Invalid post-process settings."
    }

    for i in 0..<file.scene.entity_count{
        if file.scene.has_directional_light[i]{
            file.scene.directional_lights[i].direction = alg.normalize(
                file.scene.directional_lights[i].direction,
            )
       }
    }

    // Transfer ownership of the new allocations to the active scene.
    scene_file_destroy()
    g_scene_file_arena = arena
    g_scene_file_arena_active = true
    g_scene = file.scene

    g_renderer.post_exposure = post.exposure
    g_renderer.post_threshold = post.bloom_threshold
    g_renderer.post_strength = post.bloom_strength

    commited = true
    return true, "Scene loaded."
}