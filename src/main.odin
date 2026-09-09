package main

main :: proc(){
    window_create()
    renderer_init()
    renderer_create_depth_buffer()
    renderer_load_assets()
    renderer_load_texture()
    defer renderer_destroy()

    for g_running{
        window_process_messages()
        renderer_render_frame()
    }
}