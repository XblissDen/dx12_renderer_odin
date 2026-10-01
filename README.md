# DX12 renderer

A graphics-learning project written in Odin, with a DirectX 12 renderer.

## Build and run

Requirements:

- Odin on `PATH`.
- Visual Studio or Build Tools with **Desktop development with C++** and a Windows SDK.

From the project root:

```bat
build.bat
dx12_renderer.exe
```

Run from the project root so the relative `models/`, `textures/`, and `shaders/`
paths resolve correctly. The HDR environment is a local asset and is not tracked;
the current loader expects `textures/environment_4k_2.hdr`.

## Debug UI

The **Renderer controls** panel has exposure/bloom sliders, FPS, wall-clock frame
time, and all six GPU-pass timings. Changes reach the post-process constants in
the same frame. The final GPU timing includes tone mapping and the UI draw.

- **L**: release/capture the mouse. Release it to interact with the panel;
  capture it for the existing WASD/mouse camera controls.
- **F1**: hide/show the panel.
- **1–6**: existing exposure, bloom-threshold, and bloom-strength shortcuts.
- **Esc**: exit.
- **Show ImGui demo**: explore the included widgets and docking features.

Keyboard input captured by UI controls is kept away from the parameter shortcuts.
Camera mode disables ImGui mouse/keyboard interaction. L, F1, and Esc remain
application shortcuts.

## Dear ImGui dependency

Dear ImGui **v1.92.9b-docking** is vendored under `vendor/imgui/src`, including its
MIT license and unmodified official DX12/Win32 backends. The exact commit is in
`vendor/imgui/VERSION.txt`.

The project uses a small C interface in `vendor/imgui/bridge.cpp` instead of a
generated binding package. The Odin declarations and panel code are in
`src/debug_ui.odin`. Adding more widgets involves extending this small interface.

`build.bat` builds the static library automatically on the first build and reuses
it afterward. There is **no Premake, Python, CMake, or binding-generation step**.
Generated objects and libraries are ignored by Git. A clean checkout builds them
from the included sources using MSVC, found with Visual Studio's `vswhere`.

After changing the bridge or vendored C++ sources, rebuild the library explicitly:

```bat
vendor\imgui\build.bat --rebuild
build.bat
```

The UI owns a separate shader-visible SRV heap with allocation/free callbacks for
ImGui's dynamic font textures. It draws onto the SDR back buffer after tone
mapping and before the transition to `PRESENT`. Shutdown happens after the
renderer waits for the GPU. No changes to the scene's descriptor slots are needed.
