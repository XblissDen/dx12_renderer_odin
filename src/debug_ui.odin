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
    ui_draw_circle :: proc(x, y, radius: f32, color: u32, thickness: f32) ---
    ui_radio_button :: proc(label: cstring, active: bool) -> bool ---
    ui_same_line :: proc() ---
    ui_begin_frame :: proc(cursor_locked: bool) ---
    ui_next_window :: proc(x, y, width, height: f32) ---
    ui_begin_panel :: proc(title: cstring) -> bool ---
    ui_end_panel :: proc() ---
    ui_text :: proc(text: [^]u8, length: uint) ---
    ui_text_wrapped :: proc(text: [^]u8, length: uint) ---
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

    ui_tree_row :: proc(label: cstring, selected: bool, depth: i32, has_children: bool, open: ^bool) -> bool ---
    ui_drag_entity :: proc(entity: i32, label: cstring) ---
    ui_drop_entity :: proc(entity: ^i32) -> bool ---
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

// A picker for a linear color, which it shows gamma-encoded (2.2, close to
// sRGB) so the swatch and values look like the rendered result. Keeps the
// color within 0-1.
debug_ui_linear_color :: proc(label: cstring, color: ^[3]f32) -> bool {
    picker: [3]f32
    for channel in 0..<3 do picker[channel] = math.pow(clamp(color[channel], 0, 1), 1.0 / 2.2)
    if !ui_color_edit3(label, &picker) do return false
    for channel in 0..<3 do color[channel] = math.pow(clamp(picker[channel], 0, 1), 2.2)
    return true
}

debug_ui_update :: proc() {
    if !g_debug_ui_ready {
        return
    }
    // Capturing the mouse ends any edit in progress.
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
    ui_next_window(16, 16, 360, 430)
    if ui_begin_panel("Renderer controls") {
        if g_cursor_locked {
            debug_ui_text("L: release mouse to edit controls")
        } else {
            debug_ui_text("L: capture mouse for camera")
        }
        debug_ui_text("F1: show/hide panel | Esc: quit")
        // At the top, so a shader error is in view while editing.
        debug_ui_shader_controls()
        ui_separator()

        // Do not short-circuit these calls: every widget must run each frame.
        if debug_ui_exposure_controls() do changed = true
        if ui_slider_float("Bloom threshold", &r.post_threshold, 0.1, 5.0) do changed = true
        if ui_slider_float("Bloom strength", &r.post_strength, 0.0, 2.0) do changed = true
        tone_mapper_labels := [len(ToneMapper)]cstring{"Reinhard", "ACES (fitted)", "AgX"}
        tone_mapper := i32(r.post_tone_mapper)
        if ui_combo("Tone mapping", &tone_mapper, raw_data(tone_mapper_labels[:]), i32(len(tone_mapper_labels))) {
            r.post_tone_mapper = ToneMapper(tone_mapper)
        }
        anti_aliasing_labels := [len(AntiAliasing)]cstring{"FXAA", "Off", "TAA"}
        anti_aliasing := i32(r.post_anti_aliasing)
        if ui_combo("Anti-aliasing", &anti_aliasing, raw_data(anti_aliasing_labels[:]), i32(len(anti_aliasing_labels))) {
            r.post_anti_aliasing = AntiAliasing(anti_aliasing)
        }
        if r.post_anti_aliasing == .TAA {
            ui_slider_float("Sharpening", &r.post_sharpness, 0.0, 1.0)
        }
        debug_ui_shadow_controls()
        debug_ui_environment_controls()

        ui_separator()
        ui_checkbox("Frustum culling", &r.frustum_culling_enabled)
        ui_checkbox("Occlusion culling", &r.occlusion_culling_enabled)
        ui_checkbox("Show ImGui demo", &g_debug_ui_demo)
    }
    ui_end_panel()

    debug_ui_draw_profiler()
    editor_draw_scene(&g_scene)
    editor_draw_inspector(&g_scene)
    editor_draw_import_panel()
    // Before the gizmo, which then draws over the icons.
    editor_draw_icons(&g_scene)
    editor_update_gizmo(&g_scene)

    if g_debug_ui_demo {
        ui_show_demo(&g_debug_ui_demo)
    }
    if changed {
        renderer_update_post_title()
    }

    editor_finish_idle_edit()
}

// Frame rate, what culling kept, the lights in view, and the GPU time of
// each pass.
debug_ui_draw_profiler :: proc() {
    r := &g_renderer
    text_buffer: [256]u8
    // Along the right edge of the window, wherever that is.
    ui_next_window(max(f32(r.width) - 436, 16), 16, 420, 520)
    if ui_begin_panel("Profiler") {
        debug_ui_text(fmt.bprintf(text_buffer[:], "FPS: %.0f | Frame: %.2f ms", r.fps, r.frame_ms))
        ui_separator()

        stats := r.culling_stats
        spot_shadow_count := 0
        for entity in r.spot_shadow_entities do if entity >= 0 do spot_shadow_count += 1
        point_shadow_count := 0
        for entity in r.point_shadow_entities do if entity >= 0 do point_shadow_count += 1
        // Visible draws and nonempty calls come from the GPU cull pass.
        debug_ui_text(fmt.bprintf(
            text_buffer[:],
            "Scene meshes: %d/%d | Draw calls: %d",
            stats.gpu.scene_visible,
            stats.scene_total,
            stats.gpu.scene_calls,
        ))
        debug_ui_text(fmt.bprintf(
            text_buffer[:],
            "Culled: %d (%d occluded)",
            stats.scene_total - int(stats.gpu.scene_visible),
            stats.gpu.scene_occluded,
        ))
        debug_ui_text(fmt.bprintf(
            text_buffer[:],
            "Shadow draws: %d in %d calls (%d casters)",
            stats.gpu.shadow_visible,
            stats.gpu.shadow_calls,
            stats.shadow_total,
        ))
        debug_ui_text(fmt.bprintf(
            text_buffer[:],
            "Shadow views: %d cascades, %d spot, %d point",
            SHADOW_CASCADE_COUNT,
            spot_shadow_count,
            point_shadow_count,
        ))
        debug_ui_text(fmt.bprintf(
            text_buffer[:], "Point and spot lights: %d in view of %d (clustered)",
            r.visible_light_count, r.scene_light_count,
        ))
        if stats.draws_dropped {
            debug_ui_text(fmt.bprintf(
                text_buffer[:], "Draws skipped: over %d draws or %d calls in a frame",
                MAX_DRAWS, MAX_DRAW_CALLS,
            ))
        }
        ui_separator()

        pass_names := [GPU_PASS_COUNT]string{
            "Shadow", "Scene", "Bloom prefilter", "Bloom downsample",
            "Bloom upsample", "Post + UI", "Depth prepass", "SSAO + blur", "FXAA / sharpen", "TAA resolve",
            "Auto exposure", "SSR", "Light clusters", "Volumetric fog", "GPU culling", "Occlusion culling",
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
    }
    ui_end_panel()
}

// Shaders reload by themselves when a file in shaders/ is saved; the button
// forces it, including the IBL re-bake.
debug_ui_shader_controls :: proc() {
    r := &g_renderer
    if ui_button("Reload shaders") {
        r.shader_stamp = 0
        r.environment_shader_stamp = 0
    }
    ui_same_line()
    text_buffer: [128]u8
    switch {
    case r.shader_error != "":
        debug_ui_text("Failed: previous shaders kept")
    case r.shader_reload_count > 0:
        debug_ui_text(fmt.bprintf(text_buffer[:], "Reloaded (%.0f ms)", r.shader_reload_ms))
    case:
        debug_ui_text("Watching shaders/")
    }
    if r.shader_error != "" {
        ui_text_wrapped(raw_data(r.shader_error), uint(len(r.shader_error)))
    }
}

debug_ui_render :: proc() {
    if g_debug_ui_ready {
        ui_render(rawptr(g_renderer.command_list))
    }
}

// Manual exposure, or auto-exposure and its settings. True when the title's
// exposure value changed.
debug_ui_exposure_controls :: proc() -> (changed: bool) {
    r := &g_renderer
    s := &r.auto_exposure
    // Turning it on starts from the measured exposure instead of adapting.
    if ui_checkbox("Auto exposure", &s.enabled) {
        r.auto_exposure_reset = true
        changed = true
    }
    if !s.enabled {
        return ui_slider_float("Exposure", &r.post_exposure, 0.1, 5.0) || changed
    }
    text_buffer: [64]u8
    debug_ui_text(fmt.bprintf(text_buffer[:], "Current: %+.2f EV (x%.3f)", r.auto_exposure_ev + s.compensation,
        math.pow(f32(2), r.auto_exposure_ev + s.compensation)))
    if ui_slider_float("Compensation (EV)", &s.compensation, -5, 5) do changed = true
    // Keep the limits ordered while dragging either one.
    if ui_slider_float("Min EV", &s.min_ev, -16, 16) do s.max_ev = max(s.max_ev, s.min_ev)
    if ui_slider_float("Max EV", &s.max_ev, -16, 16) do s.min_ev = min(s.min_ev, s.max_ev)
    ui_slider_float("Adapt to dark (/s)", &s.adapt_dark, 0.1, 10)
    ui_slider_float("Adapt to bright (/s)", &s.adapt_bright, 0.1, 10)
    return
}

debug_ui_shadow_controls :: proc() {
    r := &g_renderer
    ui_separator()
    debug_ui_text("Sun shadows (bias in shadow-map texels)")
    ui_slider_float("Shadow distance", &r.shadow_distance, MIN_SHADOW_DISTANCE, MAX_SHADOW_DISTANCE)
    ui_slider_float("Shadow bias", &r.shadow_bias_constant, 0, MAX_SHADOW_BIAS)
    ui_slider_float("Shadow slope bias", &r.shadow_bias_slope, 0, MAX_SHADOW_BIAS)
    ui_checkbox("Show shadow cascades", &r.shadow_show_cascades)

    ui_separator()
    ui_checkbox("Ambient occlusion (SSAO)", &r.ao_enabled)
    if r.ao_enabled {
        ui_slider_float("AO radius", &r.ao_radius, MIN_AO_RADIUS, MAX_AO_RADIUS)
        ui_slider_float("AO intensity", &r.ao_intensity, 0, MAX_AO_INTENSITY)
        ui_checkbox("Show AO only", &r.ao_show)
    }

    ui_separator()
    ui_checkbox("Screen-space reflections (SSR)", &r.ssr_enabled)
    if r.ssr_enabled {
        ui_slider_float("SSR max distance", &r.ssr_max_distance, MIN_SSR_MAX_DISTANCE, MAX_SSR_MAX_DISTANCE)
        ui_slider_float("SSR thickness", &r.ssr_thickness, MIN_SSR_THICKNESS, MAX_SSR_THICKNESS)
        ui_slider_float("SSR max roughness", &r.ssr_max_roughness, MIN_SSR_MAX_ROUGHNESS, MAX_SSR_MAX_ROUGHNESS)
        ui_checkbox("Show reflections only", &r.ssr_show)
    }

    ui_separator()
    ui_checkbox("Show light clusters", &r.light_show_clusters)

    ui_separator()
    fog := &r.fog
    ui_checkbox("Volumetric fog", &fog.enabled)
    if fog.enabled {
        ui_slider_float("Fog density", &fog.density, 0, MAX_FOG_DENSITY)
        ui_slider_float("Fog height", &fog.height, MIN_FOG_HEIGHT, MAX_FOG_HEIGHT)
        ui_slider_float("Fog height falloff", &fog.height_falloff, 0, MAX_FOG_HEIGHT_FALLOFF)
        debug_ui_linear_color("Fog color", &fog.color)
        ui_slider_float("Fog anisotropy", &fog.anisotropy, -MAX_FOG_ANISOTROPY, MAX_FOG_ANISOTROPY)
        ui_slider_float("Fog sky light", &fog.ambient, 0, MAX_FOG_AMBIENT)
        ui_slider_float("Fog distance", &fog.distance, MIN_FOG_DISTANCE, MAX_FOG_DISTANCE)
    }
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
        if debug_ui_linear_color("Ambient color", &settings.ambient_color) do changed = true
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
        if debug_ui_linear_color("Background color", &settings.background_color) do changed = true
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
