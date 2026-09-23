package main

import "core:time"
import win32 "core:sys/windows"

main :: proc(){
    window_create()
    window_lock_cursor()
    camera_init()
    scene_init()

    renderer_init()
    renderer_create_depth_buffer()
    renderer_load_assets()
    renderer_load_texture()
    defer renderer_destroy()

    last_time := time.now()

    for g_running{
        window_process_messages()
        if !g_running{
            break
        }

        now := time.now()
        dt := f32(time.duration_seconds(time.diff(last_time, now)))
        last_time = now

        if g_client_width == 0 || g_client_height == 0{
            win32.Sleep(16)
            continue
        }

        renderer_resize(g_client_width, g_client_height)
        camera_update(&g_camera, dt)
        scene_update(&g_scene, dt)
        renderer_render_frame(&g_scene, dt)
    }
}