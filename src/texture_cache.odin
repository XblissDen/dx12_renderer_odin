package main

// Material textures as the GPU stores them. Every mip level is built on the
// CPU (texture_build_mips) and block-compressed where the size allows: BC7 for
// color, BC5 for normal maps (x and y; the shader rebuilds z) and BC4 for
// single-channel maps, a quarter to an eighth of RGBA8's memory. Compressing
// takes a while, so file textures are prepared once and kept in
// cache/textures/ as DDS files, named by the texture's id and a hash of the
// source file and its settings; later runs only read them.
//
// HDR panoramas are stored the same way for the sky, as BC6H (half floats,
// a sixteenth of RGBA32F), and cached in cache/environments/.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import dxgi "vendor:directx/dxgi"

TEXTURE_CACHE_DIRECTORY :: "cache/textures"
ENVIRONMENT_CACHE_DIRECTORY :: "cache/environments"
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
        settings := fmt.tprintf("%v|%v|%v", desc.usage, desc.settings.channel, desc.settings.flip_green)
        cache_path = texture_cache_path(TEXTURE_CACHE_DIRECTORY, desc.id, desc.path, settings)
        if cached, ok := texture_cache_read(cache_path); ok {
            if cached.format == texture_format(desc.usage, cached.width, cached.height) {
                cached.alpha = texture_data_alpha(desc.usage, cached)
                return cached
            }
            texture_data_destroy(&cached)
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

// Bytes per 4x4 block, or 0 for uncompressed formats.
texture_block_bytes :: proc(format: dxgi.FORMAT) -> int {
    #partial switch format {
    case .BC4_UNORM: return 8
    case .BC5_UNORM, .BC6H_UF16, .BC7_UNORM_SRGB: return 16
    }
    return 0
}

// One level's bytes per row and rows (rows of blocks when compressed).
texture_level_rows :: proc(format: dxgi.FORMAT, width, height: u32) -> (row_size, row_count: int) {
    if block := texture_block_bytes(format); block > 0 {
        return int((width + 3) / 4) * block, int((height + 3) / 4)
    }
    return int(width) * (16 if format == .R32G32B32A32_FLOAT else 4), int(height)
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

// A line segment through a block's 16 values: along their principal axis (by
// power iteration, from the channel that varies most), spanning their
// projections onto it.
block_principal_segment :: proc(points: [16][4]f32) -> (ends: [2][4]f32) {
    mean: [4]f32
    for point in points do mean += point / 16
    covariance: [4][4]f32
    for point in points {
        d := point - mean
        for i in 0..<4 do for j in 0..<4 do covariance[i][j] += d[i] * d[j]
    }
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
    for point in points {
        d := point - mean
        t := d[0] * axis[0] + d[1] * axis[1] + d[2] * axis[2] + d[3] * axis[3]
        low, high = min(low, t), max(high, t)
    }
    return {mean + axis * low, mean + axis * high}
}

// The endpoints that best fit the values for the chosen 4-bit indices (least
// squares); false when the indices cannot tell the endpoints apart.
block_refit_segment :: proc(points: [16][4]f32, indices: [16]u8) -> (ends: [2][4]f32, ok: bool) {
    a, b, c: f32
    x0, x1: [4]f32
    for point, i in points {
        w := f32(BC7_WEIGHTS[indices[i]]) / 64
        a += (1 - w) * (1 - w)
        b += w * (1 - w)
        c += w * w
        x0 += (1 - w) * point
        x1 += w * point
    }
    determinant := a * c - b * b
    if abs(determinant) < 0.0001 do return
    return {(c * x0 - b * x1) / determinant, (a * x1 - b * x0) / determinant}, true
}

// BC7 using only mode 6: one line segment through RGBA space per block, 16
// steps along it. That suits most material textures; the partitioned modes
// would do better on blocks with two distinct colors. The segment follows the
// block's principal axis, then is refitted twice by least squares to the
// indices chosen.
bc7_encode_block :: proc(texels: [16][4]u8) -> [16]u8 {
    opaque := true
    points: [16][4]f32
    for texel, i in texels {
        for c in 0..<4 do points[i][c] = f32(texel[c])
        opaque &&= texel[3] == 255
    }
    ends := block_principal_segment(points)
    best := Bc7_Fit{error = max(f32)}
    for iteration in 0..<3 {
        fit := bc7_fit(texels, ends, opaque)
        if fit.error < best.error do best = fit
        if iteration == 2 || best.error == 0 do break
        ok: bool
        if ends, ok = block_refit_segment(points, fit.indices); !ok do break
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

// The format the sky stores a panorama in: BC6H when both sides are
// multiples of 4, else full floats.
environment_format :: proc(width, height: u32) -> dxgi.FORMAT {
    return .BC6H_UF16 if width % 4 == 0 && height % 4 == 0 else .R32G32B32A32_FLOAT
}

// The sky's copy of a panorama (RGBA floats): read from the cache when its
// entry is current, otherwise built and, when compressed, cached.
environment_prepare :: proc(desc: EnvironmentDesc, pixels: []f32, width, height: u32) -> (texture: TextureData) {
    format := environment_format(width, height)
    if format != .BC6H_UF16 do return environment_encode(pixels, width, height, format)
    cache_path := texture_cache_path(ENVIRONMENT_CACHE_DIRECTORY, desc.id, desc.path, "sky")
    if cached, ok := texture_cache_read(cache_path); ok {
        if cached.format == format && cached.width == width && cached.height == height do return cached
        texture_data_destroy(&cached)
    }
    texture = environment_encode(pixels, width, height, format)
    if cache_path != "" do texture_cache_write(cache_path, desc.id, texture)
    return
}

// A panorama's mip chain (texture_next_environment_mip) in `format`: BC6H or
// RGBA32F.
environment_encode :: proc(pixels: []f32, width, height: u32, format: dxgi.FORMAT) -> (texture: TextureData) {
    heap := runtime.heap_allocator()
    texture.format, texture.width, texture.height = format, width, height
    texture_allocate_levels(&texture, int(texture_mip_count(width, height)))
    level, level_width, level_height := pixels, width, height
    for i in 0..<len(texture.levels) {
        if format == .BC6H_UF16 {
            bc6h_encode_level(level, level_width, level_height, texture.levels[i])
        } else {
            copy(texture.levels[i], slice.to_bytes(level))
        }
        if i + 1 == len(texture.levels) do break
        next, next_width, next_height := texture_next_environment_mip(level, level_width, level_height, heap)
        if i > 0 do delete(level, heap)
        level, level_width, level_height = next, next_width, next_height
    }
    if len(texture.levels) > 1 do delete(level, heap)
    return
}

// One BC6H level, its rows of blocks shared out to a thread per core (a 4K
// panorama has over half a million blocks).
bc6h_encode_level :: proc(pixels: []f32, width, height: u32, out: []u8) {
    Job :: struct {
        pixels: []f32,
        width, height: u32,
        out: []u8,
        next_row: int,
    }
    encode_rows :: proc(job: ^Job) {
        blocks_x, blocks_y := (job.width + 3) / 4, (job.height + 3) / 4
        for {
            by := u32(sync.atomic_add(&job.next_row, 1))
            if by >= blocks_y do break
            for bx in 0..<blocks_x {
                texels: [16][3]f32
                for i in 0..<u32(16) {
                    x := min(bx * 4 + i % 4, job.width - 1)
                    y := min(by * 4 + i / 4, job.height - 1)
                    offset := int(y * job.width + x) * 4
                    texels[i] = {job.pixels[offset], job.pixels[offset + 1], job.pixels[offset + 2]}
                }
                encoded := bc6h_encode_block(texels)
                copy(job.out[int(by * blocks_x + bx) * 16:][:16], encoded[:])
            }
        }
    }
    job := Job{pixels = pixels, width = width, height = height, out = out}
    // Small levels are not worth starting threads for.
    helpers := clamp(os.get_processor_core_count(), 1, 16) - 1 if height >= 256 else 0
    threads := make([]^thread.Thread, helpers, context.temp_allocator)
    for &t in threads do t = thread.create_and_start_with_poly_data(&job, encode_rows)
    encode_rows(&job)
    thread.join_multiple(..threads)
    for t in threads do thread.destroy(t)
}

// BC6H's single-region modes (11 to 14 in D3D's numbering): the mode's bits,
// the endpoint precision, and how many bits store the second endpoint as a
// signed difference from the first (0: stored whole, at 10 bits). More
// precision with a smaller difference suits smooth blocks, such as most of a
// sky.
Bc6h_Mode :: struct {bits, precision, delta: u32}
BC6H_MODES := [4]Bc6h_Mode{{0x03, 10, 0}, {0x07, 11, 9}, {0x0b, 12, 8}, {0x0f, 16, 4}}

// A BC6H block being fitted: quantized RGB endpoints (the mode's precision)
// and a 4-bit index per texel.
Bc6h_Fit :: struct {
    mode: int,
    endpoints: [2][3]i32,
    indices: [16]u8,
    error: f32,
}

// A radiance value as BC6H's unsigned half floats see it: the half's bits,
// clamped to the largest finite half. Interpolating these bits is roughly
// interpolating the logarithm, so errors measured on them are relative.
bc6h_half_bits :: proc(value: f32) -> f32 {
    if !(value > 0) do return 0
    return f32(transmute(u16)f16(min(value, 65504)))
}

// An endpoint from `precision` bits to 16, as the decoder expands it.
bc6h_unquantize :: proc(value: i32, precision: u32) -> i32 {
    if precision >= 15 || value == 0 do return value
    if value == (i32(1) << precision) - 1 do return 0xFFFF
    return ((value << 16) + 0x8000) >> precision
}

// The `precision`-bit endpoint whose expansion is nearest `target` (0 to 65535).
bc6h_quantize :: proc(target: f32, precision: u32) -> i32 {
    top := (i32(1) << precision) - 1
    guess := clamp(i32(target * f32(top + 1) / 65536), 0, top)
    best := guess
    for value in max(guess - 1, 0)..=min(guess + 1, top) {
        if abs(f32(bc6h_unquantize(value, precision)) - target) < abs(f32(bc6h_unquantize(best, precision)) - target) do best = value
    }
    return best
}

// The half-float bits a texel decodes to: expanded endpoints interpolated,
// then scaled by 31/64 into the finite half range.
bc6h_interpolate :: proc(a, b, w: i32) -> f32 {
    return f32(((((64 - w) * a + w * b + 32) >> 6) * 31) >> 6)
}

// Like bc7_encode_block, in half-float bits: a segment along the principal
// axis, refitted twice by least squares, with each round trying every
// single-region mode. The two-region modes, which would suit blocks with two
// distinct colors, are not used.
bc6h_encode_block :: proc(pixels: [16][3]f32) -> [16]u8 {
    points: [16][4]f32
    for pixel, i in pixels do for c in 0..<3 do points[i][c] = bc6h_half_bits(pixel[c])
    ends := block_principal_segment(points)
    best := Bc6h_Fit{error = max(f32)}
    for iteration in 0..<3 {
        round := Bc6h_Fit{error = max(f32)}
        for mode in 0..<len(BC6H_MODES) {
            fit := bc6h_fit(points, ends, mode)
            if fit.error < round.error do round = fit
        }
        if round.error < best.error do best = round
        if iteration == 2 || best.error == 0 do break
        ok: bool
        if ends, ok = block_refit_segment(points, round.indices); !ok do break
    }
    return bc6h_pack(best)
}

// Quantizes two endpoints (in half-float bits) for one mode and picks each
// texel's index. The error is max(f32) when the mode cannot hold the block.
bc6h_fit :: proc(points: [16][4]f32, ends: [2][4]f32, mode: int) -> (fit: Bc6h_Fit) {
    m := BC6H_MODES[mode]
    fit.mode = mode
    limit := i32(1) << m.delta >> 1
    colors: [2][3]i32
    for c in 0..<3 {
        // From half bits back to the 16-bit range the endpoints expand to.
        a := bc6h_quantize(clamp(ends[0][c] * 64 / 31, 0, 65535), m.precision)
        b := bc6h_quantize(clamp(ends[1][c] * 64 / 31, 0, 65535), m.precision)
        if m.delta > 0 do b = a + clamp(b - a, -limit, limit - 1)
        fit.endpoints[0][c], fit.endpoints[1][c] = a, b
        colors[0][c], colors[1][c] = bc6h_unquantize(a, m.precision), bc6h_unquantize(b, m.precision)
    }

    // As in bc7_fit: the nearest palette entry is near the projection.
    low, high: [3]f32
    direction: [3]f32
    for c in 0..<3 {
        low[c], high[c] = bc6h_interpolate(colors[0][c], colors[1][c], 0), bc6h_interpolate(colors[0][c], colors[1][c], 64)
        direction[c] = high[c] - low[c]
    }
    length2 := direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]
    for point, i in points {
        t: f32
        if length2 > 0 {
            for c in 0..<3 do t += (point[c] - low[c]) * direction[c]
            t /= length2
        }
        guess := 0
        for w, index in BC7_WEIGHTS do if abs(f32(w) / 64 - t) < abs(f32(BC7_WEIGHTS[guess]) / 64 - t) do guess = index
        best, best_error := guess, max(f32)
        for index in max(guess - 1, 0)..=min(guess + 1, 15) {
            error: f32
            for c in 0..<3 {
                d := bc6h_interpolate(colors[0][c], colors[1][c], BC7_WEIGHTS[index]) - point[c]
                error += d * d
            }
            if error < best_error do best, best_error = index, error
        }
        fit.indices[i] = u8(best)
        fit.error += best_error
    }

    // The first index's top bit must be 0: swapping the endpoints flips every
    // index, and a difference must then fit the other way round.
    if fit.indices[0] >= 8 {
        fit.endpoints[0], fit.endpoints[1] = fit.endpoints[1], fit.endpoints[0]
        for &index in fit.indices do index = 15 - index
        for c in 0..<3 {
            if m.delta > 0 && fit.endpoints[1][c] - fit.endpoints[0][c] >= limit do fit.error = max(f32)
        }
    }
    return
}

// The single-region layouts, from the lowest bit: the mode, the first
// endpoint's low 10 bits (R, G, B), then for each channel either the second
// endpoint (10 bits), or its difference followed by the first endpoint's
// remaining bits from the highest down; then the indices, the first with 3
// bits since its top bit is 0.
bc6h_pack :: proc(fit: Bc6h_Fit) -> (block: [16]u8) {
    m := BC6H_MODES[fit.mode]
    bits, position: u128
    put :: proc(bits, position: ^u128, value: u32, count: u32) {
        bits^ |= u128(value & ((u32(1) << count) - 1)) << position^
        position^ += u128(count)
    }
    put(&bits, &position, m.bits, 5)
    for c in 0..<3 do put(&bits, &position, u32(fit.endpoints[0][c]), 10)
    for c in 0..<3 {
        if m.delta == 0 {
            put(&bits, &position, u32(fit.endpoints[1][c]), 10)
            continue
        }
        put(&bits, &position, u32(fit.endpoints[1][c] - fit.endpoints[0][c]), m.delta)
        for bit := m.precision - 1; bit >= 10; bit -= 1 do put(&bits, &position, u32(fit.endpoints[0][c]) >> bit, 1)
    }
    for index, i in fit.indices do put(&bits, &position, u32(index), 3 if i == 0 else 4)
    assert(position == 128)
    for i in 0..<16 do block[i] = u8(bits >> u128(8 * i))
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

// Where an asset's cache entry is, in `directory`: the hash covers the source
// file's path, size and write time, the asset's settings and the cache
// version, so changing any of them makes a new entry. "" if the source is
// missing.
texture_cache_path :: proc(directory, id, source, settings: string) -> string {
    info, error := os.stat(source, context.temp_allocator)
    if error != nil do return ""
    key := fmt.tprintf(
        "%d|%s|%d|%d|%s", TEXTURE_CACHE_VERSION, source, info.size,
        time.to_unix_nanoseconds(info.modification_time), settings,
    )
    return fmt.tprintf("%s/%s@%016x.dds", directory, texture_cache_name(id), hash.fnv64a(transmute([]u8)key))
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

// A cache entry, if it exists and holds a full mip chain. Callers check that
// its format is the one they want.
texture_cache_read :: proc(path: string) -> (texture: TextureData, ok: bool) {
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
       u32(header.mip_map_count) != texture_mip_count(texture.width, texture.height) {
        return
    }
    if !texture_allocate_levels(&texture, int(header.mip_map_count), size_of(Dds_Header), data) do return {}, false
    return texture, true
}

// Writes a cache entry and removes the asset's older ones in that directory.
// A failure only means the next run prepares the texture again.
texture_cache_write :: proc(path, id: string, texture: TextureData) {
    directory := path[:strings.last_index_byte(path, '/')]
    _ = os.make_directory_all(directory)
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
    texture_cache_forget(id, keep = path, directory = directory)
}

// Removes an asset's cache entries, except `keep`.
texture_cache_forget :: proc(id: string, keep := "", directory := TEXTURE_CACHE_DIRECTORY) {
    entries, error := os.read_all_directory_by_path(directory, context.temp_allocator)
    if error != nil do return
    prefix := fmt.tprintf("%s@", texture_cache_name(id))
    keep_name := keep[strings.last_index_byte(keep, '/') + 1:] if keep != "" else ""
    for entry in entries {
        if strings.has_prefix(entry.name, prefix) && strings.has_suffix(entry.name, ".dds") && entry.name != keep_name {
            os.remove(entry.fullpath)
        }
    }
}
