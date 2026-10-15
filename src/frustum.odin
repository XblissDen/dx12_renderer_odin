package main

import "core:math"
import alg "core:math/linalg"

Frustum :: struct {
    planes: [6]alg.Vector4f32,
}

WorldBounds :: struct {
    center: alg.Vector3f32,
    half_axes: [3]alg.Vector3f32,
    valid: bool,
}

frustum_from_matrix :: proc(view_projection: alg.Matrix4f32) -> Frustum {
    // HLSL uses row vectors: clip coordinates are dot products with columns.
    columns: [4]alg.Vector4f32
    for column in 0..<4 {
        columns[column] = {
            view_projection[0, column], view_projection[1, column],
            view_projection[2, column], view_projection[3, column],
        }
    }

    result := Frustum{planes = {
        columns[3] + columns[0], // Left:   x + w >= 0
        columns[3] - columns[0], // Right:  w - x >= 0
        columns[3] + columns[1], // Bottom: y + w >= 0
        columns[3] - columns[1], // Top:    w - y >= 0
        columns[2],             // Near:   z >= 0 (Direct3D)
        columns[3] - columns[2], // Far:    w - z >= 0
    }}

    for &plane in result.planes {
        length := alg.length(alg.Vector3f32{plane.x, plane.y, plane.z})
        if length > 0 {
            plane /= length
        }
    }
    return result
}

bounds_to_world :: proc(
    bounds: MeshBounds,
    model: alg.Matrix4f32,
) -> WorldBounds {
    if !bounds.valid {
        return {}
    }

    local_center := (bounds.minimum + bounds.maximum) * 0.5
    half_size := (bounds.maximum - bounds.minimum) * 0.5

    center := alg.mul(model, alg.Vector4f32{
        local_center.x, local_center.y, local_center.z, 1,
    })

    // Each column transforms one local axis; include its half-size here.
    return WorldBounds{
        center = {center.x, center.y, center.z},
        half_axes = {
            alg.Vector3f32{model[0, 0], model[1, 0], model[2, 0]} * half_size.x,
            alg.Vector3f32{model[0, 1], model[1, 1], model[2, 1]} * half_size.y,
            alg.Vector3f32{model[0, 2], model[1, 2], model[2, 2]} * half_size.z,
        },
        valid = true,
    }
}

frustum_intersects_bounds :: proc(
    frustum: Frustum,
    bounds: WorldBounds,
) -> bool {
    if !bounds.valid {
        return true
    }

    for plane in frustum.planes {
        normal := alg.Vector3f32{plane.x, plane.y, plane.z}
        distance := alg.dot(normal, bounds.center) + plane.w
        radius := math.abs(alg.dot(normal, bounds.half_axes[0])) +
                  math.abs(alg.dot(normal, bounds.half_axes[1])) +
                  math.abs(alg.dot(normal, bounds.half_axes[2]))

        // Reject only when the whole box lies outside a plane.
        // A small world-space tolerance retains boxes touching a boundary.
        if distance + radius < -0.001 {
            return false
        }
    }

    return true
}