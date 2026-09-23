package main

import "core:math"
import "core:math/linalg"
import win32 "core:sys/windows"

Camera :: struct {
    position: linalg.Vector3f32,
    yaw:      f32, // radians
    pitch:    f32,
    speed:    f32,
    sensitivity: f32,
}

g_camera: Camera

camera_init :: proc(){
    g_camera = Camera {
        position    = { 0, 0, -3 },
        yaw         = math.PI * 0.5, // смотрим вдоль +Z изначально
        pitch       = 0,
        speed       = 3.0,           // единиц в секунду
        sensitivity = 0.003,
    }
}

camera_forward :: proc(c: ^Camera) -> linalg.Vector3f32 {
    return linalg.normalize(linalg.Vector3f32{
        math.cos(c.pitch) * math.cos(c.yaw),
        math.sin(c.pitch),
        math.cos(c.pitch) * math.sin(c.yaw),
    })
}

camera_right :: proc(c: ^Camera) -> linalg.Vector3f32 {
    world_up := linalg.Vector3f32{ 0, 1, 0 }
    return linalg.normalize(linalg.cross(camera_forward(c), world_up))
}

camera_update :: proc(c: ^Camera, dt: f32) {
    if !g_cursor_locked{
        return
    }
    
    forward := camera_forward(c)
    right   := camera_right(c)

    c.yaw -= f32(g_mouse_delta_x) * c.sensitivity
    c.pitch -= f32(g_mouse_delta_y) * c.sensitivity

    c.pitch = clamp(c.pitch, -math.PI * 0.49, math.PI * 0.49)

    g_mouse_delta_x = 0
    g_mouse_delta_y = 0

    move: linalg.Vector3f32

    if key_down(i32('W'))         do move += forward
    if key_down(i32('S'))         do move -= forward
    if key_down(i32('D'))         do move -= right
    if key_down(i32('A'))         do move += right
    if key_down(win32.VK_SPACE)   do move.y += 1
    if key_down(win32.VK_SHIFT)   do move.y -= 1

    if linalg.length(move) > 0 {
        move = linalg.normalize(move)
        c.position += move * c.speed * dt
    }
}

camera_view_matrix :: proc(c: ^Camera) -> linalg.Matrix4f32 {
    forward := camera_forward(c)
    target  := c.position + forward
    return look_at_lh(c.position, target, { 0, 1, 0 })
}

key_down :: proc(vkey: i32) -> bool {
    return (u16(win32.GetAsyncKeyState(vkey)) & 0x8000) != 0
}