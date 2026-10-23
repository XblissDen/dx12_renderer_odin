package main

import "core:fmt"
import "core:math"
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
    ui_scene_left_click :: proc(x, y: ^f32) -> bool ---
    ui_scene_mouse :: proc(mouse: ^SceneMouse) ---
    ui_draw_line :: proc(x0, y0, x1, y1: f32, color: u32, thickness: f32) ---
    ui_draw_triangle :: proc(x0, y0, x1, y1, x2, y2: f32, color: u32) ---
    ui_draw_rect :: proc(x0, y0, x1, y1: f32, color: u32) ---
    ui_radio_button :: proc(label: cstring, active: bool) -> bool ---
    ui_same_line :: proc() ---
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
    ui_selectable :: proc(label: cstring, selected: bool) -> bool ---

    ui_drag_float3 :: proc(
        label: cstring,
        values: ^[3]f32,
        speed: f32,
    ) -> bool ---

    ui_drag_float :: proc(
        label: cstring,
        value: ^f32,
        speed, minimum, maximum: f32,
    ) -> bool ---

    ui_push_id :: proc(id: i32) ---
    ui_pop_id :: proc() ---
    ui_color_edit3 :: proc(label: cstring, values: ^[3]f32) -> bool ---

    ui_begin_disabled :: proc(disabled: bool) ---
    ui_end_disabled :: proc() ---

    ui_button :: proc(label: cstring) -> bool ---

    ui_item_activated :: proc() -> bool ---
    ui_item_deactivated :: proc() -> bool ---
    ui_any_item_active :: proc() -> bool ---
    ui_begin_combo :: proc(label, preview: cstring) -> bool ---
    ui_end_combo :: proc() ---
    ui_combo :: proc(
        label: cstring,
        selected: ^i32,
        items: [^]cstring,
        count: i32,
    ) -> bool ---

    ui_input_text :: proc(
        label: cstring,
        buffer: [^]u8,
        capacity: uint,
    ) -> bool ---
}

// Matches SceneMouse in vendor/imgui/bridge.cpp.
SceneMouse :: struct {
    x, y: f32,
    over_ui: bool,
    down: bool,
    clicked: bool,
    released: bool,
    cancel: bool,
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
    //finish edits when leaving the UI
    if g_cursor_locked {
        editor_finish_edit()
    }

    ui_begin_frame(g_cursor_locked)
    if !g_debug_ui_visible {
        editor_finish_edit()
        editor_gizmo_end(&g_scene, false)
        g_editor_gizmo.hovered = .None
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
        tone_mapper_labels := [len(ToneMapper)]cstring{"Reinhard", "ACES (fitted)", "AgX"}
        tone_mapper := i32(r.post_tone_mapper)
        if ui_combo("Tone mapping", &tone_mapper, raw_data(tone_mapper_labels[:]), i32(len(tone_mapper_labels))) {
            r.post_tone_mapper = ToneMapper(tone_mapper)
        }
        debug_ui_shadow_controls()
        debug_ui_environment_controls()

        ui_separator()
        debug_ui_text(fmt.bprintf(text_buffer[:], "FPS: %.0f | Frame: %.2f ms", r.fps, r.frame_ms))

        ui_checkbox("Frustum culling", &r.frustum_culling_enabled)

        stats := r.culling_stats
        debug_ui_text(fmt.bprintf(
            text_buffer[:],
            "Scene meshes: %d/%d | Culled: %d",
            stats.scene_visible,
            stats.scene_total,
            stats.scene_total - stats.scene_visible,
        ))

        debug_ui_text(fmt.bprintf(
            text_buffer[:],
            "Shadow draws: %d (%d casters x %d cascades)",
            stats.shadow_visible,
            stats.shadow_total,
            SHADOW_CASCADE_COUNT,
        ))

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

    editor_draw_scene(&g_scene)
    editor_draw_inspector(&g_scene)
    editor_draw_import_panel()
    editor_update_gizmo(&g_scene)

    if g_debug_ui_demo {
        ui_show_demo(&g_debug_ui_demo)
    }
    if changed {
        renderer_update_post_title()
    }

    editor_finish_idle_edit()
}

debug_ui_render :: proc() {
    if g_debug_ui_ready {
        ui_render(rawptr(g_renderer.command_list))
    }
}

debug_ui_shadow_controls :: proc() {
    r := &g_renderer
    ui_separator()
    debug_ui_text("Sun shadows (bias in shadow-map texels)")
    ui_slider_float("Shadow distance", &r.shadow_distance, MIN_SHADOW_DISTANCE, MAX_SHADOW_DISTANCE)
    ui_slider_float("Shadow bias", &r.shadow_bias_constant, 0, MAX_SHADOW_BIAS)
    ui_slider_float("Shadow slope bias", &r.shadow_bias_slope, 0, MAX_SHADOW_BIAS)
    ui_checkbox("Show shadow cascades", &r.shadow_show_cascades)
}

debug_ui_environment_controls :: proc() {
    r := &g_renderer
    settings := r.environment_settings
    if pending, ok := r.environment_pending.(EnvironmentSettings); ok do settings = pending
    changed := false
    text_buffer: [128]u8
    ui_separator()
    debug_ui_text("Ambient lighting")
    ambient_labels := [2]cstring{"HDRI", "Ambient Color"}
    ambient_mode := i32(settings.ambient_mode)
    if ui_combo("Lighting mode", &ambient_mode, raw_data(ambient_labels[:]), i32(len(ambient_labels))) {
        settings.ambient_mode = AmbientLightingMode(ambient_mode)
        changed = true
    }
    if settings.ambient_mode == .Color {
        if ui_color_edit3("Ambient color", &settings.ambient_color) do changed = true
        if ui_slider_float("Ambient intensity", &settings.ambient_intensity, 0, 8) do changed = true
    } else {
        if ui_slider_float("IBL intensity", &settings.intensity, 0, 8) do changed = true
        sun_from_hdri := !settings.manual_sun
        if ui_checkbox("Sun from HDRI", &sun_from_hdri) {
            settings.manual_sun = !sun_from_hdri
            changed = true
        }
        sun := r.environment_sun
        if !settings.manual_sun && r.environment_sun_asset == settings.asset {
            if sun.found {
                elevation := math.to_degrees(math.asin(clamp(sun.direction[1], -1, 1)))
                debug_ui_text(fmt.bprintf(
                    text_buffer[:], "HDRI sun: intensity %.2f, elevation %.0f deg",
                    sun.intensity * settings.intensity, elevation,
                ))
            } else {
                debug_ui_text("No distinct sun in this HDRI; using the scene sun.")
            }
        }
    }

    background_labels := [2]cstring{"HDRI", "Solid Color"}
    background_mode := i32(settings.background_mode)
    if ui_combo("Background", &background_mode, raw_data(background_labels[:]), i32(len(background_labels))) {
        settings.background_mode = BackgroundMode(background_mode)
        changed = true
    }
    if settings.background_mode == .Solid {
        if ui_color_edit3("Background color", &settings.background_color) do changed = true
    }
    if ui_slider_float("Background brightness", &settings.background_brightness, 0, 8) do changed = true

    // Keep selection available in color mode so a missing HDRI can be replaced
    // before enabling it. Selecting it here does not load an unused HDR file.
    preview: cstring = "Select environment"
    if assets_environment_valid(settings.asset) do preview = g_assets.environments[settings.asset].label
    if ui_begin_combo("HDRI", preview) {
        for i in 1..<len(g_assets.environments) {
            ui_push_id(i32(i))
            if ui_selectable(g_assets.environments[i].label, settings.asset == EnvironmentHandle(i)) {
                settings.asset = EnvironmentHandle(i)
                changed = true
            }
            ui_pop_id()
        }
        ui_end_combo()
    }
    if renderer_environment_needs_hdri(settings) {
        if ui_slider_float("Environment rotation", &settings.rotation_degrees, -180, 180) do changed = true
    }
    if changed do r.environment_pending = settings
    debug_ui_text("Edit sun and point lights in the Inspector.")
    if r.environment_status != "" do debug_ui_text(r.environment_status)
}
