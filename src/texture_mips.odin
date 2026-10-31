package main

import "base:runtime"
import "core:math"

// The next mip level of an HDR panorama (RGBA floats), built on the CPU at
// half the size. Panoramas are linear radiance, so latitude rows are weighted
// by their solid angle: each level keeps the sphere's energy, including for
// odd sizes.
texture_next_environment_mip :: proc(
    source: []f32,
    width, height: u32,
    allocator := context.allocator,
) -> (result: []f32, next_width, next_height: u32) {
    next_width = max(u32(1), width / 2)
    next_height = max(u32(1), height / 2)
    result = make([]f32, int(next_width) * int(next_height) * 4, allocator)

    for y in 0..<next_height {
        y0 := f64(y) * f64(height) / f64(next_height)
        y1 := f64(y + 1) * f64(height) / f64(next_height)
        first_y, end_y := u32(y0), min(u32(math.ceil(y1)), height)
        // Halving a dimension overlaps at most three source rows.
        row_weights: [3]f32
        for sy in first_y..<end_y {
            theta0 := max(y0, f64(sy)) * math.PI / f64(height)
            theta1 := min(y1, f64(sy + 1)) * math.PI / f64(height)
            row_weights[sy - first_y] = f32(math.cos(theta0) - math.cos(theta1))
        }

        for x in 0..<next_width {
            x0 := f64(x) * f64(width) / f64(next_width)
            x1 := f64(x + 1) * f64(width) / f64(next_width)
            first_x, end_x := u32(x0), min(u32(math.ceil(x1)), width)
            sum: [4]f32
            total_weight: f32
            for sy in first_y..<end_y {
                for sx in first_x..<end_x {
                    overlap := min(x1, f64(sx + 1)) - max(x0, f64(sx))
                    weight := f32(overlap) * row_weights[sy - first_y]
                    index := int((sy * width + sx) * 4)
                    for channel in 0..<4 do sum[channel] += source[index + channel] * weight
                    total_weight += weight
                }
            }
            index := int((y * next_width + x) * 4)
            for channel in 0..<4 do result[index + channel] = sum[channel] / total_weight
        }
    }
    return
}

// Levels in a full mip chain: each half the size of the last (rounded down,
// at least 1) down to 1x1.
texture_mip_count :: proc(width, height: u32) -> u32 {
    count: u32 = 1
    for w, h := width, height; w > 1 || h > 1; count += 1 {
        w, h = max(1, w / 2), max(1, h / 2)
    }
    return count
}

// How a material texture's levels average texels: data as stored, sRGB color
// in linear space (alpha stays linear), and normal maps as directions.
Texture_Mip_Mode :: enum {Data, Srgb, Normal}

texture_mip_mode :: proc(usage: TextureUsage) -> Texture_Mip_Mode {
    #partial switch usage {
    case .albedo, .emissive: return .Srgb
    case .normal: return .Normal
    }
    return .Data
}

// The full mip chain of an RGBA8 image; level 0 is `pixels` itself, the rest
// come from runtime.heap_allocator(). Each level is a 2x2 box filter of the
// one above: for odd sizes the last row or column is dropped, as D3D's sizes
// (half, rounded down) imply, and a 1-texel-wide level repeats its only
// column. sRGB is decoded and re-encoded with the exact transfer functions and
// every value rounded to the nearest byte, so the error does not grow level
// after level.
texture_build_mips :: proc(pixels: []u8, width, height: u32, mode: Texture_Mip_Mode) -> [][]u8 {
    heap := runtime.heap_allocator()
    levels := make([][]u8, texture_mip_count(width, height), heap)
    levels[0] = pixels

    to_linear: [256]f32
    for &value, i in to_linear {
        c := f32(i) / 255
        value = c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4)
    }
    to_byte :: proc(value: f32) -> u8 {
        return u8(math.floor(clamp(value, 0, 1) * 255 + 0.5))
    }
    to_srgb :: proc(value: f32) -> f32 {
        return value * 12.92 if value <= 0.0031308 else 1.055 * math.pow(max(value, 0), 1.0 / 2.4) - 0.055
    }

    w, h := width, height
    for level in 1..<len(levels) {
        next_w, next_h := max(1, w / 2), max(1, h / 2)
        source := levels[level - 1]
        target := make([]u8, int(next_w) * int(next_h) * 4, heap)
        for y in 0..<next_h {
            for x in 0..<next_w {
                taps: [4]int
                for i in 0..<u32(4) {
                    sx := min(x * 2 + i % 2, w - 1)
                    sy := min(y * 2 + i / 2, h - 1)
                    taps[i] = int(sy * w + sx) * 4
                }
                out := target[int(y * next_w + x) * 4:][:4]
                switch mode {
                case .Data:
                    for c in 0..<4 {
                        sum := 0
                        for tap in taps do sum += int(source[tap + c])
                        out[c] = u8((sum + 2) / 4)
                    }
                case .Srgb:
                    for c in 0..<3 {
                        sum: f32
                        for tap in taps do sum += to_linear[source[tap + c]]
                        out[c] = to_byte(to_srgb(sum * 0.25))
                    }
                    alpha := 0
                    for tap in taps do alpha += int(source[tap + 3])
                    out[3] = u8((alpha + 2) / 4)
                case .Normal:
                    // Average directions, not encoded values.
                    n: [3]f32
                    for tap in taps do for c in 0..<3 do n[c] += f32(source[tap + c]) / 255 * 2 - 1
                    length := math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
                    n = n / length if length > 0.0001 else {0, 0, 1}
                    for c in 0..<3 do out[c] = to_byte(n[c] * 0.5 + 0.5)
                    out[3] = 255
                }
            }
        }
        levels[level] = target
        w, h = next_w, next_h
    }
    return levels
}