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

`build.bat` builds with `-o:speed` and passes extra arguments to `odin build`.
`build.bat -debug` enables the D3D12 debug layer; its messages, and a report of
GPU objects still alive at shutdown, are printed to stderr. That build uses the
Windows subsystem, which has no console, so to see them build a console version
instead: `odin build src -debug -o:speed`.

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

## Importing models

The **Assets...** panel imports OBJ, glTF 2.0 (`.gltf` with its
`.bin` and images beside it, or a single `.glb`), and PNG/JPEG textures.

A glTF import copies the model and every file it references into
`models/imported/<id>/` (embedded GLB images become files there), registers it
in `assets.json`, and is undone completely if any step fails:

- The model is flattened into one entity: node transforms are baked into the
  vertices, and primitives sharing a material become one submesh.
- Each material becomes a *material slot* with its base color (texture and
  factor), normal map, metallic/roughness, emission, occlusion, alpha mode
  (opaque, cutout or blend) and double-sidedness. The packed metallic-roughness
  texture is registered as a roughness texture (green channel) and a metallic
  texture (blue channel); the occlusion map uses the red channel, often of that
  same texture. Select a slot in the Inspector to edit it; scenes (format
  version 9) save every slot.
- **Emission** (color, strength, and an optional sRGB map) is added after
  lighting, so bright parts bloom. `KHR_materials_emissive_strength` is read.
- **Occlusion maps** darken ambient light only, multiplied with SSAO and
  blended in by their strength.
- **Cutout** (glTF alpha mask) materials: pixels whose albedo alpha is below the
  cutoff are discarded in the depth prepass and shadow pass, and the lit pass
  shades only what the prepass kept. Alpha is scaled up with the mip level so
  thin cutouts (leaves, chains) keep their coverage at a distance.
- **Blend** materials (glass, such as the FlightHelmet lenses) are drawn after
  all opaque surfaces, farthest first by submesh center, over them by albedo
  alpha times the material's opacity (the base color factor's alpha in glTF).
  They are depth-tested but write no depth, so they are left out of SSAO, and
  TAA has no motion vectors for them (moving glass can smear slightly). They
  cast shadows where their alpha is at least 0.5. Sorting is per submesh, so
  overlapping blended parts of one submesh can blend in the wrong order.
- **Double-sided** materials draw without back-face culling, and back faces
  are lit from their own side; blended ones draw their back faces first.
- Geometry is converted from glTF's right-handed space to the renderer's
  left-handed one. Missing normals and tangents are generated.
- Not supported yet: animation and skinning (the static pose loads), and
  compressed meshes (Draco, meshopt), which are rejected.
- **Picking** (clicking an object) matches what is drawn: it sees through
  cutout holes (the albedo alpha at the hit point against the cutoff), hits
  both sides of double-sided materials, and selects blended surfaces such as
  glass like any other. For this, albedo textures that contain transparency
  keep a full-size copy of their alpha channel on the CPU (fully opaque ones
  keep nothing). The pick tests the full-size texel, while the shader filters
  and adjusts alpha per mip level, so edges can differ by a texel.
- Models imported before a material feature existed keep the materials stored
  in `assets.json`; import them again to pick it up.

Textures load at startup and on import. PNG/JPEG decoding runs on worker
threads, one texture per core at a time; only the full-size image is
uploaded, and the GPU renders the mip chain from it (`shaders/texture_mips.hlsl`):
2x2 averages in linear space for color, renormalized directions for normal
maps, rounded the same way as the CPU filter it replaced. With Sponza and the
helmets in the catalog (129 textures), textures take about 1.2 s.

### Removing assets

The same panel removes a model or texture from the catalog (with a
confirmation step):

- It is refused while anything uses the asset: an entity in the scene (for
  textures, in any material slot or map, including disabled ones), or another
  model's default material. The panel names the user.
- Removing a model also removes the textures its import registered
  (`<model id>.…`) that nothing else uses.
- `assets.json` is rewritten without them and their GPU data is freed. Files the
  importer copied are deleted: a glTF model's `models/imported/<id>/` folder, an
  imported OBJ or texture file. Files outside `models/imported/` and
  `textures/imported/` are never deleted, only unlisted.
- Undo history is cleared (old steps could bring back an entity using the asset),
  and the removal itself cannot be undone. Saved scenes that use a removed asset
  no longer load.
- Handles are not reused during a session, so nothing else shifts; the catalog is
  compacted at the next start.

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
- **Anti-aliasing**: FXAA (default), TAA, or Off. FXAA runs on the tone-mapped
  image, finds high-contrast edges, and blends across them along the edge's
  direction. TAA renders each frame with a sub-pixel jitter (8-sample Halton
  pattern) and blends it into a history reprojected with per-pixel motion vectors
  from the depth prepass, clipping the history to the current neighbourhood's
  colours to avoid ghosting; it resolves in HDR before bloom, which also steadies
  edge flicker in motion and SSAO noise. The selection outline and this UI are
  drawn afterwards, so text stays sharp.
- **Ambient occlusion (SSAO)**: darkens ambient (sky) light in creases and where
  objects meet, using a depth prepass, 16 view-space samples per pixel within
  **AO radius** (world units), and a depth-aware blur. **AO intensity** is the
  exponent applied to the result. Direct sun and point light are unaffected.
  Materials with an occlusion map multiply it in. **Show AO only** displays the
  combined occlusion for tuning.
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
  viewport. **W** moves (center square: move in the view plane), **E** rotates,
  **R** scales along the object's local axes (center square: uniform). **Q**
  switches moving and rotating between world and local axes; scale is always
  local, since scaling a rotated object along world axes would shear it.
  **Snap** moves, rotates and scales in whole steps counted from where the drag
  started (defaults: 0.25 units, 15°, 0.1, or 10% for uniform scale); holding
  **Ctrl** during a drag flips it. Right-click during a drag cancels it; each
  drag is one undo step. The modes, space, snapping and step sizes are in the
  Inspector. Orbiting point lights cannot be moved.
- **Lights**: **Add Point Light** (Scene panel) places a white light, shown by a
  small unlit cube, three units in front of the camera. Point lights can be
  duplicated and deleted like models, with undo; a duplicated orbiting light
  starts 45° further along its orbit. The shader takes at most 16 point lights,
  and adding, duplicating or undoing past that is refused with a note. The sun
  cannot be deleted: the renderer always uses exactly one directional light.
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
