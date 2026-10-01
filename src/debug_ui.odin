package main

import "core:fmt"
import win32 "core:sys/windows"

foreign import imgui_lib "../vendor/imgui/lib/dx12_debug_ui.lib"
foreign import imgui_system_libs {
    "dwmapi.lib",
    "imm32.lib",
}

// A small, pinned C interface to ImGui. Panels and engine logic stay in Odin.
@(default_calling_convention="c", link_prefix="dx12_")
foreign imgui_lib {
    ui_init :: proc(hwnd: win32.HWND, device, queue: rawptr, frames_in_flight: i32) -> win32.HRESULT ---
    ui_shutdown :: proc() ---
    ui_handle_message :: proc(hwnd: win32.HWND, message: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) -> bool ---
    ui_wants_keyboard :: proc() -> bool ---
    ui_begin_frame :: proc(cursor_locked: bool) ---
    ui_next_window :: proc(x, y, width, height: f32) ---
    ui_begin_panel :: proc(title: cstring) -> bool ---
    ui_end_panel :: proc() ---
    ui_text :: proc(text: [^]u8, length: uint) ---
    ui_separator :: proc() ---
    ui_slider_float :: proc(label: cstring, value: ^f32, minimum, maximum: f32) -> bool ---
    ui_checkbox :: proc(label: cstring, value: ^bool) -> bool ---
    ui_begin_table :: proc(label: cstring) -> bool ---
    ui_table_column :: proc(label: cstring) ---
    ui_table_headers :: proc() ---
    ui_table_row :: proc() ---
    ui_table_next_column :: proc() ---
    ui_end_table :: proc() ---
    ui_show_demo :: proc(open: ^bool) ---
    ui_render :: proc(command_list: rawptr) ---
}

g_debug_ui_ready: bool
g_debug_ui_visible: bool = true
g_debug_ui_demo: bool

debug_ui_init :: proc() {
    r := &g_renderer
    dx_check(ui_init(g_hwnd, rawptr(r.device), rawptr(r.command_queue), FRAME_COUNT))
    g_debug_ui_ready = true
}

// Call only after the renderer has waited for all submitted GPU work.
debug_ui_destroy :: proc() {
    if g_debug_ui_ready {
        ui_shutdown()
        g_debug_ui_ready = false
    }
}

debug_ui_handle_message :: proc(hwnd: win32.HWND, message: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) -> bool {
    return g_debug_ui_ready && ui_handle_message(hwnd, message, wparam, lparam)
}

debug_ui_wants_keyboard :: proc() -> bool {
    return g_debug_ui_ready && g_debug_ui_visible && !g_cursor_locked && ui_wants_keyboard()
}

debug_ui_text :: proc(text: string) {
    ui_text(raw_data(text), uint(len(text)))
}

debug_ui_update :: proc() {
    if !g_debug_ui_ready {
        return
    }

    ui_begin_frame(g_cursor_locked)
    if !g_debug_ui_visible {
        return
    }

    r := &g_renderer
    changed := false
    text_buffer: [256]u8
    ui_next_window(16, 16, 360, 430)
    if ui_begin_panel("Renderer controls") {
        if g_cursor_locked {
            debug_ui_text("L: release mouse to edit controls")
        } else {
            debug_ui_text("L: capture mouse for camera")
        }
        debug_ui_text("F1: show/hide panel | Esc: quit")
        ui_separator()

        // Do not short-circuit these calls: every widget must run each frame.
        if ui_slider_float("Exposure", &r.post_exposure, 0.1, 5.0) do changed = true
        if ui_slider_float("Bloom threshold", &r.post_threshold, 0.1, 5.0) do changed = true
        if ui_slider_float("Bloom strength", &r.post_strength, 0.0, 2.0) do changed = true

        ui_separator()
        debug_ui_text(fmt.bprintf(text_buffer[:], "FPS: %.0f | Frame: %.2f ms", r.fps, r.frame_ms))

        pass_names := [GPU_PASS_COUNT]string{
            "Shadow", "Scene", "Bloom extract", "Bloom horizontal",
            "Bloom vertical", "Post + UI",
        }
        if ui_begin_table("GPU timings") {
            ui_table_column("GPU pass")
            ui_table_column("Milliseconds")
            ui_table_headers()
            for i in 0..<GPU_PASS_COUNT {
                ui_table_row()
                ui_table_next_column()
                debug_ui_text(pass_names[i])
                ui_table_next_column()
                debug_ui_text(fmt.bprintf(text_buffer[:], "%.3f", r.gpu_pass_ms[i]))
            }
            ui_end_table()
        }
        ui_checkbox("Show ImGui demo", &g_debug_ui_demo)
    }
    ui_end_panel()

    if g_debug_ui_demo {
        ui_show_demo(&g_debug_ui_demo)
    }
    if changed {
        renderer_update_post_title()
    }
}

debug_ui_render :: proc() {
    if g_debug_ui_ready {
        ui_render(rawptr(g_renderer.command_list))
    }
}
