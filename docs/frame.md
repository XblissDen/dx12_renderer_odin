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
per-draw object data and bounds, the cull entries and indirect draw calls,
post-processing and sky constants, and the light buffer. Before recording,
the CPU waits on the fence for the frame that last used the same slot
(`renderer_begin_frame`). That wait is also when it reads that frame's GPU
timings, exposure and culling counters, which are therefore two frames old.
Presentation uses vsync.

The buffers the GPU itself writes each frame (the indirect calls after
culling, the instance lists, the depth pyramid, and the flags saying which
draws the camera saw) exist once: frames run in order on the one queue, so a
frame never overwrites them while an earlier one still reads them.

## Pass order

`renderer_render_frame` records one command list per frame:

| Pass | What it does | Details |
| --- | --- | --- |
| GPU culling | Compute pass testing draws against every view's frustum, filling in the shadow views' calls and the camera's early ones | [below](#gpu-culling) |
| Shadows | Sun cascades, then spot shadow slots, then point shadow cube faces | [Lighting](lighting.md#shadows) |
| Depth prepass | Depth, motion vectors, and the surface buffer (normal, roughness): the camera's early calls, then the depth pyramid and the late cull, then its late calls | [below](#depth-prepass) |
| SSAO | Ambient occlusion from depth, then a depth-aware blur | [Lighting](lighting.md#ambient-occlusion-ssao) |
| SSR | Reflections traced through depth, read from last frame's image | [Lighting](lighting.md#screen-space-reflections-ssr) |
| Light clusters | Compute pass listing the lights that reach each view cluster | [Lighting](lighting.md#clustered-lighting) |
| Volumetric fog | Compute passes lighting the fog's cells and integrating them front to back | [Lighting](lighting.md#volumetric-fog) |
| Scene | Sky, then lit opaque surfaces, then blended surfaces back to front, then the fog, into the HDR target | [Lighting](lighting.md) |
| TAA | Blends the frame into the reprojected history, in HDR | [Post-processing](post_processing.md#taa) |
| Auto exposure | Luminance histogram and exposure adaptation (compute) | [Post-processing](post_processing.md#auto-exposure) |
| Bloom | Threshold, downsample chain, upsample chain | [Post-processing](post_processing.md#bloom) |
| Post + UI | Tone mapping, then FXAA or sharpening, the debug lines, the selection outline, and the UI | [Post-processing](post_processing.md) |

The scene is rendered into an `R16G16B16A16_FLOAT` HDR target. Everything up
to tone mapping works in linear HDR; the swap chain is `R8G8B8A8_UNORM`, and
tone mapping encodes sRGB itself because the UI draws to the same buffer.

## Per-frame data

`renderer_prepare_frame` (`src/renderer_frame_data.odin`) turns the scene into
GPU data every frame:

- **Draws**: one per submesh of every visible model entity, up to `MAX_DRAWS`
  (4096). Each has its object data: the model matrix, the inverse model
  matrix for normals, last frame's model matrix, the material's values, and
  its textures. These are 288-byte `ObjectData` entries in this frame's part
  of the object buffer, which shaders read as a structured buffer.
- **Bindless textures**: an object names its six textures (albedo, normal,
  roughness, metallic, emissive, occlusion) by their index in the SRV heap
  ([below](#bindless-textures)). Unused maps get neutral textures (white, or a
  flat normal), so shaders never branch on missing textures except where a
  flag saves work.
- **Draw variants**: each mesh pass has four pipelines, for opaque, cutout,
  double-sided, and cutout double-sided materials. Cutouts run the alpha test
  in the depth-only passes; double-sided ones disable culling.
- **Batches**: each view's candidate draws become indirect draw calls
  ([below](#instanced-batching)), which the GPU fills in as it culls
  ([below](#gpu-culling)).
- **Frame constants** (`FrameConstants`, one 256-byte-aligned block): camera
  matrices (jittered for TAA, and unjittered for motion vectors, this frame
  and last), the sun, environment and ambient settings, shadow matrices and
  cascade data, SSAO, SSR, light-cluster and fog settings, and the debug view
  flags.
- **Lights**: the point and spot lights in view, written straight into this
  frame's slice of the light buffer (see [Clustered
  lighting](lighting.md#clustered-lighting)).

### Instanced batching

Draws that could be drawn by the same draw call go out as one instanced call.
Two draws batch when they share the same mesh and submesh index range and the
same pipeline variant. Everything else can differ: transforms, material values
(tint, roughness, and so on), and textures, which are bindless. Copies of a
model, the repeated parts of a glTF node tree, and different objects that use
the same mesh (the cube, say) all become one call.

The CPU batches every draw a view *might* draw, before knowing which are in
view (`renderer_batch_draws` and `renderer_add_view_batches` in
`src/renderer_frame_data.odin`):

1. **Candidates.** The camera gets every opaque and cutout draw, plus every
   blended one; each shadow view with a light this frame gets every draw that
   casts shadows.
2. **Grouping.** Candidates are sorted by variant, then submesh, so pipelines
   change rarely, and each run that batches together becomes one call. The
   grouping is done once for the camera and once for all shadow views, which
   share it.
3. **Calls.** Each view gets its own copy of the calls. Each call is an
   `IndirectDraw` in this frame's indirect call buffer: the mesh's vertex
   and index buffer views, a root constant (`instance_base`) with the call's
   start in the **instance list**, and the indexed draw's arguments, with an
   instance count of zero. The call has room in the instance list for all its
   candidates. The camera's opaque draws get two copies, early and late
   ([occlusion culling](#occlusion-culling)).

The GPU then culls ([below](#gpu-culling)), which fills in each call's
instances. A pass draws its calls with `ExecuteIndirect`, one per run of the
same pipeline variant (`renderer_draw_batches`). The command signature
(`draw_command_signature`) sets the vertex buffer, index buffer and root
constant per call, so one `ExecuteIndirect` covers calls of different meshes.

The vertex shader finds its object as
`g_objects[g_instance_draws[instance_base + SV_InstanceID]]` and passes the
index to the pixel shader as a `nointerpolation` value. That way the pixel
shader reads the same object's material values and textures. The prepass and
the lit pass use the same calls.

Blended draws are not merged, because they must stay in back-to-front order:
the CPU sorts all of them by distance to their center, in view or not, and
each is its own call of at most one instance.

The Profiler panel's **Draw calls** count is the camera's calls that drew something,
per pass (early and late together), next to the visible draws, and the
shadow line shows its draws and calls. With 40 extra cubes in the default scene, the 46 draws take 2 calls per
pass: every cube-shaped object (portrait cubes, the stone ground, the light
markers), then the pyramid. The 214 shadow draws take 21 calls. Sponza gains
little, because its submeshes are different index ranges.

Within a call, instances land in whatever order the cull pass's threads
reach them, not in entity order. Where two surfaces have exactly the same
depth (overlapping leaves in Sponza), the one drawn last wins the
`LESS_EQUAL` test, so which one shows can change from frame to frame.

### GPU culling

Every draw has a world-space bounding box: the mesh's local box under the
entity's transform, kept as a center and three half axes so rotation does not
inflate it. A box is tested against the six planes of a view's frustum and
rejected only if it lies entirely outside one plane. The camera, each sun
cascade, each spot shadow slot, and each point shadow cube face cull
separately, so shadow passes draw only their own casters.

The test runs on the GPU, in a compute pass before the shadow pass
(`renderer_cull_draws`, `shaders/cull.hlsl`), except for what the camera
tests after the prepass's early draws ([below](#occlusion-culling)). The
CPU writes three things per frame:

- **Bounds**: each draw's box. Draws without bounds get huge boxes, so they
  pass every test.
- **View planes**: the six planes of all 33 views (the camera, then the 32
  shadow views), in `CullConstants`.
- **Cull entries**: one per candidate of each view's calls, naming the draw,
  its call, and the view.

The pass copies the calls into a GPU buffer and runs one thread per entry.
A thread whose box is in view adds one to its call's instance count with an
atomic add. The count before the add is its place in the call's part of the
instance list, so it writes its draw index there. Calls with no visible
draws keep zero instances and draw nothing. The buffer then serves as
`ExecuteIndirect`'s argument buffer, and the instance list as the vertex
shaders' `g_instance_draws`.

The CPU never learns what is visible. The pass also counts visible draws and
calls that drew something, for the camera and for the shadow views, and the
camera's draws hidden by occlusion culling, at the start of the call buffer.
These counts are copied to a readback buffer and shown in the Profiler panel
two frames late. Frustum culling can be turned off in Renderer controls to
compare; the
cull pass then keeps every candidate.

Limits: 32,768 calls per frame (`MAX_DRAW_CALLS`). A view whose calls do not
fit is skipped that frame, as are draws past `MAX_DRAWS`; the Profiler panel
then shows a warning. Point and spot lights are still culled on the CPU
(their range against the camera), since the light list is built there.

### Occlusion culling

The camera also skips draws hidden behind others, using the depth the prepass
has already written. It needs depth before deciding what to draw, so its
draws are split in two phases around a **depth pyramid** (Hi-Z):

1. **Early.** The first cull pass gives the camera's early calls the draws
   in its frustum that it saw last frame (a per-draw flag in
   `visibility_buffer`, kept across frames). The prepass draws them.
2. **Pyramid.** A compute pass builds the depth pyramid from that depth
   (`renderer_build_hiz`, `CSBuildHiZ`). Level 0 is the power of two at or
   below the window size in each direction, so each of its texels covers up
   to three depth texels each way. Each further level halves it, down to
   one texel. Every texel holds the farthest depth of what it covers.
3. **Late.** A second cull pass (`renderer_cull_late`) tests every draw in
   the camera's frustum against the pyramid. It projects the box's corners,
   takes their nearest depth and the screen rectangle they cover, and picks
   the level where that rectangle spans at most two texels each way. The
   draw is hidden if its nearest depth is farther than the farthest depth of
   those texels. The result becomes the draw's flag for next frame. Visible
   draws not drawn early go into the late calls, which the prepass draws
   next. Blended draws, which write no depth, are only culled here, into
   their own calls.

The lit pass then draws the early and late calls. Every visible draw is
drawn in one phase or the other, so nothing pops in a frame late, even when
the camera jumps. The early depth holds only real surfaces, so it can
never hide a visible draw. A wrong guess from last frame only costs work:
a draw that is no longer visible is still drawn early, and a draw that
just came into view waits for the late phase.

The test is conservative. It works on boxes rather than meshes, adds one
top-level texel of margin for TAA's jitter, and never hides a box reaching
behind the camera. Shadow views test only their frustums. On the first frame,
and for a draw newly added, there are no flags yet, so everything is drawn
late.

Occlusion culling can be turned off in Renderer controls. Every draw in the frustum
is then drawn early, and the pyramid is not built. Its GPU timing row covers
the pyramid and the late cull, and the depth prepass row includes them too.
With a wall in front of the 40-cube scene, 34 of its 47 draws are culled as
hidden.

### Bindless textures

Shaders see the entire SRV heap as one array, `g_textures[]`, through one
descriptor table (root slot `Textures`) bound at the heap's start. Every
texture's SRV is written into the heap once, when it is loaded or imported,
at the index it keeps (`GpuTexture.srv_index`). Each object stores the
indices of its six material textures. Shaders read them through
`NonUniformResourceIndex`, because the instances of one call can use different
textures, so the index can differ within a wave.

- **Nothing is copied per draw.** There is no per-frame material table ring,
  and no CPU-only staging heap to copy from.
- **Batching ignores textures.** Draws batch on geometry and variant alone.
- **The array is unbounded.** FXC needs
  `ENABLE_UNBOUNDED_DESCRIPTOR_TABLES` for that, so every shader is compiled
  with it.
- **Hardware support:** feature level 12_0, which the renderer already
  requires, guarantees resource binding tier 2. That tier allows a table over
  the whole heap with slots the shader never reads left unwritten.

The heap holds 65,536 descriptors, render targets and environment maps
included. The rest is room for textures, and importing reports when it is
full.

## Depth prepass

Opaque and cutout surfaces are drawn once without lighting before anything
else. The lit pass then tests against this depth without writing it, so each
pixel is shaded once, and SSAO and SSR have depth to read. The vertex shaders
of the two passes share one function, so both produce bit-identical depth:
opaque surfaces use a `LESS_EQUAL` test, and cutouts use `EQUAL` so the lit
pass does not repeat the alpha test.

The prepass draws in two halves, the camera's early and late calls. Between
them, the depth buffer is briefly readable by compute for the depth pyramid
and the late cull ([occlusion culling](#occlusion-culling)).

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

Blended surfaces are not in the prepass: they write no depth, so SSAO and SSR
see what is behind them. They write their own motion vectors later, in the lit
pass, where they are mostly opaque ([TAA](post_processing.md#taa)).

## Root signature

One root signature serves every graphics pass. Passes bind by slot name
(`Root_Slot` in `src/renderer.odin`), and `ROOT_LAYOUT` is the only place that
assigns registers:

| Slot | Register | Contents |
| --- | --- | --- |
| Draw constants | b0 | Root constant: the draw call's first instance-list entry |
| Post / Sky / Prefilter constants | b1, b2, b3 | Per-pass constants |
| Frame constants | b4 | Camera, lights, shadows, effect settings |
| Shadow view | b5 | Root constant: the cascade, spot slot or point face being drawn |
| Texture T0, T1 | t0, t1 | Main inputs of full-screen passes; t1 is the sun's shadow cascades in the lit pass |
| Environment, Irradiance, Prefiltered | t2, t3, t4 | Panorama and IBL maps |
| Spot shadows, Point shadows | t5, t6 | Shadow map arrays |
| Surface | t7 | Prepass normal and roughness |
| Texture T8, Depth | t8, t9 | AO or motion vectors; scene depth |
| Textures | t22 onwards | The whole SRV heap, the bindless texture array |
| Exposure buffer | t16 | Root SRV, the automatic exposure |
| Reflections | t17 | SSR result |
| Lights, Cluster lights | t18, t19 | Root SRVs, the light buffer and cluster lists |
| Objects, Instance draws | t20, t21 | Root SRVs, this frame's object data and the instance lists the cull pass wrote |

Static samplers: linear wrap (s0), shadow comparison with a white border (s1),
16× anisotropic for materials (s2), panoramas wrapping horizontally but
clamped at the poles (s3), and clamp-to-edge for screen-space lookups (s4).

Compute passes (GPU culling, auto exposure, light clusters, fog) have their
own small root signatures, and so do the selection outline and debug lines,
which share one. The indirect draws' command signature is built against the
main root signature, because each call sets the `Draw constants` root
constant.

## GPU timings

Every pass is bracketed by a pair of timestamp queries, resolved into a
readback buffer at the end of the frame and read when that frame slot comes
around again. A pass that is switched off still records its two timestamps,
so every pass has a value each frame (zero when skipped). The **GPU timings**
table in the Profiler panel lists them; "Post + UI" includes tone mapping and
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
- **Includes**: shaders share code through `#include "common.hlsl"` (the
  panorama mapping and PI), which the compiler finds next to the including
  file. `common.hlsl` is never compiled on its own.
- **Re-bakes**: the image-based lighting maps are baked once, so editing
  `irradiance.hlsl`, `environment_prefilter.hlsl` or `common.hlsl` also
  re-bakes them. **Reload shaders** forces a full reload including that
  re-bake.

Changes outside the shaders, such as a new constant-buffer field or root slot,
need the program rebuilt.

## Resizing

On resize, the renderer waits for the GPU, releases and recreates the swap
chain buffers, depth, and every screen-sized target (HDR, LDR, bloom chain,
SSAO, TAA history and motion vectors, SSR surface and reflection targets, the
depth pyramid), and
rewrites their descriptors in place. TAA and SSR restart: their history from
the old size is discarded.
