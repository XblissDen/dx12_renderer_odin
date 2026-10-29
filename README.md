# DX12 renderer

A graphics-learning project: a real-time renderer and small scene editor
written in Odin on DirectX 12, with a Dear ImGui interface.

## Features

- **Lighting**: metallic-roughness PBR; one sun plus up to 1024 point and spot
  lights shaded through clustered lighting; image-based lighting from HDR
  panoramas, with the panorama's sun extracted as a shadowed light.
- **Shadows**: four cascaded sun shadow maps, plus shadow maps for the four
  nearest spot lights and cube maps for the four nearest point lights.
- **Screen-space and volumetric effects**: ambient occlusion (SSAO),
  reflections (SSR), and volumetric fog with light shafts.
- **Post-processing**: TAA with sharpening or FXAA, auto exposure, bloom, and
  ACES, AgX or Reinhard tone mapping.
- **Assets**: OBJ and glTF 2.0 import with materials (normal, roughness and
  metallic, emissive and occlusion maps; cutout, blended and double-sided
  materials); textures with mips built on the GPU.
- **Editor**: picking and multiple selection, move/rotate/scale gizmos, an Inspector, undo and redo,
  and saving and loading scenes.
- **Workflow**: shader hot-reload, and GPU timings for every pass.

How each of these works is explained in **[docs/](docs/README.md)**.

## Build and run

Requirements:

- Odin on `PATH`.
- Visual Studio or Build Tools with **Desktop development with C++** and a
  Windows SDK.

From the project root:

```bat
build.bat
dx12_renderer.exe
```

- `build.bat` builds optimized (`-o:speed`) and passes extra arguments to
  `odin build`; `build.bat -debug` enables the D3D12 debug layer.
- The debug layer's messages, and a report of GPU objects still alive at
  shutdown, go to stderr, and the Windows-subsystem build has no console. To see them, build a console version instead:
  `odin build src -debug -o:speed`.
- Run from the project root, so the relative `models/`, `textures/` and
  `shaders/` paths resolve.
- Assets are listed in `assets.json`; if it is missing, startup creates one
  with the starter assets.
- Saving a file in `shaders/` while the program runs reloads the shaders.

## Controls

| Input | Action |
| --- | --- |
| **L** | Capture or release the mouse |
| Mouse, **W A S D**, **Space / Shift** | Look, move, move up / down (mouse captured) |
| Click, Ctrl+click, Shift+click | Select an object; add or remove; add (mouse released) |
| **W / E / R**, **Q** | Gizmo move, rotate, scale; world or local axes (mouse released) |
| **1–6** | Exposure, bloom threshold, bloom strength |
| **F1** | Hide or show the panels |
| **Esc** | Quit |

## Dear ImGui

Dear ImGui **v1.92.9b-docking** is vendored under `vendor/imgui/src`, with its
MIT license and unmodified DX12/Win32 backends; the exact commit is in
`vendor/imgui/VERSION.txt`. Odin uses it through a small C interface in
`vendor/imgui/bridge.cpp`, declared in `src/debug_ui.odin`. There are no
generated bindings and no Premake, CMake or Python step.

`build.bat` builds the static library on the first build with MSVC (found
through `vswhere`) and reuses it afterwards. After changing the bridge or the
vendored sources, rebuild it explicitly:

```bat
vendor\imgui\build.bat --rebuild
build.bat
```
