package main

import c "core:c"
import "base:runtime"
import "core:math"
import "core:os"
import "core:strings"
import d3d12 "vendor:directx/d3d12"
import stbi "vendor:stb/image"

AmbientLightingMode :: enum u32 {HDRI, Color}
BackgroundMode :: enum u32 {HDRI, Solid}

EnvironmentSettings :: struct {
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
    manual_sun: bool,
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
    if settings.ambient_mode != .HDRI || settings.manual_sun || !sun.found ||
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
    }
    if !assets_environment_valid(settings.asset) || !os.exists(g_assets.environments[settings.asset].desc.path) {
        settings.ambient_mode = .Color
        settings.background_mode = .Solid
    }
    return
}

renderer_environment_needs_hdri :: proc(settings: EnvironmentSettings) -> bool {
    return settings.ambient_mode == .HDRI || settings.background_mode == .HDRI
}

renderer_environment_settings_valid :: proc(settings: EnvironmentSettings) -> bool {
    if settings.ambient_mode != .HDRI && settings.ambient_mode != .Color do return false
    if settings.background_mode != .HDRI && settings.background_mode != .Solid do return false
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
    bake := settings.ambient_mode == .HDRI &&
            (load_sky ||
             r.environment_filtered_asset != settings.asset ||
             r.environment_filtered_without_sun != remove_sun)

    if load_sky || bake {
        // Earlier frames may still reference the old textures, descriptors,
        // and the upload allocator.
        renderer_wait_for_gpu()
        path := g_assets.environments[settings.asset].desc.path
        if error := renderer_load_environment(path, load_sky, bake, remove_sun); error != "" do return error
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
// and rebuilds the IBL maps when `bake`. With `remove_sun`, the maps are baked
// from a temporary copy without the sun, which then lights the scene as the
// shadowed directional light instead. The sky always shows the original.
renderer_load_environment :: proc(path: string, load_sky, bake, remove_sun: bool) -> string {
    r := &g_renderer

    width, height, channels: c.int
    decoded := stbi.loadf(
        strings.clone_to_cstring(path, context.temp_allocator) or_else panic("Environment path allocation failed"),
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
        texture, error := renderer_upload_environment(pixels, u32(width), u32(height), r.environment_srv_index)
        if error != "" do return error
        if r.environment_texture != nil do r.environment_texture->Release()
        r.environment_texture = texture
    }
    if !bake {
        return ""
    }

    // Baking needs HDRI lighting, so the sky texture already holds this
    // panorama (just uploaded, or cached for the same asset).
    source_srv_index := r.environment_srv_index
    bake_source: ^d3d12.IResource
    defer if bake_source != nil do bake_source->Release()

    if remove_sun && r.environment_sun.found {
        hdri_extract_sun(pixels, int(width), int(height), true)
        error: string
        bake_source, error = renderer_upload_environment(pixels, u32(width), u32(height), r.environment_bake_srv_index)
        if error != "" do return error
        source_srv_index = r.environment_bake_srv_index
    }

    r.environment_average_radiance = hdri_average_radiance(pixels, int(width), int(height))

    if r.irradiance_texture == nil do renderer_create_irradiance_map()
    if r.prefilter_texture == nil do renderer_create_prefiltered_environment()
    renderer_generate_irradiance(source_srv_index)
    renderer_generate_prefiltered_environment(source_srv_index)
    // Both passes wait for the GPU, so the temporary source can be released.
    return ""
}

// Uploads a panorama with its mip chain and writes its SRV at `srv_index`.
renderer_upload_environment :: proc(
    pixels: []f32,
    width, height: u32,
    srv_index: u32,
) -> (texture: ^d3d12.IResource, message: string) {
    r := &g_renderer

    mips := make([dynamic][]f32)
    append(&mips, pixels)
    defer {
        for mip in mips[1:] do delete(mip)
        delete(mips)
    }
    mip_width, mip_height := width, height
    for mip_width > 1 || mip_height > 1 {
        next, next_width, next_height := texture_next_environment_mip(
            mips[len(mips) - 1], mip_width, mip_height,
        )
        append(&mips, next)
        mip_width, mip_height = next_width, next_height
    }

    renderer_wait_for_gpu()
    candidate: ^d3d12.IResource
    defer if message != "" && candidate != nil do candidate->Release()

    texture_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(width),
        Height = u32(height),
        DepthOrArraySize = 1,
        MipLevels = u16(len(mips)),
        // Keep the sun's full radiance while filtering, including values above
        // half-float range. The convolved lighting maps remain RGBA16F.
        Format = .R32G32B32A32_FLOAT,
        SampleDesc = {Count = 1},
    }
    default_heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}

    hr := r.device->CreateCommittedResource(
        &default_heap,
        {},
        &texture_desc,
        {.COPY_DEST},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&candidate),
    )
    if hr < 0 do return nil, "Could not allocate the environment texture."

    layouts := make([]d3d12.PLACED_SUBRESOURCE_FOOTPRINT, len(mips))
    row_counts := make([]u32, len(mips))
    row_sizes := make([]u64, len(mips))
    defer delete(layouts)
    defer delete(row_counts)
    defer delete(row_sizes)
    upload_size: u64
    r.device->GetCopyableFootprints(
        &texture_desc, 0, u32(len(mips)), 0,
        raw_data(layouts), raw_data(row_counts), raw_data(row_sizes), &upload_size,
    )

    upload_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = upload_size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }
    upload_heap := d3d12.HEAP_PROPERTIES{Type = .UPLOAD}

    upload_buffer: ^d3d12.IResource
    hr = r.device->CreateCommittedResource(
        &upload_heap,
        {},
        &upload_desc,
        d3d12.RESOURCE_STATE_GENERIC_READ,
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&upload_buffer),
    )
    if hr < 0 do return nil, "Could not allocate the environment upload buffer."
    defer upload_buffer->Release()

    mapped: rawptr
    hr = upload_buffer->Map(0, nil, &mapped)
    if hr < 0 do return nil, "Could not map the environment upload buffer."

    for mip in 0..<len(mips) {
        layout := layouts[mip]
        for y in 0..<int(row_counts[mip]) {
            destination := uintptr(mapped) + uintptr(layout.Offset) +
                uintptr(u64(y) * u64(layout.Footprint.RowPitch))
            source := uintptr(raw_data(mips[mip])) + uintptr(u64(y) * row_sizes[mip])
            runtime.mem_copy(rawptr(destination), rawptr(source), int(row_sizes[mip]))
        }
    }
    upload_buffer->Unmap(0, nil)

    hr = r.command_allocators[0]->Reset()
    if hr < 0 do return nil, "Could not reset the environment upload allocator."
    hr = r.command_list->Reset(r.command_allocators[0], nil)
    if hr < 0 do return nil, "Could not reset the environment upload command list."

    for mip in 0..<len(mips) {
        source := d3d12.TEXTURE_COPY_LOCATION{
            pResource = upload_buffer,
            Type = .PLACED_FOOTPRINT,
            PlacedFootprint = layouts[mip],
        }
        destination := d3d12.TEXTURE_COPY_LOCATION{
            pResource = candidate,
            Type = .SUBRESOURCE_INDEX,
            SubresourceIndex = u32(mip),
        }
        r.command_list->CopyTextureRegion(&destination, 0, 0, 0, &source, nil)
    }

    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = candidate,
        StateBefore = {.COPY_DEST},
        StateAfter = {.PIXEL_SHADER_RESOURCE},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    hr = r.command_list->Close()
    if hr < 0 do return nil, "Could not close the environment upload command list."
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
        Format = .R32G32B32A32_FLOAT,
        ViewDimension = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = {MipLevels = u32(len(mips))}
    r.device->CreateShaderResourceView(candidate, &srv_desc, renderer_srv_cpu(srv_index))
    return candidate, ""
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

renderer_generate_irradiance :: proc(source_srv_index: u32) {
    r := &g_renderer

    // The environment upload has completed before this procedure runs.
    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))

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

    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()
}

// The prefiltered specular map: each mip holds the panorama blurred for one
// roughness, from 0 at mip 0 to 1 at the last, with a constant slot per mip.
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
    r.prefilter_constant_buffer, mapped = renderer_create_mapped_upload_buffer(u64(size_of(PrefilterConstants) * PREFILTER_MIP_COUNT))
    r.prefilter_cb_mapped_data = ([^]PrefilterConstants)(mapped)

    for mip in 0..<PREFILTER_MIP_COUNT {
        r.prefilter_cb_mapped_data[mip].roughness =
            f32(mip) / f32(PREFILTER_MIP_COUNT - 1)
    }
}

// Renders every mip of the prefiltered map from the panorama at
// `source_srv_index`, and waits for the GPU.
renderer_generate_prefiltered_environment :: proc(source_srv_index: u32) {
    r := &g_renderer

    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))

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

        cb_offset := u64(mip) * u64(size_of(PrefilterConstants))
        renderer_bind_cbv(
            .Prefilter_Constants,
            r.prefilter_constant_buffer->GetGPUVirtualAddress() + cb_offset,
        )

        r.command_list->DrawInstanced(3, 1, 0, 0)
    }

    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)

    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
    renderer_wait_for_gpu()
}
