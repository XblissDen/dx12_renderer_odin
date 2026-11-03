# Lighting

All lighting happens in one forward pass (`ShadeSurface` in
`shaders/scene.hlsl`): each pixel of each surface sums the sun, the point and
spot lights reaching its cluster, the environment's diffuse and specular
light (or a reflection probe's, and diffuse light from an irradiance
volume), and emission. The result goes to the HDR target in linear units;
exposure and tone mapping come later ([Post-processing](post_processing.md)).

## Surface shading

The model is the common metallic-roughness PBR model:

- **Direct light**: a Cook-Torrance specular term with the GGX distribution,
  Smith-Schlick geometry (k = (roughness + 1)² / 8) and Schlick's Fresnel,
  plus a Lambert diffuse term scaled by (1 − F)(1 − metallic). F0 is 0.04 for
  dielectrics and the albedo for metals.
- **Ambient light**: the environment's diffuse light (irradiance) times the
  albedo, plus its specular light (the prefiltered environment) times the
  split-sum BRDF. The BRDF's scale and bias come from Karis' analytic
  approximation (`EnvBRDFApprox`), so there is no lookup texture.
- **Occlusion**: ambient occlusion (GTAO times the material's occlusion map)
  darkens only ambient light; the sun and local lights have shadows instead.
  Reflections fade with occlusion through Lagarde's specular occlusion: less at
  grazing angles and on smooth surfaces.
- **Emission** is added after lighting and is neither lit nor shadowed; bloom
  picks up its bright parts.
- **Unlit** materials (the light markers) output their tint times 4.

### Materials

A material has a base color (texture times tint), a normal map with a
strength, roughness and metallic values each optionally multiplied by a map
(red channel), emission (color times strength, times an optional sRGB map),
an occlusion map with a strength, an alpha mode (opaque, cutout, or blend),
double-sidedness, and a UV scale. See [Assets](assets.md#materials) for how
glTF materials map onto this.

- **Normal maps**: the tangent basis is rebuilt per pixel from the
  interpolated normal and tangent (Gram-Schmidt), with the tangent's w giving
  the bitangent's sign. Only the map's x and y are read (BC5 compression
  stores nothing else); z is rebuilt as `sqrt(1 - x² - y²)`. Then x and y
  are scaled by the normal strength.
- **Double-sided** surfaces seen from behind flip the whole basis, so back
  faces are lit from their own side.
- **Specular anti-aliasing**: normal-map detail smaller than a pixel would
  sparkle as isolated highlights. The variance of the shading normal across
  the pixel (from its screen-space derivatives) widens the GGX lobe instead,
  capped so smooth surfaces stay glossy. The prepass computes the same
  roughness for SSR.
- **Cutouts** discard pixels whose albedo alpha is below the cutoff, in the
  prepass and shadow passes; the alpha is scaled up with the mip level (Ben
  Golus' method) so thin cutouts keep their coverage in the distance.
- **Blended** surfaces are drawn after all opaque ones, with alpha = albedo
  alpha × opacity, order-independently ([below](#blended-surfaces)). They
  skip GTAO and SSR, which come from the opaque surface behind them.

### Blended surfaces

Ordinary alpha blending needs surfaces drawn back to front. Sorting whole
objects by their centers gets crossing or interlocking glass wrong, and
nothing can sort the triangles within one mesh. Blended surfaces therefore use
**weighted blended order-independent transparency** (McGuire and Bavoil,
2013), in which the result does not depend on the order at all:

1. **Accumulate**: each blended pixel adds its premultiplied color and its
   alpha, times a weight, into an accumulation target (`R32G32B32A32_FLOAT`,
   cleared to 0). It also multiplies a revealage target (`R16_FLOAT`,
   cleared to 1) by 1 − alpha, leaving how much of the opaque image still
   shows through. Both are sums and products, so order does not matter.
2. **Weight**: alpha × clamp(10 / (10⁻⁵ + (d/10)³ + (d/200)⁶), 0.01, 3000),
   with d the view depth, one of the paper's suggested weights. It falls with
   the cube of the distance, so a surface 25% nearer counts about twice as
   much, and the front pane of glass reads as being in front.
3. **Composite**: a full-screen pass divides the accumulated color by the
   accumulated alpha (the weighted average color) and lays it over the lit
   image: average × (1 − revealage) + scene × revealage. Pixels with no blended
   surface are skipped.

The coverage (how much of the background shows) is exact. The color is an
average, so where two surfaces of similar distance overlap, each tints the
other's area about equally instead of the front one covering the back one.
That is the method's trade-off for not sorting. The accumulation is 32-bit,
because weights up to 3000 times bright HDR highlights would overflow half
floats.

Double-sided blended surfaces draw both faces in one draw. Blended draws are
still sorted back to front, but only so that the nearest mostly-opaque
surface writes the motion vector TAA follows
([Frame structure](frame.md#instanced-batching)).

## The sun

There is always exactly one directional light. Its direction, color and
intensity come from the scene's sun entity, or, with HDRI lighting and **Sun
from HDRI** on, from the sun found in the panorama ([below](#sun-from-the-hdri)).
It casts the cascaded shadows described under [Shadows](#shadows).

## Point and spot lights

- **Falloff**: inverse square, `intensity / (1 + d²)`, multiplied by the
  window `(1 − (d / range)⁴)²`. The window reaches exactly zero at the range
  and stays close to 1 well inside it (as in Unreal and Frostbite), so a light
  can be skipped beyond its range without a visible edge.
- **Spot cone**: full brightness inside the inner angle, fading to zero at the
  outer one: `saturate(cos θ × scale + offset)²`, with scale and offset
  computed on the CPU from the two angles. A spot light shines along its
  entity's local −Y axis.
- **Markers**: each light has a small unlit marker mesh in its color (a cube
  for point lights, a pyramid for spot lights). Markers cast no shadows.

## Clustered lighting

A scene can have up to 1024 point and spot lights; a pixel shades only the
few that can reach it (`src/renderer_lights.odin`).

1. **Light buffer**: each frame, the CPU tests each light's range sphere
   (as a box) against the camera frustum and writes the survivors into this
   frame's slice of an upload buffer, a `StructuredBuffer<GpuLight>`.
2. **Clusters**: the view is split into 16 × 9 screen tiles times 24 depth
   slices, 3456 clusters. Slices are spaced logarithmically from the near plane
   to the far clip, each one deeper than the last by a constant ratio, so near
   clusters stay small. A slice index is `log2(z) × scale + bias`.
3. **Cluster pass**: a compute shader runs one thread per cluster. It builds
   the cluster's view-space bounding box from its tile corners at the slice's
   near and far depth, and tests every light: its range sphere against the box,
   and for spot lights also the cluster's bounding sphere against the outer
   cone (Bart Wronski's cone test). Each cluster stores its light count and up
   to 127 light indices. Lights beyond 127 are dropped from that cluster.
4. **Shading**: the lit and blended passes find their cluster from the pixel's
   screen position and view depth and loop over its list only.

Clusters do not depend on the depth buffer, so blended surfaces use them too.
**Show light clusters** colors each pixel by its cluster's light count: black
for none, then blue (1), green (4), yellow (16), red (64), and white for a full
cluster. With 240 lights in the default scene, the lit pass takes 0.64 ms
instead of 3.5 ms looping over all of them, with the same image; the cluster
pass takes about 0.1 ms.

## Shadows

All shadow maps are rendered in one pass at the start of the frame, each view
drawing only the casters inside its own frustum. Opaque casters have no pixel
shader; cutouts and blended surfaces (where alpha ≥ 0.5) run the alpha test.

### Sun: cascaded shadow maps

- **Cascades**: the camera view out to **Shadow distance** (default 40) is
  split into four slices, each with its own 2048² map in a texture array.
  Split depths are 80% logarithmic and 20% uniform (the "practical" scheme),
  which matches how perspective shrinks texels with distance.
- **Fitting**: each cascade's orthographic volume is a bounding sphere of its
  slice of the view, so its size does not change as the camera turns. Its
  center snaps to whole shadow-map texels, so shadow edges do not shimmer when
  the camera moves. The near plane is pulled back towards the sun to include
  casters outside the sphere.
- **Lookup**: a pixel uses the first cascade whose slice contains it, and
  cross-fades into the next over the last 10% of each slice. Shadows fade out
  over the last 15% of the shadow distance.
- **Bias**: the lookup starts one texel off the surface along its geometric
  normal, then subtracts a depth bias of **Shadow bias** plus **Shadow slope
  bias** times the surface's slope towards the sun, both in texels of that
  cascade.
- **Filtering**: a 5 × 5 tent filter from nine bilinear comparison taps
  (Ignacio Castaño's optimized PCF), giving smooth edges without 25 samples.
- **Show shadow cascades** tints receivers red, green, blue and yellow by
  cascade.

### Spot and point lights: the shadow atlas

Spot and point light shadows share one 4096² depth atlas
(`src/renderer_shadow.odin`). Every shadow-casting light whose range reaches
the view gets square tiles in it, so any number of lights can cast shadows, up
to what fits (and 64 lights).

- **Views**: a spot light has one tile, a perspective view whose field of
  view is the outer cone and whose far plane is the range. A point light has
  six, its cube faces in D3D's order (+X, −X, +Y, −Y, +Z, −Z). Each face is
  drawn three texels wider than 90° on every side, so filtering near a face's
  edge never reads a neighbouring tile.
- **Sizes**: a tile's size follows how large the light's range looks on
  screen, as a power of two: 128–1024 texels for spot lights, 64–512 per face
  for point lights. Nearby lights keep the previous fixed sizes (1024 and
  512). A light keeps its size until the wanted size is well off (below 35% or
  above 150% of it), so walking around does not keep resizing tiles.
- **Placement**: tiles sit on a grid of 64-texel cells, each at the first free
  aligned square. When a light does not fit but outranks one that holds
  tiles, every tile is placed again, biggest lights first; lights that still
  do not fit have no shadow. The Inspector shows a light's tile size, or why
  it has none.
- **Caching**: a tile is drawn again only when it has to: when its light
  moved or changed (its view matrices differ), or when the shadow casters
  around the light changed. That is a hash of every caster whose bounds reach
  into the light's range: placement, mesh, pipeline variant, and a cutout's
  texture and cutoff. A scene that stands still draws no light views at all.
- **Budget**: at most 28 light views are drawn per frame (as many as the four
  spot and four point slots used to take). Changed lights are taken in order of
  size on screen times frames waited, so every light gets its turn even when
  more change than fit. A light never drawn comes first, and has no shadow
  until it is drawn.
- **Lookup**: the tiles' views and atlas rectangles go to the shaders in a
  buffer (`g_shadow_tiles`), each light pointing at its first. A spot light's
  receiver goes through its tile's view. A point light's receiver picks the
  face by the direction's dominant axis, then does the same with that face's
  tile. Both look up 1.5 texels off the surface (the texel size grows with
  distance from the light) and filter with the sun's 5 × 5 tent, kept inside the
  tile. Casters get a slope-scaled rasterizer depth bias.

The Profiler shows how many spot and point lights hold tiles, how full the
atlas is, and how many light views were drawn this frame.

## Image-based lighting and the sky

### Environment panoramas

The environment is an HDR panorama (equirectangular, 2:1). It is decoded and
given a full mip chain on the CPU (each level weights rows by their solid
angle, so the panorama's total light is preserved). The sky samples a BC6H
copy (see [Assets](assets.md#environments)); the two lighting maps are baked
from a temporary full-float copy, which keeps the sun's full radiance.
**Environment rotation** turns it around the Y axis; **IBL intensity** scales
the light it gives.

- **Irradiance** (64 × 32): for each normal direction, the cosine-weighted
  average of incoming light from 1024 Hammersley samples. Each sample reads the
  panorama at a mip level matching its share of the hemisphere, so a small,
  very bright sun cannot reveal the sample pattern.
- **Prefiltered environment** (1024 × 512, 5 levels): level n holds
  reflections for roughness n / 4. Level 0 is the panorama itself, filtered
  down to the map's size; the others average 1024 GGX importance samples,
  assuming the view direction equals the normal (the split-sum
  approximation), with the same footprint-based mip selection. The lit pass
  reads level roughness × 4.

Both maps are baked on the GPU, once per environment change. Panoramas load
only when lighting or the background needs them, and switching back to a
loaded environment reuses its maps.

### Sun from the HDRI

A panorama's sun is far too bright and small to bake well: it would make the
IBL maps noisy and could not cast shadows. When a panorama loads, its sun is
found as the region of texels brighter than 0.1% of the peak connected to the
brightest one. It counts as a sun only if it carries at least 25% of the
panorama's light from a compact area (under 0.05 sr). The light it adds above
the surrounding sky gives the sun's direction, color and intensity.

With HDRI lighting and **Sun from HDRI** on (the default), the IBL maps are
baked from a copy with those texels replaced by the surrounding sky, and the
measured sun becomes the shadowed directional light. It follows the
environment's rotation and intensity. The visible sky still shows the original
sun. Panoramas without a distinct sun keep the scene's sun.

### Ambient color mode

Instead of the panorama, lighting can come from a constant **ambient color**
times an intensity, used as both the diffuse and the specular environment, so
metals are still lit. Zero intensity leaves only the sun and local lights.

### Sky

The sky is drawn first into the HDR target, behind everything, as a
full-screen triangle with no depth. It is either the panorama, scaled by
**Background brightness**, or a solid color; the background is independent of
the lighting mode. Each pixel reads the panorama at the mip matching the angle
the pixel covers, not from UV derivatives. Derivatives go wrong where the
panorama's U wraps around and near the poles, both of which would show the
smallest mip.

## Reflection probes

The environment's light comes from infinitely far away, so indoors it is
wrong: a floor in a hall reflects the bright sky instead of the walls. A
**reflection probe** (`src/renderer_probes.odin`) captures the scene from a
point, and surfaces inside its box use that capture instead of the
environment. See [Editor](editor.md#reflection-probes) for placing them.

- **Box**: the probe entity's unit cube (−0.5 to 0.5) under its world
  matrix, so Scale sets its size and Rotation turns it. The capture is taken
  from the box's center.
- **Capture**: the lit scene is drawn into the six faces of a 256 × 256 cube
  map: the sky first, then the opaque surfaces (blended ones are left out)
  with the lit pass's shader. They get the sun with its shadows, every point
  and spot light, and the light of probes already captured, so capturing
  again adds bounces. The capture's draws go through the
  [GPU culling](frame.md#gpu-culling) as six more views.
- **What a capture lacks**: GTAO, SSR, fog and the light clusters belong to
  the camera's view, so a capture does without them and tries every light.
  The sun's cascades follow the camera too: a captured point uses the finest
  cascade that covers it and is unshadowed outside all four, so a probe far
  beyond the shadow distance from the camera can show sunlight where there is
  shadow. The sky in a capture is the environment as lighting uses it (IBL
  intensity, or the ambient color), not the visible background.
- **Filtering**: the capture gets a mip chain (2 × 2 averages, down to
  1 × 1), then is prefiltered like the environment
  (`shaders/environment_prefilter.hlsl`) into five levels for roughness 0,
  0.25 … 1. Each texel takes 128 GGX samples, each reading the mip that
  matches its footprint. The result goes to the probe's cube in an array of 16
  cubes (4.2 MB each, 67 MB in all).
- **When**: one probe per frame: a new probe, one that moved, every probe
  after the environment changes or a scene loads, and on request (**Capture
  again** in the Inspector, **Capture all probes again** in Renderer
  controls). Changing lights, models or the sun does not capture again on its
  own. A capture takes about 0.5 ms of GPU time in Sponza (the
  **Probe capture** row in the Profiler).

In the lit pass, each probe whose box holds the point gets a weight that
rises from 0 at the box's faces to 1 at **Blend distance** inside them. Its
reflection is read along the reflected ray, or, with **Box projection**,
where that ray leaves the box as seen from the box's center. That corrects the
parallax for rooms whose walls are near the box's faces. Overlapping probes
are averaged by weight, and where the weights add up to less than 1 the
environment fills the rest. SSR then replaces the result where it finds the
reflected surface. Blended surfaces use probes too.

**Probes replace the sky's diffuse light** (off by default) also swaps the
irradiance map for the probe's roughest level read along the normal, which
is close to the cosine-weighted average of the captured light. Interiors then
come out much darker, since a capture holds the sky's light after one bounce
(more with each capture again). It suits scenes with auto exposure.

## Irradiance volumes

The sky's irradiance map assumes every surface sees the whole sky, so
interiors get the sky's full blue light, and no surface gets light bounced
off the others. An **irradiance volume** (`src/renderer_probes.odin`,
`shaders/irradiance_volume.hlsl`) captures the diffuse light at a grid of
points, and surfaces inside it use that instead. It is the diffuse
counterpart of reflection probes, and stores far less per point. See
[Editor](editor.md#irradiance-volumes) for placing one.

- **Grid**: the volume entity's unit cube under its world matrix, as for
  reflection probes, divided into **cells** (8 × 4 × 8 by default, up to 32
  along each axis). Each cell holds the light around its center.
- **Capture**: one cell per frame, with the reflection probes' capture: the
  same 256 × 256 cube of the lit scene and its mip chain, without the
  prefiltering. Probes go first when both are waiting. A compute pass
  (`CSProjectCell`) then reduces the capture's 32 × 32 level to **L1
  spherical harmonics**: per color, the light's average plus one linear term
  per axis, 12 numbers per cell. A texel adds its radiance weighted by the
  solid angle it covers and the basis functions along its direction.
- **Stored ready to evaluate**: the coefficients are pre-scaled by the
  cosine lobe's convolution, so the lit pass gets the cosine-weighted
  average radiance (irradiance / π, what the irradiance map holds) along
  normal N as `constant + dot(linear, N)`.
- **Bounces**: captures shade surfaces with the volumes captured so far. The
  first pass over the cells gives light that bounced once, and each further
  pass adds another bounce. **Volume bounces** (Renderer controls, default 2)
  sets the number of passes.
- **Cost**: a cell capture takes about 0.45 ms of GPU time in Sponza (in the
  **Probe capture** row), so a volume filling Sponza (17 × 7 × 10 cells, two
  bounces, plus the cells that move, below) takes about 3,850 frames, about
  21 seconds at 180 frames a second. Using the volume costs about 0.16 ms in
  the lit pass at 1920 × 1080.

### Cells inside walls

A cell whose center is inside a wall or a closed model sees the inside of
that model, and its light would leak out to the surfaces around it. Cells
therefore capture with back faces drawn too: one-sided materials draw their
back faces black with zero alpha (`PSCaptureVolume`). The alpha averaged
over the capture is how much of the cell's view is front faces. Seeing more
than 10% back faces lowers a cell's **validity**, and at 30% it is invalid.

An invalid cell moves, as DDGI moves its probes out of geometry. The
projection also writes the cell's validity to a small buffer the CPU reads
back two frames later (`renderer_read_volume_capture`). If the cell is
invalid, it is captured again from the next of 14 offset points: 0.45 cells
along each axis, then 0.35 cells toward each corner. It keeps the first
valid one for later bounces. The atlas stores where each cell was captured
from. In Sponza about 1,470 of the 2,380 captures of the first bake are such
retries, mostly cells inside the walls, pillars and roof.

### Lookup

All volumes share one 3D texture (`VOLUME_ATLAS_*`), a 32³ block per volume.
A block has four planes: the red, green and blue coefficients, each times
the cell's validity, then the validity and the capture offset.
`ApplyIrradianceVolumes` in the lit pass:

1. Moves the lookup point 0.2 cells along the normal, so a surface reads the
   cells in front of it rather than those level with it.
2. Blends the eight cells around that point. Each cell's trilinear weight is
   scaled by its validity, and by how far it lies in front of the surface
   (DDGI's smooth back-face term, `((dot(direction to cell, N) + 1) / 2)²
   + 0.2`). Cells behind a wall then add little to the light in front of it.
3. Fades the volume out where no valid cell is near, and over **Blend
   distance** inside the box's faces. Like probes, overlapping volumes are
   averaged, and the light they leave out comes from the sky (or from
   probes, with **Probes replace the sky's diffuse light**).

The volume replaces only the diffuse ambient light. GTAO and material
occlusion still apply on top, and reflections still come from probes, the
sky and SSR. **Show diffuse ambient light only** (Renderer controls) shows
the light a white surface gets, which makes volumes easy to compare with the
sky's light.

### Limits

- **Coarse**: with cells a meter or more apart, light changes smoothly. Small
  objects get light from cells around them, not their own contact shadows;
  GTAO adds those.
- **Leaks**: the back-face term reduces light passing through walls thinner
  than a cell, but does not stop it. A volume per room, with blend distances,
  leaks less than one volume over a building.
- **Darker interiors**: rooms come out much darker than with the sky's
  light, as they should. Auto exposure suits them.
- **Sun shadows** in captures come from the camera's cascades, as for probes:
  cells far from the camera can see sunlight where there is shadow. Bake
  with the camera near the volume, or raise **Shadow distance** while it
  bakes.
- **Static**: changing lights or models does not capture again on its own.
  Use **Capture volume again** (Inspector) or **Capture all volumes again**
  (Renderer controls). Changing the environment does capture again. Moving a
  volume captures it again over its old values, and changing its cells
  starts from nothing.
- **Up to 4 volumes** are used.

## Volumetric fog

Fog that scatters light: haze in the distance, glow around lights, and shafts
where shadows cut through sunlight or a spot light's cone
(`src/renderer_fog.odin`, `CSFogInject`, `CSFogIntegrate` and `PSFogApply` in
`scene.hlsl`). It costs about 0.15 ms.

1. **Cells**: the view out to **Fog distance** (default 64) is divided into
   160 × 90 × 64 cells aligned with the screen ("froxels"), stored in 3D
   textures. Cell depth grows with the square of the slice index, so cells are
   thin near the camera and deep in the distance. The grid does not depend on
   the window size.
2. **Inject** (compute): each cell computes its density and the light it
   scatters towards the camera:
   - Density is **Fog density** (extinction per unit) at or below **Fog
     height**, falling off exponentially above it by **Fog height falloff**.
   - The sun, through its shadow cascades (one comparison per cell), and every
     point and spot light in the cell's light cluster, with their shadow maps.
     Each is weighted by the Henyey-Greenstein phase function with **Fog
     anisotropy** g. Positive g scatters forward, so fog glows towards a
     light in front of the camera.
   - Sky light, which reaches the fog evenly from every direction: the
     panorama's average radiance (computed when its maps are baked, without the
     sun when that was extracted), or the ambient color, times **Fog sky
     light**.
   - The result, scattered light times **Fog color**, is stored with the
     extinction.
3. **Temporal blend**: each frame, a cell samples at a different depth within
   itself, and the result is blended 10% into the cell's value from last frame,
   found by reprojecting the cell's center with last frame's camera. This
   averages out banding between slices, without relying on TAA. History
   restarts when fog is turned on or the fog distance changes.
4. **Integrate** (compute): each column of cells is marched front to back. Each
   cell stores the light scattered towards the camera up to its far end and the
   transmittance from the camera to there, integrated over the cell's
   thickness along the ray as in Frostbite (Hillaire, 2015).
5. **Apply**: after the lit and blended passes, a full-screen pass looks up
   each pixel's depth in the integrated volume (trilinear) and blends:
   `color × transmittance + scattered`. Sky pixels get the fog out to the fog
   distance.

Limitations: sky light in the fog is not occluded, so enclosed spaces get the
same sky glow as open ones; lower **Fog sky light** indoors. Blended surfaces
are fogged at the depth of what is behind them. SSR reflects last frame's image
with its fog already applied.

## Ambient occlusion (GTAO)

Ambient occlusion darkens ambient light in creases and where objects meet.
It is computed as **ground-truth ambient occlusion** (GTAO; Jimenez et al.
2016, following Intel's XeGTAO), from the prepass's depth and normals
(`PSGtao` and `PSAoBlur` in `scene.hlsl`, `src/renderer_ao.odin`). Where
sampling-based SSAO counts points in a hemisphere, GTAO measures how much of
the sky a pixel can see, weighted by the cosine to its normal, as a diffuse
surface receives it.

1. **Slices**: three screen directions per pixel, rotated by a 4 × 4 pattern.
   Each defines a slice: the plane through the view direction along that
   direction.
2. **Horizons**: on both sides of the pixel, four depth samples out to **AO
   radius** (world units, default 1, converted to pixels at the pixel's
   depth), denser near the pixel. Each sample gives the angle up to it from
   the view direction, and the highest one on each side is the horizon. Samples
   beyond 40% of the radius fade towards no occlusion, so a distant
   silhouette does not darken the background behind it.
3. **Integral**: the prepass's shading normal (normal maps included) is
   projected into the slice. The visible arc between the two horizons,
   clamped to the normal's hemisphere, is integrated with the cosine in
   closed form. The slices' average, each weighted by the projected normal's
   length, is the visible share of the ambient light.
4. **Blur**: a 4 × 4 average skipping pixels whose depth differs by more than
   5%, which removes the pattern without blurring across edges.
5. **Result**: `visibility ^ AO intensity` (default 2), multiplied by the
   material's occlusion map. **Show AO only** displays this combined occlusion.

In the lit pass, the diffuse ambient light then uses GTAO's **multi-bounce**
fit: light bouncing between the surfaces around a crease lifts its occlusion,
more on light-colored surfaces, so white plaster darkens less than dark wood.
Reflections use the plain value, through the specular occlusion above. The
pass costs about 0.9 ms at 1280 × 720 in Sponza, against 0.7 ms for the SSAO
it replaced.

## Screen-space reflections (SSR)

SSR replaces the environment's reflection with what is actually on screen,
where it can find it (`src/renderer_ssr.odin`, `TraceReflection` in
`scene.hlsl`). It costs about 0.6 ms at 1080p.

1. **Inputs**: the prepass's surface buffer (normal and roughness), depth,
   motion vectors, and last frame's HDR image: TAA's output, or the HDR
   target before this frame's lit pass overwrites it.
2. **Trace**: before the lit pass, a full-screen pass reflects the view ray
   about each pixel's normal and marches it in screen space, up to 64 steps,
   with depth interpolated linearly in 1/z. The march starts at a random offset
   per pixel. A hit is a step whose segment passes behind the visible surface
   but by less than **SSR thickness**; five binary-search steps then refine it.
   Rays are clipped before the near plane and end at **SSR max distance**.
3. **Color**: the hit's color is read from last frame's image at the hit
   minus its motion vector. Reflections therefore include full lighting and
   earlier reflections (mirrors facing each other repeat), one frame late.
4. **Confidence**: hits fade out near the screen edges, towards the end of the
   ray, on back faces (where the hit surface faces away from the ray), and as
   roughness approaches **SSR max roughness** (fading in from 60% of it).
   The result is stored premultiplied by its confidence.
5. **Blend**: the lit pass mixes the environment's (or the reflection
   probes') specular light with the SSR color by the confidence, before the
   usual BRDF and specular occlusion.

With TAA, each pixel's ray is drawn from the GGX lobe with noise that changes
every frame, and TAA's history averages them into blurred reflections on rough
surfaces. Without TAA, rays are mirror reflections. **Show reflections only**
displays this frame's raw SSR output at tone mapping, before TAA, so the
noise shows; it does not replace the image SSR reads next frame. Blended
surfaces get no SSR, and nothing off screen or hidden behind a foreground
object can be reflected.
