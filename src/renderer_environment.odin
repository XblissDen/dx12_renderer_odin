package main

import c "core:c"
import "core:math"
import "core:os"
import "core:strings"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import stbi "vendor:stb/image"

// HDRI ambient and background modes use the environment's panorama: the
// HDRI asset's, or the physical sky's (EnvironmentSource).
AmbientLightingMode :: enum u32 {HDRI, Color}
BackgroundMode :: enum u32 {HDRI, Solid}
EnvironmentSource :: enum u32 {HDRI, Physical_Sky}

EnvironmentSettings :: struct {
    // Where the panorama comes from. Absent in older files: an HDRI.
    source: EnvironmentSource,
    // The physical sky's settings (zero in older files: the defaults then).
    sky: SkySettings,
    asset: EnvironmentHandle,
    intensity: f32,
    rotation_degrees: f32,
    background_brightness: f32,
    ambient_mode: AmbientLightingMode,
    ambient_color: [3]f32,
    ambient_intensity: f32,
    background_mode: BackgroundMode,
    background_color: [3]f32,
    // With HDRI lighting, the panorama's sun normally becomes the shadowed
    // directional light and is removed from the IBL maps. Set to keep the
    // scene's own sun and the unmodified IBL. Absent in older files (false).
    // With the physical sky, the sky's sun likewise drives the scene's.
    manual_sun: bool,
}

// A physically based sky (Hillaire, "A Scalable and Production Ready Sky and
// Atmosphere Rendering Technique", 2020): Earth's atmosphere seen from the
// ground, lit by a sun that crosses it with the time of day. The sun follows
// an equinox day: it rises due east (+X) at 6, is highest at noon, toward -Z,
// and sets due west at 18.
SkySettings :: struct {
    // Hours, 0 to 24.
    time_of_day: f32,
    // Hours the time of day moves on per second (0: it stays put).
    time_speed: f32,
    // Degrees: how far from overhead the sun passes at noon.
    latitude: f32,
    // Degrees: turns the sun's path about the vertical.
    heading: f32,
    // Aerosols: multiplies the haze (Mie) density; 1 is a clear day.
    haze: f32,
    // The sun's irradiance above the atmosphere, as a directional light's
    // intensity; the atmosphere dims and reddens it on the way down.
    sun_intensity: f32,
}

DEFAULT_SKY :: SkySettings{time_of_day = 10, latitude = 40, haze = 1, sun_intensity = 10}
MAX_SKY_HAZE :: f32(20)
MAX_SKY_TIME_SPEED :: f32(4)
MAX_SKY_SUN_INTENSITY :: f32(100)

sky_settings_valid :: proc(sky: SkySettings) -> bool {
    return sky.time_of_day >= 0 && sky.time_of_day <= 24 &&
           abs(sky.time_speed) <= MAX_SKY_TIME_SPEED &&
           sky.latitude >= 0 && sky.latitude <= 90 &&
           sky.heading >= -180 && sky.heading <= 180 &&
           sky.haze >= 0 && sky.haze <= MAX_SKY_HAZE &&
           sky.sun_intensity >= 0 && sky.sun_intensity <= MAX_SKY_SUN_INTENSITY
}

// Toward the sky's sun, in world space.
sky_sun_direction :: proc(sky: SkySettings) -> [3]f32 {
    hour_angle := (sky.time_of_day - 12) / 24 * 2 * math.PI
    latitude := math.to_radians(sky.latitude)
    // Where it is at noon, and the east it rises in: the day's circle passes
    // through both, at 6 and 18 on the horizon.
    noon := [3]f32{0, math.cos(latitude), -math.sin(latitude)}
    toward := noon * math.cos(hour_angle) - [3]f32{1, 0, 0} * math.sin(hour_angle)
    heading := math.to_radians(sky.heading)
    s, c := math.sin(heading), math.cos(heading)
    return {c * toward.x + s * toward.z, toward.y, -s * toward.x + c * toward.z}
}

// Earth's atmosphere, in kilometers (atmosphere.hlsl has the same values):
// the ground and the top, Rayleigh scattering (air), Mie scattering and
// absorption (haze), and ozone absorption, each per km at sea level.
SKY_PLANET_RADIUS :: 6360.0
SKY_ATMOSPHERE_RADIUS :: 6460.0
SKY_VIEWER_HEIGHT :: f32(0.02)
SKY_GROUND_ALBEDO :: f32(0.3)
SKY_RAYLEIGH_SCATTERING :: [3]f64{5.802e-3, 13.558e-3, 33.1e-3}
SKY_RAYLEIGH_HEIGHT :: 8.0
SKY_MIE_SCATTERING :: 3.996e-3
SKY_MIE_ABSORPTION :: 4.40e-3
SKY_MIE_HEIGHT :: 1.2
SKY_OZONE_ABSORPTION :: [3]f64{0.650e-3, 1.881e-3, 0.085e-3}

// How much sunlight reaches the viewer through the atmosphere, per color:
// none once the sun is below the horizon. The CPU's copy of the shaders'
// transmittance, for the sun's color and its disc.
sky_sun_transmittance :: proc(sky: SkySettings, toward_sun: [3]f32) -> [3]f32 {
    origin := [3]f64{0, SKY_PLANET_RADIUS + f64(SKY_VIEWER_HEIGHT), 0}
    direction := [3]f64{f64(toward_sun.x), f64(toward_sun.y), f64(toward_sun.z)}
    if sky_ray_sphere(origin, direction, SKY_PLANET_RADIUS) >= 0 do return {}
    length := sky_ray_sphere(origin, direction, SKY_ATMOSPHERE_RADIUS)
    STEPS :: 64
    depth: [3]f64
    for i in 0..<STEPS {
        t := (f64(i) + 0.5) / STEPS * length
        p := origin + direction * t
        height := math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z) - SKY_PLANET_RADIUS
        mie := math.exp(-height / SKY_MIE_HEIGHT) * f64(sky.haze)
        ozone := max(0, 1 - abs(height - 25) / 15)
        extinction := SKY_RAYLEIGH_SCATTERING * math.exp(-height / SKY_RAYLEIGH_HEIGHT) +
                      (SKY_MIE_SCATTERING + SKY_MIE_ABSORPTION) * mie + SKY_OZONE_ABSORPTION * ozone
        depth += extinction * (length / STEPS)
    }
    return {f32(math.exp(-depth.x)), f32(math.exp(-depth.y)), f32(math.exp(-depth.z))}
}

// Distance along the ray to the sphere of this radius around the planet's
// center (the nearest crossing ahead), or -1.
sky_ray_sphere :: proc(origin, direction: [3]f64, radius: f64) -> f64 {
    b := origin.x * direction.x + origin.y * direction.y + origin.z * direction.z
    c := origin.x * origin.x + origin.y * origin.y + origin.z * origin.z - radius * radius
    discriminant := b * b - c
    if discriminant < 0 do return -1
    s := math.sqrt(discriminant)
    if -b - s >= 0 do return -b - s
    if -b + s >= 0 do return -b + s
    return -1
}

// The physical sky's sun as the scene's directional light, when it drives it.
renderer_sky_sun :: proc() -> (light: DirectionalLight, ok: bool) {
    settings := g_renderer.environment_settings
    if settings.source != .Physical_Sky || settings.manual_sun do return {}, false
    toward := sky_sun_direction(settings.sky)
    return DirectionalLight{
        direction = -toward,
        color = sky_sun_transmittance(settings.sky, toward),
        intensity = settings.sky.sun_intensity,
    }, true
}

// The sun found in a panorama, in panorama space (before environment rotation).
HdriSun :: struct {
    direction: [3]f32, // toward the sun
    color: [3]f32,     // brightest channel is 1
    intensity: f32,    // color * intensity = irradiance at normal incidence
    found: bool,
}

// Texels brighter than this fraction of the peak, connected to it, form the sun.
HDRI_SUN_RELATIVE_THRESHOLD :: f32(0.001)
// A sun must carry this share of the panorama's light...
HDRI_SUN_MIN_ENERGY_SHARE :: f64(0.25)
// ...from a compact region (the real sun disk is about 0.00007 sr).
HDRI_SUN_MAX_SOLID_ANGLE :: f64(0.05)

hdri_luminance :: proc(r, g, b: f32) -> f32 {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// Panorama direction for a texel center, matching DirectionToUV in the shaders.
hdri_texel_direction :: proc(x, y, width, height: int) -> [3]f32 {
    phi := ((f32(x) + 0.5) / f32(width) - 0.5) * 2 * math.PI
    theta := (f32(y) + 0.5) / f32(height) * math.PI
    return {math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi)}
}

// Finds the sun as the region around the brightest texel and measures the light
// it adds above the surrounding sky. With `remove`, those texels are replaced by
// that sky, so the light can move from the IBL maps to the directional light
// without being counted twice.
hdri_extract_sun :: proc(pixels: []f32, width, height: int, remove: bool) -> (sun: HdriSun) {
    texel_count := width * height
    peak: f32
    peak_index := 0
    total_energy: f64
    for y in 0..<height {
        solid_angle := hdri_row_solid_angle(y, width, height)
        for x in 0..<width {
            i := y * width + x
            l := hdri_luminance(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2])
            total_energy += f64(max(l, 0)) * solid_angle
            if l > peak {
                peak = l
                peak_index = i
            }
        }
    }
    if peak <= 0 || total_energy <= 0 {
        return
    }

    // Flood-fill the bright region connected to the peak, wrapping horizontally.
    threshold := peak * HDRI_SUN_RELATIVE_THRESHOLD
    in_sun := make([]bool, texel_count)
    defer delete(in_sun)
    region := make([dynamic]int)
    defer delete(region)

    in_sun[peak_index] = true
    append(&region, peak_index)
    region_solid_angle: f64
    for next := 0; next < len(region); next += 1 {
        i := region[next]
        x, y := i % width, i / width
        region_solid_angle += hdri_row_solid_angle(y, width, height)
        if region_solid_angle > HDRI_SUN_MAX_SOLID_ANGLE {
            return // Too large to be a sun: an overcast sky or a bright interior.
        }

        neighbors := [4][2]int{{(x + width - 1) % width, y}, {(x + 1) % width, y}, {x, y - 1}, {x, y + 1}}
        for n in neighbors {
            if n[1] < 0 || n[1] >= height do continue
            j := n[1] * width + n[0]
            if in_sun[j] do continue
            if hdri_luminance(pixels[j * 4], pixels[j * 4 + 1], pixels[j * 4 + 2]) > threshold {
                in_sun[j] = true
                append(&region, j)
            }
        }
    }

    // The sky just outside the region stands in for the sky behind the sun.
    fill: [3]f64
    fill_count := 0
    for i in region {
        x, y := i % width, i / width
        neighbors := [4][2]int{{(x + width - 1) % width, y}, {(x + 1) % width, y}, {x, y - 1}, {x, y + 1}}
        for n in neighbors {
            if n[1] < 0 || n[1] >= height do continue
            j := n[1] * width + n[0]
            if in_sun[j] do continue
            for c in 0..<3 do fill[c] += f64(pixels[j * 4 + c])
            fill_count += 1
        }
    }
    if fill_count > 0 {
        for c in 0..<3 do fill[c] /= f64(fill_count)
    }

    irradiance: [3]f64
    weighted_direction: [3]f64
    for i in region {
        x, y := i % width, i / width
        solid_angle := hdri_row_solid_angle(y, width, height)
        excess: [3]f64
        for c in 0..<3 do excess[c] = max(f64(pixels[i * 4 + c]) - fill[c], 0) * solid_angle
        irradiance += excess

        direction := hdri_texel_direction(x, y, width, height)
        weight := f64(hdri_luminance(f32(excess[0]), f32(excess[1]), f32(excess[2])))
        for c in 0..<3 do weighted_direction[c] += f64(direction[c]) * weight
    }

    sun_energy := f64(hdri_luminance(f32(irradiance[0]), f32(irradiance[1]), f32(irradiance[2])))
    brightest := max(irradiance[0], irradiance[1], irradiance[2])
    direction_length := math.sqrt(
        weighted_direction[0] * weighted_direction[0] +
        weighted_direction[1] * weighted_direction[1] +
        weighted_direction[2] * weighted_direction[2],
    )
    if sun_energy < HDRI_SUN_MIN_ENERGY_SHARE * total_energy || brightest <= 0 || direction_length <= 0 {
        return
    }

    sun.found = true
    sun.intensity = f32(brightest)
    for c in 0..<3 {
        sun.color[c] = f32(irradiance[c] / brightest)
        sun.direction[c] = f32(weighted_direction[c] / direction_length)
    }

    if remove {
        for i in region {
            for c in 0..<3 do pixels[i * 4 + c] = f32(fill[c])
        }
    }
    return
}

hdri_row_solid_angle :: proc(y, width, height: int) -> f64 {
    theta := (f64(y) + 0.5) / f64(height) * math.PI
    return (2 * math.PI / f64(width)) * (math.PI / f64(height)) * math.sin(theta)
}

// The panorama's radiance averaged over the sphere (rows weighted by their
// solid angle): the light something receives from every direction equally.
hdri_average_radiance :: proc(pixels: []f32, width, height: int) -> [3]f32 {
    sum: [3]f64
    for y in 0..<height {
        row: [3]f64
        for x in 0..<width {
            i := (y * width + x) * 4
            for c in 0..<3 do row[c] += f64(pixels[i + c])
        }
        weight := hdri_row_solid_angle(y, width, height)
        for c in 0..<3 do sum[c] += row[c] * weight
    }
    return {f32(sum[0] / (4 * math.PI)), f32(sum[1] / (4 * math.PI)), f32(sum[2] / (4 * math.PI))}
}

// The HDRI sun as a world-space directional light, when it drives the scene.
renderer_hdri_sun :: proc() -> (light: DirectionalLight, ok: bool) {
    r := &g_renderer
    settings := r.environment_settings
    sun := r.environment_sun
    if settings.source != .HDRI || settings.ambient_mode != .HDRI || settings.manual_sun || !sun.found ||
       r.environment_sun_asset != settings.asset ||
       r.environment_filtered_asset != settings.asset {
        return {}, false
    }

    // Undo the panorama rotation that EnvironmentDirection applies in the shaders.
    s := math.sin(math.to_radians(settings.rotation_degrees))
    c := math.cos(math.to_radians(settings.rotation_degrees))
    p := sun.direction
    toward_sun := [3]f32{c * p[0] + s * p[2], p[1], -s * p[0] + c * p[2]}

    return DirectionalLight{
        direction = -toward_sun,
        color = sun.color,
        intensity = sun.intensity * settings.intensity,
    }, true
}

renderer_default_environment_settings :: proc() -> (settings: EnvironmentSettings) {
    settings = {
        asset = g_assets.default_environment, intensity = 1, background_brightness = 1,
        ambient_color = {0.15, 0.18, 0.22}, ambient_intensity = 1,
        background_color = {0.05, 0.06, 0.08},
        sky = DEFAULT_SKY,
    }
    if !assets_environment_valid(settings.asset) || !os.exists(g_assets.environments[settings.asset].desc.path) {
        settings.ambient_mode = .Color
        settings.background_mode = .Solid
    }
    return
}

// Whether the ambient light or the background uses the panorama.
renderer_environment_uses_panorama :: proc(settings: EnvironmentSettings) -> bool {
    return settings.ambient_mode == .HDRI || settings.background_mode == .HDRI
}

renderer_environment_needs_hdri :: proc(settings: EnvironmentSettings) -> bool {
    return settings.source == .HDRI && renderer_environment_uses_panorama(settings)
}

renderer_environment_settings_valid :: proc(settings: EnvironmentSettings) -> bool {
    if settings.ambient_mode != .HDRI && settings.ambient_mode != .Color do return false
    if settings.background_mode != .HDRI && settings.background_mode != .Solid do return false
    if settings.source != .HDRI && settings.source != .Physical_Sky do return false
    if !sky_settings_valid(settings.sky) do return false
    if settings.asset != 0 && !assets_environment_valid(settings.asset) do return false
    if renderer_environment_needs_hdri(settings) && !assets_environment_valid(settings.asset) do return false
    for color in settings.ambient_color do if !(color >= 0 && color <= 1) do return false
    for color in settings.background_color do if !(color >= 0 && color <= 1) do return false
    return settings.ambient_intensity >= 0 && settings.ambient_intensity <= 32 &&
           settings.intensity >= 0 && settings.intensity <= 32 &&
           settings.background_brightness >= 0 && settings.background_brightness <= 32 &&
           !math.is_nan(settings.rotation_degrees) && !math.is_inf(settings.rotation_degrees)
}

renderer_set_environment :: proc(settings: EnvironmentSettings) -> string {
    r := &g_renderer
    if !renderer_environment_settings_valid(settings) do return "Invalid environment settings."

    load_sky := renderer_environment_needs_hdri(settings) &&
                (r.environment_texture == nil || r.environment_loaded_asset != settings.asset)
    remove_sun := !settings.manual_sun
    // The physical sky bakes its own maps, every time it changes.
    bake := settings.source == .HDRI && settings.ambient_mode == .HDRI &&
            (load_sky ||
             r.environment_filtered_asset != settings.asset ||
             r.environment_filtered_without_sun != remove_sun)

    if load_sky || bake {
        // Earlier frames may still reference the old textures, descriptors,
        // and the upload allocator.
        renderer_wait_for_gpu()
        desc := g_assets.environments[settings.asset].desc
        if error := renderer_load_environment(desc, load_sky, bake, remove_sun); error != "" do return error
        r.environment_sun_asset = settings.asset
        if load_sky {
            r.environment_loaded_asset = settings.asset
            if !bake do r.environment_filtered_asset = 0
        }
        if bake {
            r.environment_filtered_asset = settings.asset
            r.environment_filtered_without_sun = remove_sun
        }
    }
    // The probes captured this environment's light. Changes to the sky alone
    // (dragging the time of day) are left to renderer_update_sky, which
    // captures again once the sky settles.
    other := settings
    other.sky = r.environment_settings.sky
    if other != r.environment_settings do renderer_recapture_probes()
    if settings.source == .Physical_Sky do r.sky.dirty = true
    r.environment_settings = settings
    return ""
}

renderer_process_environment_change :: proc() {
    r := &g_renderer
    settings, pending := r.environment_pending.(EnvironmentSettings)
    if !pending do return
    r.environment_pending = nil
    r.environment_status = renderer_set_environment(settings)
}

// Decodes the panorama, finds its sun, uploads it for the sky when `load_sky`,
// and rebuilds the IBL maps when `bake`. The sky is BC6H (environment_prepare),
// whose half floats would clamp a sun brighter than 65504 and blur it into
// its blocks, so the maps are baked from a temporary full-float copy instead.
// With `remove_sun`, that copy leaves the sun out, which then lights the scene
// as the shadowed directional light. The sky always shows the original.
renderer_load_environment :: proc(desc: EnvironmentDesc, load_sky, bake, remove_sun: bool) -> string {
    r := &g_renderer

    width, height, channels: c.int
    decoded := stbi.loadf(
        strings.clone_to_cstring(desc.path, context.temp_allocator) or_else panic("Environment path allocation failed"),
        &width, &height, &channels,
        4, // Request RGBA floats.
    )
    if decoded == nil {
        return "Could not decode the environment HDR file."
    }
    defer stbi.image_free(rawptr(decoded))
    if width <= 0 || height <= 0 do return "The environment HDR has invalid dimensions."
    pixels := decoded[:int(width) * int(height) * 4]

    // Measure first: removal below modifies the pixels in place.
    r.environment_sun = hdri_extract_sun(pixels, int(width), int(height), false)

    if load_sky {
        sky_data := environment_prepare(desc, pixels, u32(width), u32(height))
        defer texture_data_destroy(&sky_data)
        sky := GpuTexture{srv_index = r.environment_srv_index}
        if renderer_upload_texture(&sky, sky_data) < 0 do return "Could not upload the environment texture."
        if r.environment_texture != nil do r.environment_texture->Release()
        r.environment_texture = sky.resource
    }
    if !bake {
        return ""
    }

    if remove_sun && r.environment_sun.found {
        hdri_extract_sun(pixels, int(width), int(height), true)
    }
    source_data := environment_encode(pixels, u32(width), u32(height), .R32G32B32A32_FLOAT)
    defer texture_data_destroy(&source_data)
    source := GpuTexture{srv_index = r.environment_bake_srv_index}
    if renderer_upload_texture(&source, source_data) < 0 do return "Could not upload the environment for baking."
    // Both passes below wait for the GPU, so the source can be released after.
    defer source.resource->Release()

    r.environment_average_radiance = hdri_average_radiance(pixels, int(width), int(height))

    if r.irradiance_texture == nil do renderer_create_irradiance_map()
    if r.prefilter_texture == nil do renderer_create_prefiltered_environment()
    renderer_generate_irradiance(source.srv_index)
    renderer_generate_prefiltered_environment(source.srv_index)
    return ""
}

renderer_create_irradiance_map :: proc() {
    r := &g_renderer

    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = 1,
        Type = .RTV,
    }
    dx_check(r.device->CreateDescriptorHeap(
        &rtv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.irradiance_rtv_heap),
    ))

    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = IRRADIANCE_WIDTH,
        Height = IRRADIANCE_HEIGHT,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }

    clear_value := d3d12.CLEAR_VALUE{
        Format = .R16G16B16A16_FLOAT,
    }
    clear_value.Color = {0, 0, 0, 1}
    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.irradiance_texture),
    ))

    r.device->CreateRenderTargetView(r.irradiance_texture, nil, descriptor_handle(r.irradiance_rtv_heap, .RTV, 0))
    renderer_write_srv(r.irradiance_texture, .R16G16B16A16_FLOAT, r.irradiance_srv_index)
}

// Bakes the irradiance map from the panorama at `source_srv_index`, and waits
// for the GPU.
renderer_generate_irradiance :: proc(source_srv_index: u32) {
    r := &g_renderer
    // The environment upload has completed before this procedure runs.
    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))
    renderer_record_irradiance(source_srv_index)
    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()
}

// Records the irradiance bake into the open command list.
renderer_record_irradiance :: proc(source_srv_index: u32) {
    r := &g_renderer
    renderer_begin_event("Irradiance bake")

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.irradiance_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.irradiance_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    r.command_list->OMSetRenderTargets(1, &rtv, false, nil)

    viewport := d3d12.VIEWPORT{
        Width = IRRADIANCE_WIDTH,
        Height = IRRADIANCE_HEIGHT,
        MinDepth = 0,
        MaxDepth = 1,
    }
    scissor := d3d12.RECT{
        right = IRRADIANCE_WIDTH,
        bottom = IRRADIANCE_HEIGHT,
    }
    r.command_list->RSSetViewports(1, &viewport)
    r.command_list->RSSetScissorRects(1, &scissor)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.irradiance_pipeline_state)

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))

    renderer_bind_srv(.Environment, source_srv_index)

    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)
    renderer_end_event()
}

// Importance samples per texel when the physical sky is prefiltered: its
// panorama is smooth (no sun disc) and has mips, so few samples cover each
// lobe, and the bake fits in a frame.
SKY_PREFILTER_SAMPLES :: 64

// The prefiltered specular map: each mip holds the panorama blurred for one
// roughness, from 0 at mip 0 to 1 at the last, with a constant slot per mip:
// one set for HDRIs, then one with fewer samples for the physical sky.
renderer_create_prefiltered_environment :: proc() {
    r := &g_renderer

    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = PREFILTER_MIP_COUNT,
        Type = .RTV,
    }
    dx_check(r.device->CreateDescriptorHeap(
        &rtv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.prefilter_rtv_heap),
    ))

    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = PREFILTER_WIDTH,
        Height = PREFILTER_HEIGHT,
        DepthOrArraySize = 1,
        MipLevels = PREFILTER_MIP_COUNT,
        Format = .R16G16B16A16_FLOAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }

    clear_value := d3d12.CLEAR_VALUE{
        Format = .R16G16B16A16_FLOAT,
    }
    clear_value.Color = {0, 0, 0, 1}
    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.prefilter_texture),
    ))

    for mip in 0..<PREFILTER_MIP_COUNT {
        rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC{
            Format = .R16G16B16A16_FLOAT,
            ViewDimension = .TEXTURE2D,
        }
        rtv_desc.Texture2D = {MipSlice = u32(mip)}
        r.device->CreateRenderTargetView(r.prefilter_texture, &rtv_desc, descriptor_handle(r.prefilter_rtv_heap, .RTV, u32(mip)))
    }

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R16G16B16A16_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = PREFILTER_MIP_COUNT}
    r.device->CreateShaderResourceView(r.prefilter_texture, &srv_desc, renderer_srv_cpu(r.prefilter_srv_index))

    // One 256-byte constant-buffer slot for each mip's roughness.
    mapped: rawptr
    r.prefilter_constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(size_of(PrefilterConstants) * PREFILTER_MIP_COUNT * 2))
    r.prefilter_cb_mapped_data = ([^]PrefilterConstants)(mapped)

    for mip in 0..<PREFILTER_MIP_COUNT {
        roughness := f32(mip) / f32(PREFILTER_MIP_COUNT - 1)
        r.prefilter_cb_mapped_data[mip] = {roughness = roughness, sample_count = 1024}
        r.prefilter_cb_mapped_data[PREFILTER_MIP_COUNT + mip] = {roughness = roughness, sample_count = SKY_PREFILTER_SAMPLES}
    }
}

// Renders every mip of the prefiltered map from the panorama at
// `source_srv_index`, and waits for the GPU.
renderer_generate_prefiltered_environment :: proc(source_srv_index: u32) {
    r := &g_renderer
    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))
    renderer_record_prefiltered_environment(source_srv_index, sky = false)
    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()
}

// Records the prefilter bake into the open command list; `sky` uses the
// physical sky's sample counts.
renderer_record_prefiltered_environment :: proc(source_srv_index: u32, sky: bool) {
    r := &g_renderer
    renderer_begin_event("Prefilter bake")

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.prefilter_texture,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.prefilter_pipeline_state)

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))

    renderer_bind_srv(.Environment, source_srv_index)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)

    for mip in 0..<PREFILTER_MIP_COUNT {
        mip_width := u32(PREFILTER_WIDTH) >> u32(mip)
        mip_height := u32(PREFILTER_HEIGHT) >> u32(mip)

        rtv := descriptor_handle(r.prefilter_rtv_heap, .RTV, u32(mip))
        r.command_list->OMSetRenderTargets(1, &rtv, false, nil)

        viewport := d3d12.VIEWPORT{
            Width = f32(mip_width),
            Height = f32(mip_height),
            MinDepth = 0,
            MaxDepth = 1,
        }
        scissor := d3d12.RECT{
            right = i32(mip_width),
            bottom = i32(mip_height),
        }
        r.command_list->RSSetViewports(1, &viewport)
        r.command_list->RSSetScissorRects(1, &scissor)

        cb_offset := u64(mip + (PREFILTER_MIP_COUNT if sky else 0)) * u64(size_of(PrefilterConstants))
        renderer_bind_cbv(
            .Prefilter_Constants,
            r.prefilter_constant_buffer->GetGPUVirtualAddress() + cb_offset,
        )

        r.command_list->DrawInstanced(3, 1, 0, 0)
    }

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)
    renderer_end_event()
}

// ---------------------------------------------------------------------------
// The physical sky on the GPU (atmosphere.hlsl). Two lookup tables describe
// the atmosphere: the transmittance from any height in any direction to
// space, and the light scattered more than once, per height and sun angle.
// From them the sky is ray-marched into a panorama, each mip at its own
// size, without the sun's disc (the background draws that). The panorama
// then goes through the same irradiance and prefilter bakes as an HDRI, but
// inside the frame and with fewer samples, whenever the sky changes. The
// tables are redrawn only when the haze changes.
SKY_PANORAMA_WIDTH :: 1024
SKY_PANORAMA_HEIGHT :: 512
SKY_PANORAMA_MIPS :: 8
SKY_TRANSMITTANCE_WIDTH :: 256
SKY_TRANSMITTANCE_HEIGHT :: 64
SKY_MULTIPLE_SCATTERING_SIZE :: 32
SKY_FORMAT :: dxgi.FORMAT.R16G16B16A16_FLOAT
// SRVs and RTVs: the transmittance table, the multiple-scattering table, then
// the panorama (one SRV, an RTV per mip).
SKY_TRANSMITTANCE :: 0
SKY_MULTIPLE_SCATTERING :: 1
SKY_PANORAMA :: 2
// The irradiance map's bytes per frame slot in the readback buffer: 8 per
// texel, rows of 512 bytes (a multiple of the 256-byte pitch alignment).
SKY_READBACK_SLOT :: IRRADIANCE_WIDTH * IRRADIANCE_HEIGHT * 8
// Captures follow the sky: reflection probes every few seconds while it keeps
// changing and once it has settled; baked irradiance volumes (seconds of
// work) only once it has settled.
SKY_SETTLE_SECONDS :: f32(0.5)
SKY_RECAPTURE_SECONDS :: f32(3)

// atmosphere.hlsl's cbuffer (b3).
AtmosphereConstants :: struct #align(256) {
    sun_direction: [3]f32, // Toward the sun.
    haze: f32,
    sun_irradiance: [3]f32, // Above the atmosphere.
    viewer_height: f32,     // Kilometers.
    ground_albedo: f32,
    _pad: [3]f32,
}

Sky :: struct {
    transmittance, multiple_scattering, panorama: ^d3d12.IResource,
    rtv_heap: ^d3d12.IDescriptorHeap,
    srv_start: u32,
    transmittance_pipeline, multiple_scattering_pipeline, panorama_pipeline: ^d3d12.IPipelineState,
    // Per frame slot.
    constant_buffer: ^d3d12.IResource,
    constants: [^]AtmosphereConstants,
    // The irradiance map copied back per frame slot, for the fog's sky light
    // (the panorama's average radiance), read when the slot comes round again.
    readback: ^d3d12.IResource,
    readback_pending: [FRAME_COUNT]bool,
    // The settings the maps hold, and whether they must be baked regardless
    // (new sky, shaders reloaded, an HDRI overwrote the maps). The haze the
    // tables were drawn with (negative: none yet).
    baked: SkySettings,
    dirty: bool,
    table_haze: f32,
    // A bake happened this frame; seconds since the last one and since the
    // last probe capture; captures still owed to the latest sky.
    rebaked: bool,
    still_time, since_capture: f32,
    probes_stale, volumes_stale: bool,
}

renderer_create_sky :: proc() {
    r := &g_renderer
    s := &r.sky
    s.table_haze = -1
    s.srv_start = renderer_alloc_srv(3)
    heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = 2 + SKY_PANORAMA_MIPS, Type = .RTV}
    dx_check(r.device->CreateDescriptorHeap(&heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&s.rtv_heap)))

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    clear_value := d3d12.CLEAR_VALUE{Format = SKY_FORMAT}
    sizes := [3][3]u32{
        {SKY_TRANSMITTANCE_WIDTH, SKY_TRANSMITTANCE_HEIGHT, 1},
        {SKY_MULTIPLE_SCATTERING_SIZE, SKY_MULTIPLE_SCATTERING_SIZE, 1},
        {SKY_PANORAMA_WIDTH, SKY_PANORAMA_HEIGHT, SKY_PANORAMA_MIPS},
    }
    targets := [3]^^d3d12.IResource{&s.transmittance, &s.multiple_scattering, &s.panorama}
    for target, i in targets {
        desc := d3d12.RESOURCE_DESC{
            Dimension = .TEXTURE2D,
            Width = u64(sizes[i][0]),
            Height = sizes[i][1],
            DepthOrArraySize = 1,
            MipLevels = u16(sizes[i][2]),
            Format = SKY_FORMAT,
            SampleDesc = {Count = 1},
            Flags = {.ALLOW_RENDER_TARGET},
        }
        dx_check(r.device->CreateCommittedResource(
            &heap_props, {}, &desc, {.PIXEL_SHADER_RESOURCE}, &clear_value,
            d3d12.IResource_UUID, (^rawptr)(target),
        ))
        srv := d3d12.SHADER_RESOURCE_VIEW_DESC{
            Format = SKY_FORMAT,
            ViewDimension = .TEXTURE2D,
            Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        }
        srv.Texture2D = {MipLevels = sizes[i][2]}
        r.device->CreateShaderResourceView(target^, &srv, renderer_srv_cpu(s.srv_start + u32(i)))
    }
    for mip in 0..<2 + SKY_PANORAMA_MIPS {
        rtv := d3d12.RENDER_TARGET_VIEW_DESC{Format = SKY_FORMAT, ViewDimension = .TEXTURE2D}
        resource := s.transmittance if mip == 0 else s.multiple_scattering if mip == 1 else s.panorama
        rtv.Texture2D = {MipSlice = u32(max(mip - 2, 0))}
        r.device->CreateRenderTargetView(resource, &rtv, descriptor_handle(s.rtv_heap, .RTV, u32(mip)))
    }

    mapped: rawptr
    s.constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * size_of(AtmosphereConstants)))
    s.constants = ([^]AtmosphereConstants)(mapped)
    s.readback = create_buffer(u64(FRAME_COUNT * SKY_READBACK_SLOT), .READBACK, {}, {.COPY_DEST})
}

renderer_release_sky :: proc() {
    s := &g_renderer.sky
    s.transmittance->Release()
    s.multiple_scattering->Release()
    s.panorama->Release()
    s.rtv_heap->Release()
    s.constant_buffer->Release()
    s.readback->Release()
}

// The panorama the background shows: the physical sky's, or the HDRI's.
renderer_background_srv :: proc() -> u32 {
    r := &g_renderer
    if r.environment_settings.source == .Physical_Sky do return r.sky.srv_start + SKY_PANORAMA
    return r.environment_srv_index
}

// The sun's angular radius in degrees: the ray-traced shadows' sun size, so
// the disc matches the softness of the shadows.
renderer_sun_angle :: proc() -> f32 {
    r := &g_renderer
    return r.ray_tracing.sun_angle if r.ray_tracing.supported else DEFAULT_SUN_ANGLE
}

// The background's sun disc for the physical sky: its radiance is the sun's
// irradiance at the ground spread over the disc's solid angle (capped below
// half floats' limit).
renderer_sky_sun_disc :: proc(sky: ^SkyConstants) {
    settings := g_renderer.environment_settings
    sky.sun_disc = 0
    if settings.source != .Physical_Sky do return
    toward := sky_sun_direction(settings.sky)
    angle := math.to_radians(renderer_sun_angle())
    cos_radius := math.cos(angle)
    solid_angle := 2 * math.PI * (1 - cos_radius)
    radiance := sky_sun_transmittance(settings.sky, toward) * settings.sky.sun_intensity / max(solid_angle, 1e-7)
    for &channel in radiance do channel = min(channel, 60000)
    sky.sun_disc = 1
    sky.sun_direction = toward
    sky.sun_cos_radius = cos_radius
    sky.sun_radiance = radiance
}

// Moves the time of day on, and owes the probes a capture of a sky that
// changed: every SKY_RECAPTURE_SECONDS while it keeps changing and once it
// settles (reflection probes), or only once it settles (baked volumes).
// Dynamic volumes follow the sky by themselves. Runs once per frame.
renderer_advance_sky :: proc(dt: f32) {
    r := &g_renderer
    s := &r.sky
    sky := &r.environment_settings.sky
    if r.environment_settings.source == .Physical_Sky && sky.time_speed != 0 {
        sky.time_of_day = math.mod(sky.time_of_day + sky.time_speed * dt + 24, 24)
    }
    if s.rebaked {
        s.rebaked = false
        s.still_time = 0
        s.probes_stale = true
        s.volumes_stale = true
    } else {
        s.still_time += dt
    }
    s.since_capture += dt
    if s.probes_stale && (s.still_time >= SKY_SETTLE_SECONDS || s.since_capture >= SKY_RECAPTURE_SECONDS) {
        renderer_recapture_probes(volumes = false)
        s.probes_stale = false
        s.since_capture = 0
    }
    if s.volumes_stale && s.still_time >= SKY_SETTLE_SECONDS {
        if !renderer_dynamic_volumes_active() do r.volumes.progress = {}
        s.volumes_stale = false
    }
}

// The physical sky's GPU work for this frame: reads back the irradiance this
// frame slot baked last time (the fog's sky light), and when the sky changed,
// redraws the tables (if the haze changed), the panorama, and the irradiance
// and prefiltered maps from it.
renderer_update_sky :: proc() {
    r := &g_renderer
    s := &r.sky
    renderer_begin_gpu_pass(.Sky)
    defer renderer_end_gpu_pass(.Sky)
    settings := r.environment_settings

    if s.readback_pending[r.frame_slot] {
        s.readback_pending[r.frame_slot] = false
        offset := uint(int(r.frame_slot) * SKY_READBACK_SLOT)
        read_range := d3d12.RANGE{Begin = offset, End = offset + SKY_READBACK_SLOT}
        mapped: rawptr
        if s.readback->Map(0, &read_range, &mapped) >= 0 {
            halves := ([^]f16)(uintptr(mapped) + uintptr(offset))[:IRRADIANCE_WIDTH * IRRADIANCE_HEIGHT * 4]
            pixels := make([]f32, len(halves), context.temp_allocator)
            for half, i in halves do pixels[i] = f32(half)
            // The mean over normals of the cosine-weighted mean radiance is
            // the mean radiance over the sphere.
            if settings.source == .Physical_Sky {
                r.environment_average_radiance = hdri_average_radiance(pixels, IRRADIANCE_WIDTH, IRRADIANCE_HEIGHT)
            }
            written := d3d12.RANGE{}
            s.readback->Unmap(0, &written)
        }
    }

    if settings.source != .Physical_Sky || !renderer_environment_uses_panorama(settings) do return
    if !s.dirty && settings.sky == s.baked do return
    s.dirty = false
    s.baked = settings.sky
    s.rebaked = true
    // The maps hold the sky now: an HDRI is baked again when it returns.
    r.environment_filtered_asset = 0
    if r.irradiance_texture == nil do renderer_create_irradiance_map()
    if r.prefilter_texture == nil do renderer_create_prefiltered_environment()

    s.constants[r.frame_slot] = AtmosphereConstants{
        sun_direction = sky_sun_direction(settings.sky),
        haze = settings.sky.haze,
        sun_irradiance = settings.sky.sun_intensity,
        viewer_height = SKY_VIEWER_HEIGHT,
        ground_albedo = SKY_GROUND_ALBEDO,
    }
    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    renderer_bind_cbv(.Prefilter_Constants, s.constant_buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * size_of(AtmosphereConstants))

    if s.table_haze != settings.sky.haze {
        s.table_haze = settings.sky.haze
        renderer_sky_draw(s.transmittance, SKY_TRANSMITTANCE, SKY_TRANSMITTANCE_WIDTH, SKY_TRANSMITTANCE_HEIGHT, s.transmittance_pipeline)
        renderer_bind_srv(.Texture_T0, s.srv_start + SKY_TRANSMITTANCE)
        renderer_sky_draw(s.multiple_scattering, SKY_MULTIPLE_SCATTERING, SKY_MULTIPLE_SCATTERING_SIZE, SKY_MULTIPLE_SCATTERING_SIZE, s.multiple_scattering_pipeline)
    }
    renderer_bind_srv(.Texture_T0, s.srv_start + SKY_TRANSMITTANCE)
    renderer_bind_srv(.Texture_T1, s.srv_start + SKY_MULTIPLE_SCATTERING)
    barrier := resource_transition(s.panorama, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET})
    r.command_list->ResourceBarrier(1, &barrier)
    r.command_list->SetPipelineState(s.panorama_pipeline)
    for mip in 0..<SKY_PANORAMA_MIPS {
        renderer_sky_target(SKY_PANORAMA + mip, u32(SKY_PANORAMA_WIDTH) >> u32(mip), u32(SKY_PANORAMA_HEIGHT) >> u32(mip))
        r.command_list->DrawInstanced(3, 1, 0, 0)
    }
    barrier = resource_transition(s.panorama, {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE})
    r.command_list->ResourceBarrier(1, &barrier)

    renderer_record_irradiance(s.srv_start + SKY_PANORAMA)
    renderer_record_prefiltered_environment(s.srv_start + SKY_PANORAMA, sky = true)

    // The irradiance map back to the CPU, for the fog.
    barrier = resource_transition(r.irradiance_texture, {.PIXEL_SHADER_RESOURCE}, {.COPY_SOURCE})
    r.command_list->ResourceBarrier(1, &barrier)
    destination := d3d12.TEXTURE_COPY_LOCATION{pResource = s.readback, Type = .PLACED_FOOTPRINT}
    destination.PlacedFootprint = {
        Offset = u64(int(r.frame_slot) * SKY_READBACK_SLOT),
        Footprint = {Format = .R16G16B16A16_FLOAT, Width = IRRADIANCE_WIDTH, Height = IRRADIANCE_HEIGHT, Depth = 1, RowPitch = IRRADIANCE_WIDTH * 8},
    }
    source := d3d12.TEXTURE_COPY_LOCATION{pResource = r.irradiance_texture, Type = .SUBRESOURCE_INDEX, SubresourceIndex = 0}
    r.command_list->CopyTextureRegion(&destination, 0, 0, 0, &source, nil)
    barrier = resource_transition(r.irradiance_texture, {.COPY_SOURCE}, {.PIXEL_SHADER_RESOURCE})
    r.command_list->ResourceBarrier(1, &barrier)
    s.readback_pending[r.frame_slot] = true
}

// One table: a full-screen draw into it.
@(private="file")
renderer_sky_draw :: proc(target: ^d3d12.IResource, rtv: int, width, height: u32, pso: ^d3d12.IPipelineState) {
    r := &g_renderer
    barrier := resource_transition(target, {.PIXEL_SHADER_RESOURCE}, {.RENDER_TARGET})
    r.command_list->ResourceBarrier(1, &barrier)
    r.command_list->SetPipelineState(pso)
    renderer_sky_target(rtv, width, height)
    r.command_list->DrawInstanced(3, 1, 0, 0)
    barrier = resource_transition(target, {.RENDER_TARGET}, {.PIXEL_SHADER_RESOURCE})
    r.command_list->ResourceBarrier(1, &barrier)
}

@(private="file")
renderer_sky_target :: proc(rtv: int, width, height: u32) {
    r := &g_renderer
    handle := descriptor_handle(r.sky.rtv_heap, .RTV, u32(rtv))
    r.command_list->OMSetRenderTargets(1, &handle, false, nil)
    viewport := d3d12.VIEWPORT{Width = f32(width), Height = f32(height), MaxDepth = 1}
    scissor := d3d12.RECT{right = i32(width), bottom = i32(height)}
    r.command_list->RSSetViewports(1, &viewport)
    r.command_list->RSSetScissorRects(1, &scissor)
}
