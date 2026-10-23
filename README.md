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
paths resolve correctly. HDR environments are local assets registered in
`assets.json`. The default is `textures/environments/autumn_field_puresky_4k.hdr`;
`textures/environments/kloofendal_43d_clear_puresky_4k.hdr` is also available in the
Renderer controls environment picker. Set `default_environment` in `assets.json`
to the desired environment ID to change the startup default.

If `assets.json` is missing, startup creates a base catalog with the starter
meshes/textures and both environments listed above, then loads it normally.
Additional assets can be registered through the editor's import panel.
If the default HDR file is unavailable, startup uses ambient-color lighting and
a solid background instead.

## Debug UI

The **Renderer controls** panel has exposure/bloom sliders, FPS, wall-clock frame
time, and all six GPU-pass timings. Changes reach the post-process constants in
the same frame. The final GPU timing includes tone mapping and the UI draw.

- **Tone mapping**: ACES (fitted, the default), AgX, or Reinhard. Scenes saved
  before this option existed load with Reinhard, their original look.
- **Shadow distance**: how far from the camera sun shadows reach (default 40). The
  view up to this distance is split into four cascaded shadow maps (2048² each),
  mostly logarithmically, so nearby shadows get millimetre-scale texels and distant
  ones still exist. Cascades blend into each other, and shadows fade out over the
  last 15%. Edges use a 5×5 tent filter. **Show shadow cascades** tints receivers
  red/green/blue/yellow by cascade.
- **Shadow bias / slope bias**: sun-shadow depth bias in shadow-map texels. Raise
  them for acne (striped self-shadowing); lower them if shadows detach from objects.
- **Ambient occlusion (SSAO)**: darkens ambient (sky) light in creases and where
  objects meet, using a depth prepass, 16 view-space samples per pixel within
  **AO radius** (world units), and a depth-aware blur. **AO intensity** is the
  exponent applied to the result. Direct sun and point light are unaffected.
  **Show AO only** displays the occlusion buffer for tuning.
- **Sun from HDRI** (HDRI lighting, on by default): the panorama's sun is found when
  it loads, removed from the image-based lighting, and becomes the shadowed
  directional light, with its measured direction, color and intensity. It follows
  the environment rotation and IBL intensity, and the visible sky keeps its sun.
  Turn it off to use the scene's own sun with the unmodified IBL. Panoramas
  without a distinct sun keep the scene sun.
- **Lighting mode**: choose HDRI lighting or an ambient color/intensity. Ambient
  color lights both diffuse and specular materials; zero intensity gives direct
  sun/point lighting only.
- **Background**: independently choose the HDRI panorama or a solid color, with
  its own brightness. It does not change the lighting on scene geometry.
- HDR files load only when lighting or the background uses HDRI. Lighting maps
  are filtered only when HDRI lighting needs them; switching back reuses them.
- **Save Scene / Load Scene** preserves both modes and their settings, including
  the inactive HDRI/color controls. Older scenes retain HDRI lighting/backgrounds.

- **Gizmos**: with the mouse released, click an object and drag its handles in the
  viewport. **W** moves along world axes (center square: move in the view plane),
  **E** rotates around world axes, **R** scales along the object's local axes (center
  square: uniform). Right-click during a drag cancels it; each drag is one undo step.
  The same modes are in the Inspector. Orbiting point lights cannot be moved.
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
