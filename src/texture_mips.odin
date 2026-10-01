package main

import "core:math"
import linalg "core:math/linalg"

texture_next_mip :: proc(
    source: []u8,
    width, height: u32,
    allocator := context.allocator,
    normal_map := false,
    linear_data := false,
) -> (result: []u8, next_width, next_height: u32) {
    next_width = max(u32(1), width / 2)
    next_height = max(u32(1), height / 2)

    result = make(
        []u8,
        int(next_width) * int(next_height) * 4,
        allocator,
    )

    for y in 0..<next_height {
        for x in 0..<next_width {
            destination := int((y * next_width + x) * 4)

            if normal_map {
                normal: linalg.Vector3f32

                for offset_y in 0..<2 {
                    for offset_x in 0..<2 {
                        source_x := min(x * 2 + u32(offset_x), width - 1)
                        source_y := min(y * 2 + u32(offset_y), height - 1)
                        source_index := int((source_y * width + source_x) * 4)

                        for channel in 0..<3 {
                            normal[channel] +=
                                f32(source[source_index + channel]) / 255.0 * 2.0 - 1.0
                        }
                    }
                }

                if linalg.dot(normal, normal) > 0.00000001 {
                    normal = linalg.normalize(normal)
                } else {
                    normal = {0, 0, 1}
                }

                for channel in 0..<3 {
                    result[destination + channel] = u8(clamp(
                        (normal[channel] * 0.5 + 0.5) * 255.0 + 0.5,
                        0.0,
                        255.0,
                    ))
                }
                result[destination + 3] = 255
                continue
            }

            for channel in 0..<3 {
                linear_sum: f32

                for offset_y in 0..<2 {
                    for offset_x in 0..<2 {
                        source_x := min(x * 2 + u32(offset_x), width - 1)
                        source_y := min(y * 2 + u32(offset_y), height - 1)
                        source_index := int(
                            (source_y * width + source_x) * 4 +
                            u32(channel)
                        )

                        encoded := f32(source[source_index]) / 255.0
                        if linear_data {
                            linear_sum += encoded
                        } else {
                            linear_sum += math.pow(encoded, 2.2)
                        }
                    }
                }

                linear_average := linear_sum * 0.25
                encoded_average := linear_average

                if !linear_data {
                    encoded_average = math.pow(linear_average, 1.0 / 2.2)
                }

                result[destination + channel] = u8(clamp(
                    encoded_average * 255.0 + 0.5,
                    0.0,
                    255.0,
                ))
            }

            alpha_sum: u32
            for offset_y in 0..<2 {
                for offset_x in 0..<2 {
                    source_x := min(x * 2 + u32(offset_x), width - 1)
                    source_y := min(y * 2 + u32(offset_y), height - 1)
                    source_index := int(
                        (source_y * width + source_x) * 4 + 3
                    )
                    alpha_sum += u32(source[source_index])
                }
            }
            result[destination + 3] = u8((alpha_sum + 2) / 4)
        }
    }

    return
}