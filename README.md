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

### Shader hot-reload

Saving any file in `shaders/` while the program runs rebuilds every pipeline,
in about a third of a second (all shaders compile in parallel, at startup too).
The new set is used only if everything compiled and every pipeline was
created. Otherwise the previous shaders stay in use, and the first compiler
error is shown at the top of **Renderer controls** (also printed to the
console). Fix the file and save again to retry. Editing `irradiance.hlsl` or
`environment_prefilter.hlsl` also re-bakes the image-based lighting. **Reload
shaders** forces a full reload, including that re-bake.

Changes outside the shaders, such as a new constant-buffer field or root
signature slot, still need a rebuild of the program.

## Importing models

The **Assets...** panel imports OBJ, glTF 2.0 (`.gltf` with its
`.bin` and images beside it, or a single `.glb`), and PNG/JPEG textures.

OBJ files are read as right-handed (+Y up), as Blender and most tools write
them, and converted to the renderer's left-handed space like glTF, so models
are not mirrored. **Flip V** (on by default) matches their bottom-left UV
origin.

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
time, and the GPU timing of each pass. Changes reach the post-process constants
in the same frame. The "Post + UI" timing includes tone mapping and the UI draw.

- **Auto exposure** (on in the default scene): each frame, two compute passes
  (`shaders/auto_exposure.hlsl`) bin the HDR image's luminance, after TAA, into
  a 256-bin log histogram, average the pixels between the 50th and 95th
  percentile (so dark corners and the sun do not steer it), and expose that
  average to 0.36. The exposure eases toward its target, faster toward a
  darker image (**Adapt to bright**, 3/s) than a brighter one (**Adapt to
  dark**, 1/s), within **Min/Max EV**. **Compensation** (EV, +1 doubles the
  brightness; keys 1/2 step it by ¼ EV) adjusts the result, and the panel shows
  the current exposure. The value stays on the GPU for bloom and tone mapping.
  Scenes saved before version 10 load with it off, keeping their manual
  **Exposure**.
- **Bloom** is a mip chain (Jimenez, Call of Duty: Advanced Warfare, 2014),
  about 0.1 ms at 1080p. A prefilter writes what is above **Bloom threshold**
  at half resolution, using a 13-tap filter with a Karis average so the sun and
  other tiny super-bright spots cannot make it flicker; five downsamples halve
  it down to 1/64 resolution; upsamples then blur each level with a 3x3 tent
  and add it into the next larger one. Tone mapping adds the result, averaged
  over the levels, scaled by **Bloom strength**: a tight glow near bright
  parts plus a wide, soft halo. Edges are clamped, not wrapped.
- **Bloom threshold** applies to the exposed image, so what blooms does not
  change as exposure adapts. Saved scenes keep their threshold and strength,
  but the wider glow looks different from the old single blur, so they may
  want retuning.
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
- **Anti-aliasing**: TAA (default for new scenes), FXAA, or Off. Scenes saved
  without the setting load with FXAA. FXAA runs on the tone-mapped image, finds
  high-contrast edges, and blends across them along the edge's direction. TAA
  renders each frame with a sub-pixel jitter (8-sample Halton pattern) and
  blends it into a history reprojected with per-pixel motion vectors from the
  depth prepass, clipping the history to the current neighbourhood's colours to
  avoid ghosting; it resolves in HDR before bloom, which also steadies edge
  flicker in motion and SSAO noise. The selection outline and this UI are drawn
  afterwards, so text stays sharp.
  - **Sky motion**: the prepass draws no sky, so where a pixel's whole 3x3
    neighbourhood is sky, TAA computes its motion from camera rotation (the sky
    is infinitely far, so moving the camera does not move it): the pixel's
    far-plane point reprojected with last frame's rotation-only camera. After a
    90° turn, the sky is about ten times closer to a converged still frame than
    before. Glass and other blended surfaces still have no motion vectors.
  - **Sharpening** (TAA only, 0–1, default 0.5): AMD's contrast-adaptive
    sharpening (CAS) after tone mapping restores detail the history blend
    softens. Each pixel is pushed away from its four neighbours, less where the
    3x3 neighbourhood already has strong contrast, so edges get no halos. It
    runs like FXAA: tone mapping writes an intermediate image, and the sharpen
    pass writes the back buffer. 0 skips the pass. Scenes saved before version
    15 load with 0.
- **Ambient occlusion (SSAO)**: darkens ambient (sky) light in creases and where
  objects meet, using a depth prepass, 16 view-space samples per pixel within
  **AO radius** (world units), and a depth-aware blur. **AO intensity** is the
  exponent applied to the result. Direct sun and point light are unaffected.
  Materials with an occlusion map multiply it in. **Show AO only** displays the
  combined occlusion for tuning.
- **Screen-space reflections (SSR)** (on by default; about 0.6 ms at 1080p):
  reflections of what is on screen replace the environment's reflection on
  opaque surfaces. The depth prepass also writes each pixel's view-space
  normal (normal map included) and roughness. Before the lit pass, each pixel's
  reflected ray is marched through the depth buffer, up to 64 steps in screen
  space plus a binary search. Where the ray passes behind a surface, it reads
  that surface's color from last frame's HDR image, moved by its motion vector.
  Using last frame's image means reflections include the lighting and earlier
  reflections, so mirrors facing each other repeat. Hits fade out towards the
  screen edges, towards the end of the ray, and on back faces; there the
  environment's reflection shows instead. Settings:
  - **SSR max distance** is the ray length in world units.
  - **SSR thickness** is how far behind a visible surface the ray still counts
    as hitting it. Raise it if thin reflections break up; lower it if
    reflections smear behind objects.
  - **SSR max roughness**: rougher surfaces get no SSR, fading in below 60% of
    it. Normal-map detail too fine for the pixel raises the roughness used,
    as in lighting.

  With TAA, each pixel's ray direction is drawn from the GGX specular lobe
  with noise that changes every frame, and the TAA history averages them into
  blurred reflections on rough surfaces. Without TAA, rays are mirror
  reflections. **Show reflections only** displays this frame's raw SSR output
  before TAA, so it shows the noise. Blended surfaces (glass) get no SSR, and
  nothing off screen or hidden behind a foreground object can be reflected.
  Scenes saved before SSR load with the defaults.
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
  Inspector. Moving an orbiting point light moves its orbit (the Orbit center).
- **Lights**: **Add Point Light** and **Add Spot Light** (Scene panel) place a
  white light three units in front of the camera, shown by a small unlit marker
  in the light's color: a cube for point lights, a pyramid for spot lights.
  - Every point and spot light has a **Range**: the inverse-square falloff
    `intensity / (1 + d²)` is multiplied by `(1 - (d / range)⁴)²`, which reaches
    zero exactly at the range and stays close to 1 well inside it. Scenes saved
    before ranges (version < 11) get the distance where the old falloff drops to
    1% (about 17 units at intensity 3), so they look the same.
  - A spot light shines along its entity's local -Y axis, out of the pyramid's
    base: straight down until rotated (Rotation, or the rotate gizmo). Full
    brightness inside **Inner angle**, fading smoothly to none at **Outer angle**
    (half-angles, up to 89°).
  - **Orbit** (point lights): the light circles its **Orbit center**
    horizontally at **Orbit radius**; the center's y is the orbit's height.
    Turning orbit on sets the center so the light stays where it is, and the
    move gizmo moves the whole orbit. Orbiting lights from scenes before
    version 14 circle the origin at their saved height, as they used to.
  - Lights can be duplicated and deleted like models, with undo; a duplicated
    orbiting light starts 45° further along its orbit. A scene can have up to
    1024 point and spot lights together (as many as entities); past that,
    adding, duplicating or undoing is refused with a note. The sun cannot be
    deleted: the renderer always uses exactly one directional light.
  - **Clustered lighting** (`src/renderer_lights.odin`): each frame, the point
    and spot lights whose range reaches the view go into a light buffer. A
    compute pass splits the view into 16×9 screen tiles times 24 depth slices
    (each slice deeper than the one before, by a constant ratio from the near
    plane to the far clip). For each of these 3456 clusters it lists the lights
    whose range sphere touches the cluster's box, with spot lights also tested
    against their outer cone. The lit and blended passes shade each pixel with
    only its cluster's lights. With 240 lights in the default scene the lit
    pass takes 0.64 ms instead of 3.5 ms looping over all of them, with the
    same image; building the clusters takes about 0.1 ms. A cluster holds at
    most 127 lights, and any beyond that are left out there. **Show light
    clusters** (Renderer controls, under SSR) colors each pixel by its
    cluster's light count: black none, then blue (1), green (4), yellow (16),
    red (64), and white for a full cluster. The panel also shows how many
    lights are in view.
  - **Spot light shadows**: each frame the 4 spot lights nearest the camera with
    **Cast shadows** on (the default) get a 1024² shadow map, rendered from the
    light with the outer cone as its field of view and the range as its far
    plane, culled to that view. Cutout casters work as for the sun. Sampling
    uses the sun's 5×5 tent filter; acne is handled by a slope-scaled depth bias
    on the casters plus a 1.5-texel normal offset at the receiver. The Inspector
    says whether a light got a shadow this frame. Unlit light markers never cast
    shadows. Spot lights from version 11 scenes load with shadows on.
  - **Point light shadows** work the same way with cube maps: each frame the 4
    shadow-casting point lights nearest the camera get six 512² faces (90°
    views out to the range, in D3D's cube layout, each culled to its own view).
    The shader picks the face by direction, puts the receiver's distance along
    the dominant axis into that face's depth, and averages a 3×3 tent of
    filtered comparisons one texel apart. Each shadowed point light redraws its
    casters six times per frame; in the default scene both lights together add
    about 0.03 ms. Point lights from scenes before version 13 load with shadows
    on.
- **L**: release/capture the mouse. Release it to interact with the panel;
  capture it for the existing WASD/mouse camera controls.
- **F1**: hide/show the panel.
- **1–6**: exposure (or auto-exposure compensation), bloom-threshold, and
  bloom-strength shortcuts.
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
