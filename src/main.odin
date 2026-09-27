package main

import "core:time"
import win32 "core:sys/windows"

main :: proc(){
    window_create()
    window_lock_cursor()
    scene_init()

    renderer_init()
    renderer_create_depth_buffer()
    renderer_load_assets()
    renderer_load_textures()
    renderer_create_shadow_map()
    renderer_create_hdr_target()
    renderer_create_bloom_targets()
    defer renderer_destroy()

    last_time := time.now()
    elapsed_for_fps: f32
    frames_for_fps: i32

    for g_running{
        window_process_messages()
        if !g_running{
            break
        }

        renderer_apply_post_steps(
            g_exposure_steps,
            g_threshold_steps,
            g_bloom_steps,
        )
        g_exposure_steps = 0
        g_threshold_steps = 0
        g_bloom_steps = 0

        now := time.now()
        dt := f32(time.duration_seconds(time.diff(last_time, now)))
        last_time = now

        if g_client_width == 0 || g_client_height == 0{
            win32.Sleep(16)
            continue
        }

        renderer_resize(g_client_width, g_client_height)
        scene_update(&g_scene, dt)
        renderer_render_frame(&g_scene)

        elapsed_for_fps += dt
        frames_for_fps += 1

        if elapsed_for_fps >= 1.0 {
            g_renderer.fps = f32(frames_for_fps) / elapsed_for_fps
            g_renderer.frame_ms = elapsed_for_fps * 1000.0 / f32(frames_for_fps)

            renderer_update_post_title()

            elapsed_for_fps = 0
            frames_for_fps = 0
        }
    }
}