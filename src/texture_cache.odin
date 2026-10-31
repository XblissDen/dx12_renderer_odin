package main

// Material textures as the GPU stores them. Every mip level is built on the
// CPU (texture_build_mips) and block-compressed where the size allows: BC7 for
// color, BC5 for normal maps (x and y; the shader rebuilds z) and BC4 for
// single-channel maps, a quarter to an eighth of RGBA8's memory. Compressing
// takes a while, so file textures are prepared once and kept in
// cache/textures/ as DDS files, named by the texture's id and a hash of the
// source file and its settings; later runs only read them.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import dxgi "vendor:directx/dxgi"

TEXTURE_CACHE_DIRECTORY :: "cache/textures"
// Part of every cache key: bump it when the mips or the encoders change, so
// existing cache files are rebuilt.
TEXTURE_CACHE_VERSION :: 1

// A texture ready to upload: its format and every mip level, tightly packed
// (rows of texels, or rows of 4x4 blocks).
TextureData :: struct {
    format: dxgi.FORMAT,
    width, height: u32,
    // Slices of `data`; both from runtime.heap_allocator().
    levels: [][]u8,
    data: []u8,
    // Albedo only: what picking needs (TextureAlpha). Not freed with the rest.
    alpha: TextureAlpha,
    // Why the texture could not be prepared; empty on success.
    message: string,
}

texture_data_destroy :: proc(texture: ^TextureData) {
    delete(texture.levels, runtime.heap_allocator())
    delete(texture.data, runtime.heap_allocator())
    texture.levels, texture.data = nil, nil
}

// Everything the GPU needs for a texture asset: read from the cache when a
// file texture's entry is current, otherwise decoded, given its mips,
// compressed and (for files) cached. Safe to run on worker threads.
texture_prepare :: proc(desc: TextureDesc) -> (texture: TextureData) {
    cache_path: string
    if desc.source == .file {
        cache_path = texture_cache_path(desc)
        if cached, ok := texture_cache_read(cache_path, desc.usage); ok {
            cached.alpha = texture_data_alpha(desc.usage, cached)
            return cached
        }
    }
    pixels, width, height, message := assets_try_texture_pixels(desc, runtime.heap_allocator())
    if message != "" do return {message = message}
    defer delete(pixels, runtime.heap_allocator())

    texture = texture_encode(desc.usage, pixels, width, height)
    // From the stored data, so it matches what a cache hit would give.
    texture.alpha = texture_data_alpha(desc.usage, texture)
    if cache_path != "" do texture_cache_write(cache_path, desc.id, texture)
    return
}

// The format a texture is stored in: compressed by usage when both sides are
// multiples of 4 (D3D's rule for block-compressed textures), else RGBA8.
// Color is sRGB, so the sampler decodes it to linear before filtering.
texture_format :: proc(usage: TextureUsage, width, height: u32) -> dxgi.FORMAT {
    whole_blocks := width % 4 == 0 && height % 4 == 0
    switch usage {
    case .albedo, .emissive: return .BC7_UNORM_SRGB if whole_blocks else .R8G8B8A8_UNORM_SRGB
    case .normal: return .BC5_UNORM if whole_blocks else .R8G8B8A8_UNORM
    case .roughness, .metallic, .occlusion: return .BC4_UNORM if whole_blocks else .R8G8B8A8_UNORM
    case .data:
    }
    return .R8G8B8A8_UNORM
}

// Bytes per 4x4 block, or 0 for RGBA8.
texture_block_bytes :: proc(format: dxgi.FORMAT) -> int {
    #partial switch format {
    case .BC4_UNORM: return 8
    case .BC5_UNORM, .BC7_UNORM_SRGB: return 16
    }
    return 0
}

// One level's bytes per row and rows (rows of blocks when compressed).
texture_level_rows :: proc(format: dxgi.FORMAT, width, height: u32) -> (row_size, row_count: int) {
    if block := texture_block_bytes(format); block > 0 {
        return int((width + 3) / 4) * block, int((height + 3) / 4)
    }
    return int(width) * 4, int(height)
}

// Points `levels` at `count` levels in `data`, starting `offset` bytes in,
// and allocates `data` if none is given. False if a given `data` is not
// exactly that size.
texture_allocate_levels :: proc(texture: ^TextureData, count: int, offset := 0, data: []u8 = nil) -> bool {
    heap := runtime.heap_allocator()
    total := offset
    for level in 0..<count {
        row_size, rows := texture_level_rows(texture.format, max(1, texture.width >> u32(level)), max(1, texture.height >> u32(level)))
        total += row_size * rows
    }
    if data != nil && len(data) != total do return false
    texture.data = data if data != nil else make([]u8, total, heap)
    texture.levels = make([][]u8, count, heap)
    at := offset
    for level in 0..<count {
        row_size, rows := texture_level_rows(texture.format, max(1, texture.width >> u32(level)), max(1, texture.height >> u32(level)))
        texture.levels[level] = texture.data[at:][:row_size * rows]
        at += row_size * rows
    }
    return true
}

// The mip chain of an RGBA8 image, stored in its usage's format.
texture_encode :: proc(usage: TextureUsage, pixels: []u8, width, height: u32) -> (texture: TextureData) {
    heap := runtime.heap_allocator()
    texture.format = texture_format(usage, width, height)
    texture.width, texture.height = width, height
    mips := texture_build_mips(pixels, width, height, texture_mip_mode(usage))
    defer {
        for level in mips[1:] do delete(level, heap)
        delete(mips, heap)
    }
    texture_allocate_levels(&texture, len(mips))
    for level, i in mips {
        texture_encode_level(texture.format, level, max(1, width >> u32(i)), max(1, height >> u32(i)), texture.levels[i])
    }
    return
}

// One level: copied for RGBA8, else each 4x4 block compressed (blocks past a
// small level's edge repeat its last row and column).
texture_encode_level :: proc(format: dxgi.FORMAT, pixels: []u8, width, height: u32, out: []u8) {
    block_bytes := texture_block_bytes(format)
    if block_bytes == 0 {
        copy(out, pixels)
        return
    }
    blocks_x, blocks_y := (width + 3) / 4, (height + 3) / 4
    for by in 0..<blocks_y {
        for bx in 0..<blocks_x {
            texels: [16][4]u8
            for i in 0..<u32(16) {
                x := min(bx * 4 + i % 4, width - 1)
                y := min(by * 4 + i / 4, height - 1)
                offset := int(y * width + x) * 4
                texels[i] = {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
            }
            block := out[int(by * blocks_x + bx) * block_bytes:][:block_bytes]
            #partial switch format {
            case .BC7_UNORM_SRGB:
                encoded := bc7_encode_block(texels)
                copy(block, encoded[:])
            case .BC4_UNORM, .BC5_UNORM:
                for channel in 0..<block_bytes / 8 {
                    values: [16]u8
                    for texel, i in texels do values[i] = texel[channel]
                    encoded := bc4_encode_block(values)
                    copy(block[channel * 8:], encoded[:])
                }
            }
        }
    }
}

// BC4: two 8-bit endpoints and a 3-bit index per texel. With the larger
// endpoint first, the eight levels run evenly from one to the other.
bc4_encode_block :: proc(values: [16]u8) -> (block: [8]u8) {
    high, low := values[0], values[0]
    for value in values {
        high = max(high, value)
        low = min(low, value)
    }
    // Index 0 is `high`, 1 is `low`, and 2 to 7 lie between, from high down.
    palette: [8]i32
    palette[0], palette[1] = i32(high), i32(low)
    for i in 2..<8 do palette[i] = (i32(8 - i) * i32(high) + i32(i - 1) * i32(low) + 3) / 7
    bits: u64
    for value, texel in values {
        best, best_error := 0, max(i32)
        for level, i in palette {
            error := abs(level - i32(value))
            if error < best_error do best, best_error = i, error
        }
        bits |= u64(best) << u64(3 * texel)
    }
    block[0], block[1] = high, low
    for i in 0..<6 do block[2 + i] = u8(bits >> u64(8 * i))
    return
}

// BC7's interpolation weights for 4-bit indices, out of 64.
BC7_WEIGHTS := [16]i32{0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64}

// A BC7 mode 6 block being fitted: two RGBA endpoints of 7 bits per channel
// plus a shared low bit each (the "p-bit"), and a 4-bit index per texel.
Bc7_Fit :: struct {
    endpoints: [2][4]u8, // 7-bit values.
    p_bits: [2]u8,
    indices: [16]u8,
    error: f32,
}

// BC7 using only mode 6: one line segment through RGBA space per block, 16
// steps along it. That suits most material textures; the partitioned modes
// would do better on blocks with two distinct colors. The segment follows the
// block's principal axis, then is refitted twice by least squares to the
// indices chosen.
bc7_encode_block :: proc(texels: [16][4]u8) -> [16]u8 {
    opaque := true
    mean: [4]f32
    for texel in texels {
        for c in 0..<4 do mean[c] += f32(texel[c]) / 16
        opaque &&= texel[3] == 255
    }
    covariance: [4][4]f32
    for texel in texels {
        d: [4]f32
        for c in 0..<4 do d[c] = f32(texel[c]) - mean[c]
        for i in 0..<4 do for j in 0..<4 do covariance[i][j] += d[i] * d[j]
    }
    // The principal axis by power iteration, from the channel that varies most.
    axis: [4]f32
    widest := 0
    for c in 1..<4 do if covariance[c][c] > covariance[widest][widest] do widest = c
    axis[widest] = 1
    for _ in 0..<8 {
        next: [4]f32
        for i in 0..<4 do for j in 0..<4 do next[i] += covariance[i][j] * axis[j]
        length := math.sqrt(next[0] * next[0] + next[1] * next[1] + next[2] * next[2] + next[3] * next[3])
        if length < 0.0001 do break
        axis = next / length
    }
    low, high := max(f32), -max(f32)
    for texel in texels {
        t: f32
        for c in 0..<4 do t += (f32(texel[c]) - mean[c]) * axis[c]
        low, high = min(low, t), max(high, t)
    }
    if low > high do low, high = 0, 0
    ends := [2][4]f32{mean + axis * low, mean + axis * high}

    best := Bc7_Fit{error = max(f32)}
    for iteration in 0..<3 {
        fit := bc7_fit(texels, ends, opaque)
        if fit.error < best.error do best = fit
        if iteration == 2 || best.error == 0 do break
        // The endpoints that best fit these indices (least squares).
        a, b, c: f32
        x0, x1: [4]f32
        for texel, i in texels {
            w := f32(BC7_WEIGHTS[fit.indices[i]]) / 64
            a += (1 - w) * (1 - w)
            b += w * (1 - w)
            c += w * w
            for ch in 0..<4 {
                x0[ch] += (1 - w) * f32(texel[ch])
                x1[ch] += w * f32(texel[ch])
            }
        }
        determinant := a * c - b * b
        if abs(determinant) < 0.0001 do break
        for ch in 0..<4 {
            ends[0][ch] = (c * x0[ch] - b * x1[ch]) / determinant
            ends[1][ch] = (a * x1[ch] - b * x0[ch]) / determinant
        }
    }
    return bc7_pack_mode6(best)
}

// Quantizes two endpoints to mode 6 (opaque blocks keep the p-bit 1, so
// alpha decodes to exactly 255) and picks each texel's index.
bc7_fit :: proc(texels: [16][4]u8, ends: [2][4]f32, opaque: bool) -> (fit: Bc7_Fit) {
    colors: [2][4]i32
    for e in 0..<2 {
        best_error := max(f32)
        for p in (u8(1) if opaque else 0)..=1 {
            error: f32
            quantized: [4]u8
            decoded: [4]i32
            for c in 0..<4 {
                value := clamp(ends[e][c], 0, 255)
                q := u8(clamp(math.round((value - f32(p)) / 2), 0, 127))
                quantized[c] = q
                decoded[c] = i32(q) * 2 + i32(p)
                error += (f32(decoded[c]) - value) * (f32(decoded[c]) - value)
            }
            if error < best_error {
                best_error = error
                fit.endpoints[e], fit.p_bits[e], colors[e] = quantized, p, decoded
            }
        }
    }

    // The palette lies on the segment, so the nearest entry is near the
    // texel's projection onto it; check that one and its neighbours.
    direction: [4]f32
    for c in 0..<4 do direction[c] = f32(colors[1][c] - colors[0][c])
    length2 := direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2] + direction[3] * direction[3]
    for texel, i in texels {
        t: f32
        if length2 > 0 {
            for c in 0..<4 do t += (f32(texel[c]) - f32(colors[0][c])) * direction[c]
            t /= length2
        }
        guess := 0
        for w, index in BC7_WEIGHTS do if abs(f32(w) / 64 - t) < abs(f32(BC7_WEIGHTS[guess]) / 64 - t) do guess = index
        best, best_error := guess, max(f32)
        for index in max(guess - 1, 0)..=min(guess + 1, 15) {
            w := BC7_WEIGHTS[index]
            error: f32
            for c in 0..<4 {
                d := f32(((64 - w) * colors[0][c] + w * colors[1][c] + 32) >> 6) - f32(texel[c])
                error += d * d
            }
            if error < best_error do best, best_error = index, error
        }
        fit.indices[i] = u8(best)
        fit.error += best_error
    }
    return
}

// Mode 6's bit layout, from the lowest bit: the mode (bit 6 set), each
// channel's two 7-bit endpoints (R0 R1 G0 G1 B0 B1 A0 A1), the two p-bits,
// then the indices, the first with 3 bits since its top bit must be 0.
bc7_pack_mode6 :: proc(fit: Bc7_Fit) -> (block: [16]u8) {
    fit := fit
    if fit.indices[0] >= 8 {
        // Swapping the endpoints flips every index, clearing the first's top bit.
        fit.endpoints[0], fit.endpoints[1] = fit.endpoints[1], fit.endpoints[0]
        fit.p_bits[0], fit.p_bits[1] = fit.p_bits[1], fit.p_bits[0]
        for &index in fit.indices do index = 15 - index
    }
    bits := u128(1) << 6
    position := u128(7)
    put :: proc(bits, position: ^u128, value: u8, count: u128) {
        bits^ |= u128(value) << position^
        position^ += count
    }
    for c in 0..<4 {
        put(&bits, &position, fit.endpoints[0][c], 7)
        put(&bits, &position, fit.endpoints[1][c], 7)
    }
    put(&bits, &position, fit.p_bits[0], 1)
    put(&bits, &position, fit.p_bits[1], 1)
    for index, i in fit.indices do put(&bits, &position, index, 3 if i == 0 else 4)
    assert(position == 128)
    for i in 0..<16 do block[i] = u8(bits >> u128(8 * i))
    return
}

// The alpha of a mode 6 block, the only mode written here.
bc7_decode_alpha :: proc(block: []u8) -> (alpha: [16]u8) {
    bits: u128
    for i in 0..<16 do bits |= u128(block[i]) << u128(8 * i)
    if bits & 0x7f != 0x40 {
        for &a in alpha do a = 255
        return
    }
    a0 := i32((bits >> 49) & 0x7f) << 1 | i32((bits >> 63) & 1)
    a1 := i32((bits >> 56) & 0x7f) << 1 | i32((bits >> 64) & 1)
    position := u128(65)
    for i in 0..<16 {
        count := u128(3 if i == 0 else 4)
        w := BC7_WEIGHTS[int((bits >> position) & ((1 << count) - 1))]
        position += count
        alpha[i] = u8(((64 - w) * a0 + w * a1 + 32) >> 6)
    }
    return
}

// Albedo textures with any transparency: level 0's alpha, for picking.
texture_data_alpha :: proc(usage: TextureUsage, texture: TextureData) -> TextureAlpha {
    if usage != .albedo || len(texture.levels) == 0 do return {}
    width, height := texture.width, texture.height
    values := make([]u8, int(width) * int(height), runtime.heap_allocator())
    level := texture.levels[0]
    if texture.format == .BC7_UNORM_SRGB {
        blocks_x := (width + 3) / 4
        for by in 0..<(height + 3) / 4 {
            for bx in 0..<blocks_x {
                decoded := bc7_decode_alpha(level[int(by * blocks_x + bx) * 16:][:16])
                for i in 0..<u32(16) {
                    x, y := bx * 4 + i % 4, by * 4 + i / 4
                    if x < width && y < height do values[y * width + x] = decoded[i]
                }
            }
        }
    } else {
        for &value, i in values do value = level[i * 4 + 3]
    }
    for value in values do if value != 255 do return {values, width, height}
    delete(values, runtime.heap_allocator())
    return {}
}

// Cache file names: the texture's id, kept to safe characters, then '@' and
// the key's hash.
texture_cache_name :: proc(id: string) -> string {
    name := make([]u8, len(id), context.temp_allocator)
    for c, i in transmute([]u8)id {
        safe := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
        name[i] = c if safe else '_'
    }
    return string(name)
}

// Where a file texture's cache entry is: the hash covers the source file's
// path, size and write time, the texture's settings and the cache version,
// so changing any of them makes a new entry. "" if the source is missing.
texture_cache_path :: proc(desc: TextureDesc) -> string {
    info, error := os.stat(desc.path, context.temp_allocator)
    if error != nil do return ""
    key := fmt.tprintf(
        "%d|%s|%d|%d|%v|%v|%v", TEXTURE_CACHE_VERSION, desc.path, info.size,
        time.to_unix_nanoseconds(info.modification_time), desc.usage, desc.settings.channel, desc.settings.flip_green,
    )
    return fmt.tprintf("%s/%s@%016x.dds", TEXTURE_CACHE_DIRECTORY, texture_cache_name(desc.id), hash.fnv64a(transmute([]u8)key))
}

// The DDS file header with its DX10 extension, which names the DXGI format.
Dds_Header :: struct #packed {
    magic: u32le,
    size, flags, height, width, pitch_or_linear_size, depth, mip_map_count: u32le,
    reserved1: [11]u32le,
    pixel_format: struct #packed {
        size, flags, four_cc, rgb_bit_count, r_mask, g_mask, b_mask, a_mask: u32le,
    },
    caps, caps2, caps3, caps4, reserved2: u32le,
    dxgi_format, resource_dimension, misc_flag, array_size, misc_flags2: u32le,
}
#assert(size_of(Dds_Header) == 148)
DDS_MAGIC :: 0x20534444 // "DDS "
DDS_FOURCC_DX10 :: 0x30315844 // "DX10"

// A cache entry, if it exists and holds what `usage` and its size call for.
texture_cache_read :: proc(path: string, usage: TextureUsage) -> (texture: TextureData, ok: bool) {
    if path == "" do return
    data, error := os.read_entire_file(path, runtime.heap_allocator())
    if error != nil do return
    defer if !ok do delete(data, runtime.heap_allocator())
    if len(data) < size_of(Dds_Header) do return
    header := (^Dds_Header)(raw_data(data))^
    texture.width, texture.height = u32(header.width), u32(header.height)
    texture.format = dxgi.FORMAT(header.dxgi_format)
    if header.magic != DDS_MAGIC || header.pixel_format.four_cc != DDS_FOURCC_DX10 || header.array_size != 1 ||
       texture.width == 0 || texture.height == 0 || texture.width > 32768 || texture.height > 32768 ||
       texture.format != texture_format(usage, texture.width, texture.height) ||
       u32(header.mip_map_count) != texture_mip_count(texture.width, texture.height) {
        return
    }
    if !texture_allocate_levels(&texture, int(header.mip_map_count), size_of(Dds_Header), data) do return {}, false
    return texture, true
}

// Writes a cache entry and removes the texture's older ones. A failure only
// means the next run prepares the texture again.
texture_cache_write :: proc(path, id: string, texture: TextureData) {
    _ = os.make_directory_all(TEXTURE_CACHE_DIRECTORY)
    compressed := texture_block_bytes(texture.format) > 0
    header := Dds_Header{
        magic = DDS_MAGIC,
        size = 124,
        // Caps, height, width, pixel format, mip count, then linear size or pitch.
        flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | (0x80000 if compressed else 0x8),
        height = u32le(texture.height),
        width = u32le(texture.width),
        mip_map_count = u32le(len(texture.levels)),
        pixel_format = {size = 32, flags = 0x4, four_cc = DDS_FOURCC_DX10},
        // Texture, mipmap, complex.
        caps = 0x1000 | 0x400000 | 0x8,
        dxgi_format = u32le(texture.format),
        resource_dimension = 3, // Texture2D.
        array_size = 1,
    }
    row_size, rows := texture_level_rows(texture.format, texture.width, texture.height)
    header.pitch_or_linear_size = u32le(row_size * rows if compressed else row_size)

    file, error := os.open(path, {.Write, .Create, .Trunc})
    if error != nil do return
    header_bytes := header
    _, header_error := os.write(file, ([^]u8)(&header_bytes)[:size_of(Dds_Header)])
    data_start := uintptr(raw_data(texture.levels[0]))
    data_end := uintptr(raw_data(texture.levels[len(texture.levels) - 1])) + uintptr(len(texture.levels[len(texture.levels) - 1]))
    _, data_error := os.write(file, ([^]u8)(rawptr(data_start))[:data_end - data_start])
    close_error := os.close(file)
    if header_error != nil || data_error != nil || close_error != nil {
        os.remove(path)
        return
    }
    texture_cache_forget(id, keep = path)
}

// Removes a texture's cache entries, except `keep`.
texture_cache_forget :: proc(id: string, keep := "") {
    entries, error := os.read_all_directory_by_path(TEXTURE_CACHE_DIRECTORY, context.temp_allocator)
    if error != nil do return
    prefix := fmt.tprintf("%s@", texture_cache_name(id))
    keep_name := keep[strings.last_index_byte(keep, '/') + 1:] if keep != "" else ""
    for entry in entries {
        if strings.has_prefix(entry.name, prefix) && strings.has_suffix(entry.name, ".dds") && entry.name != keep_name {
            os.remove(entry.fullpath)
        }
    }
}
