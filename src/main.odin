package main

main :: proc(){
    window_create()
    renderer_init()
    renderer_load_assets()
    defer renderer_destroy()

    for g_running{
        window_process_messages()
        renderer_render_frame()
    }
}