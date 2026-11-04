# Editor

## Scenes and entities

A scene (`src/scene.odin`) is a fixed set of up to 1024 entity slots. Each
component type is an array indexed by entity, with a matching `has_…` flag:
transform, mesh renderer (a model handle), material slots, point light, spot
light, reflection probe, irradiance volume, directional light, and camera. An entity is just its index, plus an
`alive` flag and a name. Deleted slots are reused by later entities.

- **Transform**: position, Euler rotation, and per-axis scale (positive on
  every axis, which keeps winding, culling and picking consistent), relative
  to the entity's parent if it has one ([Hierarchy](hierarchy.md)). A rotation
  speed spins the entity around Y, for the demo scene.
- **Materials**: slot 0 is stored with the entity; models with several
  material slots keep the rest alongside it.
- **Lights**: point lights have color, intensity, range, shadow casting, and an
  optional orbit; spot lights add the inner and outer cone angles. There is
  exactly one directional light (the sun), and exactly one camera.
- **Reflection probes** have a blend distance and box projection; their box
  is the entity's transform ([below](#reflection-probes)).
- **Irradiance volumes** have a cell count along each axis and a blend
  distance; their box is the entity's transform too
  ([below](#irradiance-volumes)).

The default scene, built in code at startup, has three objects on a stone
ground, the sun, two orbiting point lights, and the camera.

## UI

The UI is Dear ImGui, vendored with its official DX12 and Win32 backends. The
Odin code talks to it through a small C interface (`vendor/imgui/bridge.cpp`)
instead of generated bindings; `src/debug_ui.odin` declares it and builds the
panels. The UI has its own shader-visible descriptor heap for ImGui's font
textures and draws onto the back buffer after tone mapping and anti-aliasing,
so text stays sharp.

- **Renderer controls**: shader reload status, exposure, bloom, tone mapping,
  anti-aliasing, the environment, shadows (with **Ray-traced sun shadows**
  and **Sun size** on GPUs with DXR 1.1), GTAO, reflections (ray-traced on
  GPUs with DXR 1.1, otherwise SSR), reflection probes,
  irradiance volumes (with **Show diffuse ambient light only**), light
  clusters, fog, and the frustum, occlusion and meshlet culling switches. **Show ImGui demo** opens
  ImGui's own demo window.
- **Profiler**: frame rate and frame time, the camera's and shadow views'
  draws and calls after culling (with how many were occluded), the camera's
  meshlets and triangles drawn out of those its large meshes hold, the shadow
  atlas (lights holding tiles, how full it is, light views drawn this frame),
  the point and spot lights in view, a warning when a frame had more draws than fit, and
  the [GPU timings](frame.md#gpu-timings) of every pass.
- **Scene**: add models (a glTF model with several nodes as its node tree,
  see [Hierarchy](hierarchy.md#gltf-node-trees)), lights and reflection
  probes, irradiance volumes, undo and redo,
  duplicate, delete, focus, open, save and save as
  ([Scene files](#scene-files)), and the entity tree (drag a row
  onto another to parent it).
- **Inspector**: the primary selected entity's parent, transform, material
  slot, light or probe settings, and the gizmo's options.
- **Assets...**: import and remove models and textures ([Assets](assets.md)).

Panel positions and sizes are saved in `imgui.ini` in the working directory
(ignored by git) and restored on the next run; deleting the file brings back
the default layout. The window title shows the frame rate and the values keys
1–6 adjust.

Color pickers show colors gamma-encoded (a 2.2 power, close to sRGB), so the
swatch and the numbers look like the result on screen; the scene stores and
renders them as linear values.

The window opens with a 1920×1080 drawing area, shrunk to fit the screen's
work area (a 1080p screen minus the taskbar is smaller), and centered.

## Camera and shortcuts

The camera is a fly camera: 45° vertical field of view, near plane 0.1, far
plane at least 100.

| Input | Action |
| --- | --- |
| **L** | Capture or release the mouse |
| Mouse (captured) | Look around |
| **W A S D** (captured) | Move |
| **Space / Shift** (captured) | Move up / down |
| **F1** | Hide or show the panels |
| **1–6** | Exposure (or auto-exposure compensation), bloom threshold, bloom strength |
| **W / E / R** (released) | Gizmo: move, rotate, scale |
| **Q** (released) | Gizmo: world or local axes |
| **Ctrl+A** (released) | Select every listed entity |
| **Esc** | Quit (asking about [unsaved changes](#scene-files)) |

While the mouse is captured, ImGui gets no mouse or keyboard input. Keys typed
into a UI control do not trigger the shortcuts.

## Picking and selection

With the mouse released, clicking in the viewport selects what is under the
cursor (`src/editor_picking.odin`):

1. The click becomes a ray from the camera through the pixel.
2. For each model entity, the ray is moved into the entity's local space
   (through the inverse of its world matrix, parents included) and
   tested against every triangle (Möller–Trumbore), keeping the nearest hit.
3. Cutout materials are tested at the hit's texture coordinate against the
   full-size albedo alpha kept for picking, so clicks go through holes. Back
   faces count only on double-sided materials. Blended surfaces such as glass
   are picked like any other.

Clicking empty background clears the selection.

**Icons** come first. Entities with nothing to draw have an icon instead
([Viewport icons and debug lines](#viewport-icons-and-debug-lines)), and a
click within 13 pixels of one picks it before any mesh, since the icon is
drawn over the scene. Several icons under the cursor go nearest first.

**Cycling**: picking collects every icon under the cursor and every entity
the ray hits, sorted by its nearest hit. A plain click within 4 pixels of the last plain click, while the
selection is still just what that click picked, selects the next entity
behind it instead, wrapping back to the nearest after the farthest. This
reaches objects inside or behind others. Moving away, a Ctrl or Shift click,
or any other change to the selection starts again from the nearest.

The shader filters alpha and
adjusts it per mip level while picking reads the nearest full-size texel, so at
cutout edges the two can differ by a texel.

### Selecting several

The selection is a set of entities (`g_editor_selection` in `src/editor.odin`)
plus a *primary* one (`g_editor_selected`), the most recently added. The
Inspector shows the primary, and the gizmo sits on it.

| Input | In the viewport | In the entity list |
| --- | --- | --- |
| Click | Select only this (empty background: nothing); again at the same spot: the next one behind | Select only this |
| **Ctrl**+click | Add, or remove if already selected | Add or remove |
| **Shift**+click | Add | Select the rows from the last plain or Ctrl click |
| **Ctrl+A** (mouse released) | Select everything in the list | |

Removing the primary makes the first remaining selected entity primary.

- **Inspector**: fields edit the primary only; with several selected it says
  so.
- **Gizmo**: the rest of the selection follows the primary. Move adds the
  same offset to all. Rotate turns all of them by the same rotation: the
  others orbit the primary's position and also turn about their own origins.
  Scale multiplies every entity's own scale by the same factors, and moves
  the others away from (or towards) the primary along the gizmo's axes.
  Orbiting lights follow by moving their orbit center. The sun and camera do
  not follow, and a selected child of another selected entity moves only with
  its parent.
- **Duplicate Selected** copies every selected model and light, with its
  children, and selects the copies; **Delete Selected** deletes them and their
  children. The sun and camera are skipped, and stay selected after a delete.
- **Undo**: a gizmo drag, a duplicate or a delete on several entities is one
  undo step (`Edit_Fields` or `Group` in `src/editor_history.odin`). Undo and
  redo select what the step touched again. A group is all or nothing: if one
  part cannot be redone (a light past the limit), the parts already done are
  reverted.

**Outline**: the selection is outlined in groups. Each selected entity with no
selected ancestor makes one group, together with all of its descendants, and
each group gets one 2-pixel outline around its whole silhouette. Selecting a
model's top entity therefore outlines the model as one shape, not each part
of it; selecting one part outlines just that part (and its own children).
The primary selection's group is orange, the others darker.
`src/renderer_selection.odin` draws it in two passes after anti-aliasing:

1. **Mask**: every mesh of each group is drawn into a screen-sized integer
   target (`R16_UINT`) as the group's id: 1 for the primary's group, then 2,
   3 and so on. There is no depth test and no culling, so the mask is each
   group's full silhouette, hidden parts included.
2. **Outline**: a full-screen pass over the back buffer colors each pixel
   within two pixels (a round brush) of a group it is not part of. Meshes in
   one group share its id, so the edges between them do not show; two
   selected groups that touch both show their edge. Outlines stay visible
   through objects in front.

The mask ignores cutout alpha, so a cutout surface is outlined along its
triangles rather than its holes.

**Focus Selected** keeps the camera's direction
and moves it back until a sphere around everything selected fits in the view,
with a little margin; the far plane grows if needed. The sphere is centered
on the box around each entity's own bounding sphere, so it is close to, but
not always, the smallest one.

## Viewport icons and debug lines

Four checkboxes in the Scene panel control them (`src/editor_viewport.odin`).
Neither shows while the UI is hidden (F1).

**Icons for entities without a mesh** (on by default): every placed entity
that draws nothing gets a 10-pixel icon at its world position. These are
empty entities, reflection probes, irradiance volumes, and lights whose
marker mesh was removed;
the camera gets none. The icons make such entities clickable in the
viewport.

- A **point light** is a disc in the light's color with eight rays.
- A **spot light** is the same disc, with three rays fanning along its beam's
  direction on screen.
- A **reflection probe** is a light blue ball with a highlight.
- An **irradiance volume** is a light orange ring around a 3 × 3 grid of
  dots.
- An **empty entity** is a diamond.
- A selected icon gets a ring, orange for the primary and darker for the
  others.

Icons are drawn on ImGui's background list, the same as the gizmo: under the
panels, over the scene, and under the gizmo. Nearer icons cover farther ones.
Icons behind the camera or past the far plane are not drawn.

**Debug lines** are world-space lines that the renderer draws after
anti-aliasing, before the selection outline (`renderer_render_debug_lines`
in `src/renderer_selection.odin`). They show:

- **Light ranges**, for the selected lights, or for every light with **Ranges
  of all lights** (the unselected ones fainter). A point light's range is
  three circles in the axis planes plus the sphere's outline as the camera
  sees it. A spot light's cone is the circle where the outer angle meets the
  range, four edges from the light to that circle, and a fainter circle for
  the inner angle. Lines use the light's color at full brightness.
- **Orbits**: an orbiting point light's circle, in its parent's space.
- **Probe and volume boxes**, for the selected reflection probes and
  irradiance volumes, or for all of them with **Boxes of all probes and
  volumes**: probes in light blue, volumes in light orange. A selected
  volume also shows a small cross at each cell's center (up to 4096 cells).
- **Mesh bounds**, with **Mesh bounds** checked: each drawn mesh's local
  bounding box, placed by its world matrix, which is the box that culling
  uses.

The editor builds the line list on the CPU each frame, and it goes into this
frame slot's part of an upload buffer. That buffer holds up to 65,536 lines,
and any more are dropped. Two pipelines draw the lines, both tested against
the prepass depth without writing it:

1. **Hidden parts**: `GREATER`, at a quarter of the line's alpha.
2. **Visible parts**: `LESS_EQUAL`, at full alpha.

As a result, lines show faintly through what is in front of them. Before the
depth test, each vertex is pulled 0.2% of its distance towards the camera.
Without this, a line lying on a surface (a box around a cube) would flicker
against TAA's jittered depth.

## Gizmos

The gizmo (`src/editor_gizmo.odin`) draws handles on the primary selected
entity, and a click on a handle starts a drag instead of changing the
selection. The rest of the selection follows ([Selecting
several](#selecting-several)).

- **Move** (W): drag an arrow to move along that axis (the closest point
  between the axis and the mouse ray), or the center square to move in the
  view plane.
- **Rotate** (E): drag a ring to rotate around that axis.
- **Scale** (R): drag an axis to scale along it, or the center square for
  uniform scale (×e per 100 pixels of horizontal drag). Scale always uses the
  entity's local axes: scale applies before rotation, so scaling along world
  axes would shear.
- **Space** (Q): move and rotate along world or local axes. Local axes
  include the parents' rotation, and drags of children work in world space
  ([Hierarchy](hierarchy.md#editing)).
- **Snap**: drags move, rotate and scale in whole steps counted from where the
  drag started (defaults: 0.25 units, 15°, 0.1, or 10% for uniform scale).
  Holding **Ctrl** during a drag flips snapping.
- An axis pointing almost straight at the camera is hidden, since it cannot be
  dragged usefully. Right-click during a drag cancels it. Each drag is one undo
  step.
- Moving an orbiting point light moves its orbit's center; the handles stay on
  the light.

## Undo and redo

Every change made in the editor is a command in a history of up to 128 steps
(`src/editor_history.odin`); older steps are dropped.

- **Field edits** record the field (position, a material value, a light
  setting, an asset reference, and so on), its value before, and after. A
  slider drag or a typed edit becomes a single step: the edit opens when the
  widget activates and closes when it deactivates, or when a different field
  starts changing. Dropdowns commit at once.
- **Material fields** record which material slot was edited; undo and redo
  select that slot again before applying.
- **Creating, duplicating and deleting** entities record a snapshot of the
  entity, so undo can remove or restore it.
- An edit after an undo starts a new branch and discards the redo steps.
- Removing an asset clears the history, since an old step could bring back an
  entity that uses the asset.

## Lights

**Add Point Light** and **Add Spot Light** place a white light three units in
front of the camera, with its marker. See [Lighting](lighting.md) for how lights
shade and cast shadows.

- **Range**: how far a light reaches; its falloff reaches zero exactly there.
- **Spot angles**: half-angles up to 89°; the inner angle stays within the
  outer one.
- **Orbit** (point lights): the light circles its **Orbit center**
  horizontally at **Orbit radius**, and the center's y is the orbit's height.
  Turning orbit on sets the center so the light stays where it is. A
  duplicated orbiting light starts 45° further along.
- **Cast shadows**: the light gets tiles in the shadow atlas, sized by how
  large it looks on screen ([Lighting](lighting.md#spot-and-point-lights-the-shadow-atlas)).
  The Inspector shows the tile size, or why the light has none.
- A scene can have up to 1024 point and spot lights together. Adding,
  duplicating, or undoing past that is refused with a note. The sun cannot be
  deleted.

## Reflection probes

**Add Reflection Probe** places a probe three units in front of the camera,
with an 8 × 4 × 8 box. See [Lighting](lighting.md#reflection-probes) for
how probes capture and shade.

- **Placing**: move the probe to where reflections should be seen from
  (usually the middle of a room), and scale it so the box matches the room:
  Scale is the box's size in each axis. Surfaces outside every box keep the
  environment's reflections, so a box that misses a model's far walls leaves
  them reflecting the sky.
- **Fit box to selected models**: select the models, then Ctrl+click the
  probe last (the Inspector shows the last one clicked). The button sets the
  probe's box around their meshes and their descendants' (in its parent's
  space, unrotated, 0.1 units larger on each side) as one undo step.
- **Blend distance**: how far inside its faces the probe fades in, so
  neighbouring or nested boxes blend instead of meeting at a seam.
- **Box projection** (on by default): reflections line up with the room's
  walls; turn it off for probes in open spaces.
- **Capturing**: a probe captures when added or moved, and every probe
  captures after the environment changes or a scene loads. After moving
  lights or models, use **Capture again** (Inspector) or **Capture all
  probes again** (Renderer controls). The Inspector shows whether the probe
  has been captured.
- **Limits**: up to 16 probes are used. Any more are ignored, and their
  Inspector says so.

## Irradiance volumes

**Add Irradiance Volume** places a volume centered three units in front of
the camera, with an 8 × 4 × 8 box and a cell every unit. See
[Lighting](lighting.md#irradiance-volumes) for how volumes capture and
shade.

- **Placing**: scale the box to cover the space whose diffuse light it should
  hold, such as a room or a building. Cells fill the box evenly, so scaling
  it spreads them further apart. **Fit box to selected models** works as for
  [reflection probes](#reflection-probes).
- **Cells along X, Y and Z** (1 to 32 each): more cells follow the light more
  closely, but each takes a frame to capture. About one cell per meter suits
  rooms. Changing them starts the volume over.
- **Blend distance**: how far inside its faces the volume fades in.
- **Capturing**: a volume captures when added, moved or resized, and again
  after the environment changes or a scene loads. The Inspector shows the
  bounce and cell being captured, then "Captured". After changing lights or
  models, use **Capture volume again**, or **Capture all volumes again** in
  Renderer controls, which also has **Volume bounces** (1 to 8, default 2;
  raising it continues from the passes already made).
- **Limits**: up to 4 volumes are used. Any more are ignored, and their
  Inspector says so.

## Scene files

A scene file (`src/scene_file.odin`) holds every live entity with its
components, plus the renderer settings (post-processing, environment, shadows,
ambient occlusion, SSR, reflection probes, irradiance volumes, fog, auto
exposure). Assets are
referenced by catalog ID, so a scene file can live in any folder.

The Scene panel's file buttons:

- **Open...** picks a `.json` scene file in the Windows file dialog and loads
  it. That clears undo history and the selection.
- **Save** writes the scene to the file it came from. If it was never saved
  (the startup scene is **Untitled**), Save works like Save As.
- **Save As...** picks a file to save to, suggesting `scene.json` for an
  untitled scene, and asks before overwriting. The scene then belongs to that
  file.

The panel shows the file's name and full path, and "(unsaved changes)" when
the scene differs from that file. The window title shows the name too, with
a `*` for unsaved changes. Both dialogs start in the current file's folder,
or in the working directory. The working directory itself never changes,
since the catalog and assets are relative to it.

**Unsaved changes.** Opening another scene, Esc, or closing the window asks
"Save changes to …?" when there is anything to save:

- **Yes** saves first (asking for a file if the scene is untitled), and goes
  on only if the save worked.
- **No** discards the changes.
- **Cancel** keeps the scene open.

A scene has unsaved changes when what a save would write differs from what
was last saved or opened. Changes that happen by themselves are left out:
the camera flying around, objects spinning, and lights orbiting. Undoing
back to how the file has it counts as no change. The check compares the
values as raw bytes (`scene_file_snapshot`) rather than encoding JSON. That
takes about 0.02 ms, against about 13 ms of JSON for a scene with 40 copies
of Sponza, so the panel can check four times a second.

- **Validation**: a file is checked completely before anything changes. Every
  referenced asset must exist and suit its use (an albedo texture where an
  albedo is expected, and so on), values must be in range, and there must be
  one sun, one camera, and at most 1024 lights. Then the scene is replaced, and
  its names are kept in their own arena. The renderer's histories (last
  frame's model matrices, and the TAA, SSR and fog histories) are dropped, as
  entity slots now hold other entities and the old images show the old scene.
- **Parents** are saved as positions in the file's entity list, and loading
  rejects cycles ([Hierarchy](hierarchy.md#scene-files)).
- **Versions**: the format is at version 18. Newer settings are optional
  sections or fields, and a file without one gets a default. Where a feature
  changed how existing scenes look, the default keeps the old look: Reinhard
  tone mapping, FXAA, no sharpening, auto exposure off, no volumetric fog,
  light ranges matching the old falloff, and orbits around the origin. Older
  lights load with shadows on. Versions 1–5, which stored the component arrays
  directly, are converted on load.
