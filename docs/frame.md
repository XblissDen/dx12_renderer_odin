# Frame structure

## Startup and the main loop

`main` (`src/main.odin`) creates the window and the D3D12 device, loads the
asset catalog (`assets.json`), builds the default scene, creates the root
signatures, and then compiles every shader and builds every pipeline in one
step (see [Shader hot-reload](#shader-hot-reload)). After that it uploads the
textures, creates the screen-sized targets, and loads the environment.

Each iteration of the loop:

1. Processes window messages and the keyboard shortcuts for exposure and bloom.
2. Resizes the swap chain and every screen-sized target if the window changed
   size. A minimized window renders nothing.
3. Builds the UI (`debug_ui_update`), which may change settings or the scene.
4. Checks the shader folder for changes, applies a pending environment change,
   and runs a pending asset import.
5. Updates picking, the camera, and scene animation (rotating objects,
   orbiting lights).
6. Renders and presents the frame.

All temporary allocations of a frame are freed at the end of the iteration.

## Frames in flight

Two frames can be in flight (`FRAME_COUNT`). Each has its own command
allocator and its own slice of every per-frame upload buffer: frame constants,
per-draw object constants, post-processing and sky constants, the light buffer,
and the material descriptor tables. Before recording, the CPU waits on the
fence for the frame that last used the same slot (`renderer_begin_frame`). That
wait is also when it reads that frame's GPU timings and exposure, which are
therefore two frames old. Presentation uses vsync.

## Pass order

`renderer_render_frame` records one command list per frame:

| Pass | What it does | Details |
| --- | --- | --- |
| Shadows | Sun cascades, then spot shadow slots, then point shadow cube faces | [Lighting](lighting.md#shadows) |
| Depth prepass | Depth, motion vectors, and the surface buffer (normal, roughness) | [below](#depth-prepass) |
| SSAO | Ambient occlusion from depth, then a depth-aware blur | [Lighting](lighting.md#ambient-occlusion-ssao) |
| SSR | Reflections traced through depth, read from last frame's image | [Lighting](lighting.md#screen-space-reflections-ssr) |
| Light clusters | Compute pass listing the lights that reach each view cluster | [Lighting](lighting.md#clustered-lighting) |
| Scene | Sky, then lit opaque surfaces, then blended surfaces back to front, into the HDR target | [Lighting](lighting.md) |
| TAA | Blends the frame into the reprojected history, in HDR | [Post-processing](post_processing.md#taa) |
| Auto exposure | Luminance histogram and exposure adaptation (compute) | [Post-processing](post_processing.md#auto-exposure) |
| Bloom | Threshold, downsample chain, upsample chain | [Post-processing](post_processing.md#bloom) |
| Post + UI | Tone mapping, then FXAA or sharpening, the selection box, and the UI | [Post-processing](post_processing.md) |

The scene is rendered into an `R16G16B16A16_FLOAT` HDR target. Everything up
to tone mapping works in linear HDR; the swap chain is `R8G8B8A8_UNORM`, and
tone mapping encodes sRGB itself because the UI draws to the same buffer.

## Per-frame data

`renderer_prepare_frame` (`src/renderer_frame_data.odin`) turns the scene into
GPU data every frame:

- **Draws**: one per submesh of every visible model entity, up to `MAX_DRAWS`
  (4096). Each has its object constants (model matrix, the inverse model
  matrix for normals, last frame's model matrix, and the material's values)
  in a 256-byte slot of the per-frame object constant buffer.
- **Material tables**: each draw's six textures (albedo, normal, roughness,
  metallic, emissive, occlusion) are copied from a CPU-only staging descriptor
  heap into a contiguous table in the shader-visible heap, bound with one root
  descriptor table. Unused maps get neutral textures (white, or a flat
  normal), so shaders never branch on missing textures except where a flag
  saves work.
- **Draw variants**: each mesh pass has four pipelines, for opaque, cutout,
  double-sided, and cutout double-sided materials. Cutouts run the alpha test
  in the depth-only passes; double-sided ones disable culling. Draws keep
  their order and switch pipelines only when the variant changes.
- **Frame constants** (`FrameConstants`, one 256-byte-aligned block): camera
  matrices (jittered for TAA, and unjittered for motion vectors, this frame
  and last), the sun, environment and ambient settings, shadow matrices and
  cascade data, SSAO, SSR and light-cluster settings, and the debug view
  flags.
- **Lights**: the point and spot lights in view, written straight into this
  frame's slice of the light buffer (see [Clustered
  lighting](lighting.md#clustered-lighting)).

### Culling

Every draw has a world-space bounding box: the mesh's local box under the
entity's transform, kept as a center and three half axes so rotation does not
inflate it. A box is tested against the six planes of each view's frustum and
rejected only if it lies entirely outside one plane. The camera view, each sun
cascade, each spot shadow slot, and each point shadow cube face cull
separately, so shadow passes draw only their own casters. Blended draws are
collected separately and sorted back to front by distance to their center. The
panel shows draw counts before and after culling, and culling can be turned
off to compare.

## Depth prepass

Opaque and cutout surfaces are drawn once without lighting before anything
else. The lit pass then tests against this depth without writing it, so each
pixel is shaded once, and SSAO and SSR have depth to read. The vertex shaders
of the two passes share one function, so both produce bit-identical depth:
opaque surfaces use a `LESS_EQUAL` test, and cutouts use `EQUAL` so the lit
pass does not repeat the alpha test.

The prepass writes two color targets alongside depth:

- **Motion vectors** (`R16G16_FLOAT`): how far each pixel's surface moved on
  screen since last frame, in UV units, from the unjittered current and
  previous clip positions. Moving objects use last frame's model matrix, kept
  per entity; an entity not drawn last frame gets no motion. TAA and SSR use
  these.
- **Surface buffer** (`R16G16B16A16_FLOAT`): the view-space shading normal
  (with the normal map) and the specular roughness. The lit pass computes the
  same values with the same function. SSR reads it; it is cleared to roughness
  1 where nothing is drawn.

Blended surfaces are not in the prepass: they write no depth, so SSAO, SSR and
TAA's motion vectors see what is behind them.

## Root signature

One root signature serves every graphics pass. Passes bind by slot name
(`Root_Slot` in `src/renderer.odin`), and `ROOT_LAYOUT` is the only place that
assigns registers:

| Slot | Register | Contents |
| --- | --- | --- |
| Object constants | b0 | Per-draw transforms and material values |
| Post / Sky / Prefilter constants | b1, b2, b3 | Per-pass constants |
| Frame constants | b4 | Camera, lights, shadows, effect settings |
| Shadow cascade, Mip constants | b5, b6 | Root constants |
| Texture T0, T1 | t0, t1 | Main inputs of full-screen passes; t1 is the sun's shadow cascades in the lit pass |
| Environment, Irradiance, Prefiltered | t2, t3, t4 | Panorama and IBL maps |
| Spot shadows, Point shadows | t5, t6 | Shadow map arrays |
| Surface | t7 | Prepass normal and roughness |
| Texture T8, Depth | t8, t9 | AO or motion vectors; scene depth |
| Material | t10–t15 | The draw's material table |
| Exposure buffer | t16 | Root SRV, the automatic exposure |
| Reflections | t17 | SSR result |
| Lights, Cluster lights | t18, t19 | Root SRVs, the light buffer and cluster lists |

Static samplers: linear wrap (s0), shadow comparison with a white border (s1),
16× anisotropic for materials (s2), panoramas wrapping horizontally but
clamped at the poles (s3), and clamp-to-edge for screen-space lookups (s4).

Compute passes (auto exposure, light clusters) and the selection box have their
own small root signatures.

## GPU timings

Every pass is bracketed by a pair of timestamp queries, resolved into a
readback buffer at the end of the frame and read when that frame slot comes
around again. A pass that is switched off still records its two timestamps,
so every pass has a value each frame (zero when skipped). The **GPU timings**
table in Renderer controls lists them; "Post + UI" includes tone mapping and
the UI draw.

## Shader hot-reload

Saving any file in `shaders/` while the program runs rebuilds every pipeline,
in about a third of a second.

- **Detection**: the folder's `.hlsl` write times are summed and checked every
  250 ms. A reload starts once the sum has stayed the same for one check, so a
  file still being written is not compiled half-saved.
- **One build path**: startup and reload both run the pipeline-creation code
  twice. The first run only records which shader entry points it asks for. All
  of them then compile in parallel, one thread each; the slowest shader sets
  the time. The second run creates the pipelines from the compiled blobs.
- **All or nothing**: the old pipelines are set aside. If any shader fails to
  compile or any pipeline fails to create (for example, a shader that no longer
  fits the root signature), the new ones are released and the old ones
  restored. The first error is shown at the top of Renderer controls, with
  paths relative to the project, and printed to the console.
- **Re-bakes**: the image-based lighting maps are baked once, so editing
  `irradiance.hlsl` or `environment_prefilter.hlsl` also re-bakes them.
  **Reload shaders** forces a full reload including that re-bake.

Changes outside the shaders, such as a new constant-buffer field or root slot,
need the program rebuilt.

## Resizing

On resize, the renderer waits for the GPU, releases and recreates the swap
chain buffers, depth, and every screen-sized target (HDR, LDR, bloom chain,
SSAO, TAA history and motion vectors, SSR surface and reflection targets), and
rewrites their descriptors in place. TAA and SSR restart: their history from
the old size is discarded.
