package main

import "core:time"

main :: proc(){
    window_create()
    window_lock_cursor()
    camera_init()

    renderer_init()
    renderer_create_depth_buffer()
    renderer_load_assets()
    renderer_load_texture()
    defer renderer_destroy()

    last_time := time.now()

    for g_running{
        window_process_messages()

        now := time.now()
        dt := f32(time.duration_seconds(time.diff(last_time, now)))
        last_time = now

        camera_update(&g_camera, dt)
        renderer_render_frame()
    }
}