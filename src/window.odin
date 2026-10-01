package main

import "base:runtime"
import win32 "core:sys/windows"

WINDOW_CLASS :: "DX12WindowClass"
WINDOW_TITLE :: "DX12 Renderer"
WINDOW_WIDTH :: 1920
WINDOW_HEIGHT :: 1080

g_client_width: u32 = WINDOW_WIDTH
g_client_height: u32 = WINDOW_HEIGHT

g_hwnd: win32.HWND
g_running: bool

g_mouse_delta_x: i32
g_mouse_delta_y: i32
g_cursor_locked: bool

g_exposure_steps: i32
g_threshold_steps: i32
g_bloom_steps: i32

window_create :: proc(){
    hinstance := win32.HINSTANCE(win32.GetModuleHandleW(nil))

    wc := win32.WNDCLASSEXW{
        cbSize = size_of(win32.WNDCLASSEXW),
        style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        lpfnWndProc = window_proc,
        hInstance = hinstance,
        hCursor = win32.LoadCursorW(nil, cast(cstring16)cast(rawptr)win32.IDC_ARROW),
        lpszClassName = win32.L(WINDOW_CLASS),
    }

    win32.RegisterClassExW(&wc)

    rect := win32.RECT {0, 0, WINDOW_WIDTH, WINDOW_HEIGHT}
    win32.AdjustWindowRect(&rect, win32.WS_EX_OVERLAPPEDWINDOW, false)

    g_hwnd = win32.CreateWindowExW(
        0,
        win32.L(WINDOW_CLASS),
        win32.L(WINDOW_TITLE),
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
        rect.right - rect.left,
        rect.bottom - rect.top,
        nil, nil,
        hinstance,
        nil,
    )

    win32.ShowWindow(g_hwnd, win32.SW_SHOW)
    win32.UpdateWindow(g_hwnd)
    g_running = true
}

window_process_messages :: proc(){
    msg: win32.MSG
    for win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE){
        if msg.message == win32.WM_QUIT{
            g_running = false
            return
        }
        win32.TranslateMessage(&msg)
        win32.DispatchMessageW(&msg)
    }
}

window_lock_cursor :: proc() {
    if g_cursor_locked {
        return
    }
    
    g_cursor_locked = true
    g_mouse_delta_x = 0
    g_mouse_delta_y = 0
    win32.ShowCursor(false)

    // clip cursor to window
    rect: win32.RECT
    win32.GetClientRect(g_hwnd, &rect)

    top_left := win32.POINT{rect.left, rect.top}
    bottom_right := win32.POINT{rect.right, rect.bottom}
    win32.ClientToScreen(g_hwnd, &top_left)
    win32.ClientToScreen(g_hwnd, &bottom_right)

    clip_rect := win32.RECT{ top_left.x, top_left.y, bottom_right.x, bottom_right.y }
    win32.ClipCursor(&clip_rect)


    // raw input registration
    rid: win32.RAWINPUTDEVICE
    rid.usUsagePage = 0x01 // Generic Desktop Controls
    rid.usUsage     = 0x02 // Mouse
    rid.dwFlags     = 0
    rid.hwndTarget  = g_hwnd

    win32.RegisterRawInputDevices(&rid, 1, size_of(win32.RAWINPUTDEVICE))
}

window_unlock_cursor :: proc(){
    if !g_cursor_locked{
        return
    }

    g_cursor_locked = false
    g_mouse_delta_x = 0
    g_mouse_delta_y = 0
    win32.ClipCursor(nil)
    win32.ShowCursor(true)
}

@(private)
window_proc :: proc "stdcall" (hwnd: win32.HWND, msg: win32.UINT,
wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT{
    context = runtime.default_context()

    if debug_ui_handle_message(hwnd, msg, wparam, lparam) {
        return 1
    }

    switch msg{
        case win32.WM_INPUT:
            if g_cursor_locked {
                size: win32.UINT
                win32.GetRawInputData(win32.HRAWINPUT(lparam), win32.RID_INPUT, nil, &size, size_of(win32.RAWINPUTHEADER))
                
                buf := make([]u8, size, context.temp_allocator)
                win32.GetRawInputData(win32.HRAWINPUT(lparam), win32.RID_INPUT, raw_data(buf), &size, size_of(win32.RAWINPUTHEADER))

                raw := (^win32.RAWINPUT)(raw_data(buf))
                if raw.header.dwType == win32.RIM_TYPEMOUSE {
                    g_mouse_delta_x += raw.data.mouse.lLastX
                    g_mouse_delta_y += raw.data.mouse.lLastY
                }
            }
        case win32.WM_KILLFOCUS:
            window_unlock_cursor()
        case win32.WM_SIZE:
            g_client_width = u32(u64(lparam) & 0xffff)
            g_client_height = u32((u64(lparam) >> 16) & 0xffff)
        case win32.WM_KEYDOWN:
            if wparam == win32.VK_ESCAPE{
                win32.PostQuitMessage(0)
            } else if wparam == win32.VK_F1 {
                if (u64(lparam) & (u64(1) << 30)) == 0 {
                    g_debug_ui_visible = !g_debug_ui_visible
                }
            } else if wparam == win32.WPARAM('L'){
                if (u64(lparam) & (u64(1) << 30)) == 0{
                    if g_cursor_locked{
                        window_unlock_cursor()
                    } else{
                        window_lock_cursor()
                    }
                }
            } else if debug_ui_wants_keyboard() {
                return 0
            } else if (u64(lparam) & (u64(1) << 30)) == 0 {
                // One adjustment per physical press, ignoring key auto-repeat.
                switch wparam {
                    case win32.WPARAM('1'): g_exposure_steps -= 1
                    case win32.WPARAM('2'): g_exposure_steps += 1
                    case win32.WPARAM('3'): g_threshold_steps -= 1
                    case win32.WPARAM('4'): g_threshold_steps += 1
                    case win32.WPARAM('5'): g_bloom_steps -= 1
                    case win32.WPARAM('6'): g_bloom_steps += 1
                }
            }
        case win32.WM_CHAR:
            if debug_ui_wants_keyboard() {
                return 0
            }
        case win32.WM_DESTROY:
            window_unlock_cursor()
            win32.PostQuitMessage(0)
    }

    return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}
