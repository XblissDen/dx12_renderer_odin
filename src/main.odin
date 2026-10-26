package main

import "core:time"
import win32 "core:sys/windows"

main :: proc(){
    window_create()
    defer window_unlock_cursor()
    window_lock_cursor()
    if error := assets_init("assets.json"); error != "" do panic(error)
    defer assets_destroy()
    
    renderer_init()
    renderer_create_depth_buffer()
    renderer_load_assets()

    scene_init()
    if error := scene_file_validate(&g_scene); error != "" do panic(error)
    defer scene_file_destroy()

    renderer_create_selection_pipeline()
    renderer_load_textures()
    renderer_create_shadow_map()
    renderer_create_hdr_target()
    renderer_create_bloom_targets()
    renderer_create_ssao_targets()
    renderer_create_taa_targets()
    renderer_create_auto_exposure()
    if error := renderer_set_environment(renderer_default_environment_settings()); error != "" do panic(error)

    defer renderer_destroy()
    debug_ui_init()

    last_time := time.now()
    elapsed_for_fps: f32
    frames_for_fps: i32

    for g_running{
        // Temporary allocations live for one frame (window title, wide-string
        // conversions, texture mips during imports); without this they pile up.
        defer free_all(context.temp_allocator)

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
        debug_ui_update()
        renderer_process_environment_change()
        editor_process_asset_import()
        editor_update_picking(&g_scene)
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
