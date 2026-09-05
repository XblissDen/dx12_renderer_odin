package main

import "base:runtime"
import win32 "core:sys/windows"

WINDOW_CLASS :: "DX12WindowClass"
WINDOW_TITLE :: "DX12 Renderer"
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

g_hwnd: win32.HWND
g_running: bool

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

@(private)
window_proc :: proc "stdcall" (hwnd: win32.HWND, msg: win32.UINT,
wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT{
    context = runtime.default_context()

    switch msg{
        case win32.WM_KEYDOWN:
            if wparam == win32.VK_ESCAPE{
                win32.PostQuitMessage(0)
            }
        case win32.WM_DESTROY:
            win32.PostQuitMessage(0)
    }

    return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}