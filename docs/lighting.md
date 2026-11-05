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

### Sun: ray-traced shadows

On GPUs with DXR 1.1 (ray-tracing tier 1.1), the sun's shadows come from
rays instead of the cascades (**Ray-traced sun shadows** in Renderer
controls, on by default). The lit pass's pixel shader casts one ray per pixel
toward the sun with an **inline ray query** (`SunRayVisibility` in
`scene.hlsl`): a `RayQuery` object, `TraceRayInline`, then a loop over
candidate hits. There are no ray-tracing pipelines or shader tables. See
[Frame structure](frame.md#ray-tracing-structures) for what the rays are
traced against.

- **The ray** starts off the surface along its geometric normal, by 2 mm plus
  0.5 mm per meter from the camera, and stops at the first hit (any hit
  shadows). Surfaces facing away from the sun get no sunlight without a ray.
  Only draws that cast shadows are considered (unlit light markers are left
  out, through the instance mask).
- **Cutouts**: draws with cutout or blended materials are non-opaque
  instances. For each candidate hit on one, the shader finds the triangle's
  three vertices through the raw views of the mesh's index and vertex
  buffers, interpolates their texture coordinates at the hit, and tests the
  albedo's alpha against the material's cutoff, as the shadow maps' alpha
  test does. The hit counts only if the alpha passes, so leaves cast
  leaf-shaped shadows.
- **Soft edges**: with TAA, each ray aims at a random point on the sun's
  disc (**Sun size**, the angular radius, default 0.27°, the real sun's).
  Neighbouring pixels and frames then average into a penumbra that is sharp
  where the shadow touches its caster and widens with distance from it.
  Without TAA the noise would stay, so the rays aim at the sun's center and
  the shadows are hard.
- **Compared with the cascades**:
  - no resolution limit, so thin and distant casters keep their shadows;
  - no depth bias, so no acne and no light leaking under thin overhangs;
  - no shadow distance, and no cascade seams;
  - probe and irradiance volume captures trace the same rays, so a capture
    far from the camera gets correct sun shadows.
- **Cost**: in Sponza at 1920 × 1080 with a high sun, the lit pass took
  0.32 ms longer (0.61 → 0.93 ms), plus 0.06 ms to build the frame's TLAS.
  With fog off, the cascades are no longer drawn, which saved 0.27 ms (Shadow
  0.31 → 0.04 ms), so the frame cost about the same.
- **What still uses the cascades**: volumetric fog's light shafts. While fog
  is on, the cascades are still drawn for it. Point and spot lights have
  rays of their own ([below](#spot-and-point-lights-ray-traced-shadows)).

On GPUs without DXR 1.1, the shaders are compiled without `RAY_TRACING`
(a pipeline using ray queries cannot be created there), the switch is
replaced by a note, and the cascades are used as before.

### Spot and point lights: the shadow atlas

Spot and point light shadows share one 4096² depth atlas
(`src/renderer_shadow.odin`). Every shadow-casting light whose range reaches
the view gets square tiles in it, so any number of lights can cast shadows, up
to what fits (and 64 lights). On GPUs with DXR 1.1, rays replace it
([below](#spot-and-point-lights-ray-traced-shadows)); it is then drawn only
for volumetric fog.

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

### Spot and point lights: ray-traced shadows

On GPUs with DXR 1.1, point and spot light shadows come from rays instead of
the atlas (**Ray-traced light shadows** in Renderer controls, on by default),
traced like the sun's (`LightRayVisibility` in `scene.hlsl`). Every
shadow-casting light gets exact shadows, however many there are.

- **The ray** leaves the surface as the sun's does and heads for the light.
  It stops short of the light by the atlas views' near distance (2 cm, or
  0.1% of the range for long ranges), so a lamp shade fitted closely around
  the light does not hide it. Surfaces facing away from the light (by their
  geometric normal) get none of its light without a ray.
- **Soft edges**: a light's **Source radius** (Inspector, default 0: exact
  shadows) is the size of its glowing ball. With TAA, each ray aims at a
  random point of the disc that ball shows the surface, so frames average
  into a penumbra that widens with distance from the caster, as for the sun.
  Each light has its own noise pattern, so overlapping penumbrae do not
  shimmer together. Without TAA the rays aim at the light's center.
- **Budget**: each light covering a pixel costs a ray, so a pixel traces at
  most **Light shadow rays per pixel** (default 4, up to 8). First, one pass
  over the pixel's light cluster ranks the shadow-casting lights by the light
  each would give it unshadowed (luminance times falloff, cone and the
  cosine to the light), keeping the largest few in registers. Only the
  lights at or above the budget-th largest get rays; the weaker ones
  are lit unshadowed there. With few lights in reach, every one gets a ray.
- **Everywhere rays shade**: blended surfaces, probe captures, reflection
  hits and dynamic GI probes' hits trace the same rays within the same
  budget, so no light leaks through walls into reflections or bounced light.
- **The atlas** is not drawn while rays replace it, unless volumetric fog is
  on: the fog still reads it (its cells would need far more rays), so lights
  keep their tiles for the fog alone. The Profiler then shows the atlas line
  as unused, or as usual with fog.
- **Compared with the atlas**: no tile sizes or atlas space, so small and
  distant lights shadow as sharply as near ones; no depth bias, so contact
  shadows stay attached (a wall relief lit from the side casts the thin
  shadow the atlas lost to its bias); no redraws when lights or casters
  move; soft edges sized by the light.
- **Cost** at 1920 × 1080 in Sponza:
  - 3 point lights reaching most of the view: the lit pass 1.44 → 1.69 ms,
    reflections 1.17 → 1.33 ms; the source radius adds almost nothing
    (1.70 ms). Nothing moved, so the atlas drew no tiles and the shadow
    pass was 0.04 ms either way; moving lights would redraw theirs.
  - 24 overlapping point lights (most pixels in reach of 4 to 16): the lit
    pass took 2.28 ms with 1 ray per pixel, 4.04 with 4 and 4.89 with 8,
    against 2.39 ms with the atlas, which fit only 16 of the lights and drew
    24 light views every frame (0.18 ms) as they fought for room. 4 and 8
    rays look the same there; 1 keeps only the strongest light's shadows.

On GPUs without DXR 1.1, the atlas is used as before, and the source radius
has no effect.

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

The volume entity's unit cube under its world matrix, as for reflection
probes, is divided into **cells** (8 × 4 × 8 by default, up to 32 along each
axis and 8,192 in all). Each cell holds the light around its center. The
cells' light comes from one of two places:

- **Dynamic** (GPUs with DXR 1.1, the default there): rays update the cells
  every frame, so the light follows moving lights, the sun and edits
  ([below](#dynamic-volumes)).
- **Baked**: cube captures, one cell per frame, once
  ([below](#baked-volumes)). This is the only mode on other GPUs, and a
  switch on DXR 1.1 GPUs to compare against.

### Dynamic volumes

On GPUs with DXR 1.1, each cell is a **probe** in the manner of DDGI
(Majercik et al., "Dynamic Diffuse Global Illumination with Ray-Traced
Irradiance Fields"). There is no bake: rays bring every probe up to date a
little each frame (**Dynamic (ray-traced probes)** in Renderer controls).

**Storage** (`shaders/volumes.hlsl`): per probe, two small maps of directions
around it, each folded into a square by octahedral mapping:

- **Irradiance**, 8 × 8 texels (6 × 6 plus a one-texel border): the
  cosine-weighted average light arriving around each direction, which is what
  a surface facing that way receives.
- **Distance**, 16 × 16 texels (14 × 14 plus border): the average distance to
  the first surface around each direction, and its square.

The maps sit in two atlases (2048 × 1024 and 4096 × 2048, 256 probes per
row). A third texture, one texel per probe, holds the probe's offset from its
cell's center and how many updates it has had. Each volume has room for
8,192 probes.

**Update**, each frame after the light clusters (the **Dynamic GI** row in
the GPU timings):

1. **Rays** (`PSVolumeRays`): a full-screen pass over a rays-by-probes
   target casts **Rays per probe** rays (default 128) from each probe of the
   frame's batch, one pixel per ray. Directions are spread evenly over the
   sphere (spherical Fibonacci) and turned by a random rotation each frame,
   so successive updates sample different directions. A ray's hit is shaded
   diffuse-only (`ShadeRayHit`): the sun with a shadow ray, point and spot
   lights with theirs (or their atlas shadows without ray-traced light
   shadows), and ambient light that includes the volumes themselves. Each
   update therefore carries light one bounce further, and the bounces add up
   over frames. A miss reads the sky, without its sun. A ray that hits the
   back of a one-sided surface records no light and a negative distance:
   that probe is inside something.
2. **Blend** (`CSBlendIrradiance`, `CSBlendDistance` in
   `shaders/dynamic_volume.hlsl`): one compute group per probe. Each map
   texel averages the rays near its direction, and the result is blended
   with what the texel held, keeping **Hysteresis** (default 0.97) of the
   old value, or none on a probe's first update. The rays are weighted by
   their cosine for irradiance, and by its 50th power for distance, so the
   distance map keeps the shape of nearby walls. Distances are capped at 1.5
   cell diagonals. The border texels then copy the interior texels across
   the octahedron's folds, so bilinear filtering is seamless.
3. **Relocate** (`CSRelocate`): DDGI's probe relocation, on the GPU. A probe
   whose rays meet back faces more than 25% of the time is inside geometry:
   it moves through the nearest back face, to just beyond it. A probe very
   close to a surface moves away from it. It stays within 0.45 cells of its
   cell's center, and a probe still inside geometry is not used. This
   replaces the baked mode's readback and retries.

**Batches**: **Probes per frame** (default 2,048, up to 4,096) are updated
each frame, taking turns across every volume's probes. A volume filling
Sponza (18 × 7 × 10 = 1,260 probes) is updated whole every frame. Moving,
resizing or adding a volume, changing the environment, loading a scene, or
**Start over** clears its probes, which then fill in again on their next
update.

**Lookup** (`SampleDynamicVolume`, from `ApplyIrradianceVolumes`): the eight
probes around the surface, as in DDGI:

1. The lookup point moves off the surface along the normal, and towards the
   viewer, by 0.2 cells.
2. Each probe's trilinear weight is scaled by the smooth back-face term (as
   for baked volumes), then by a **visibility test**. From the probe's
   distance map toward the lookup point come the mean distance to the first
   surface in that direction and its variance. A point farther than the mean
   is likely behind that surface; Chebyshev's inequality bounds how likely,
   and its cube scales the weight (at least 0.05). Weights below 0.2 are
   crushed further, so a nearly hidden probe does not tint the rest. This is
   what keeps light from leaking through walls, rather than the cell layout.
3. The probes' irradiance along the normal is averaged by those weights.
   Probes not yet updated, or inside geometry, are skipped, and the volume
   fades out where none are near.

**Results**: in Sponza with a volume of 18 × 7 × 10 cells, the probes
settle within a few seconds and match the baked result closely, without
waiting about 25 seconds for a bake. With a high sun, the bounce from the
sunlit floor appears straight away and warms the walls, where a baked volume
would need capturing again. **Cost** at 1920 × 1080: about 0.35 to 0.5 ms
per frame for the update (1,260 probes × 128 rays), and 0.3 ms more in the
lit pass than the baked lookup (16 atlas reads per volume per pixel instead
of 32 texel loads, plus the visibility test).

**Limits**: probe rays only see the point and spot lights in the camera's
view (the frame's light list). Probes are spaced a cell apart, so light
between them is interpolated, and GTAO still adds contact shadows. A probe
that cannot get out of a thick wall within 0.45 cells stays unused.

### Baked volumes

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

#### Cells inside walls

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

#### Lookup

All baked volumes share one 3D texture (`VOLUME_ATLAS_*`), a 32³ block per volume.
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

#### Limits

- **Coarse**: with cells a meter or more apart, light changes smoothly. Small
  objects get light from cells around them, not their own contact shadows;
  GTAO adds those.
- **Leaks**: the back-face term reduces light passing through walls thinner
  than a cell, but does not stop it. A volume per room, with blend distances,
  leaks less than one volume over a building.
- **Darker interiors**: rooms come out much darker than with the sky's
  light, as they should. Auto exposure suits them.
- **Sun shadows** in captures come from the camera's cascades, as for
  probes, unless ray-traced sun shadows are on: cells far from the camera can
  then see sunlight where there is shadow. Bake with the camera near the
  volume, or raise **Shadow distance** while it bakes.
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
     point and spot light in the cell's light cluster, with their shadow maps
     (drawn for the fog even when rays shadow the surfaces).
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

### Ray-traced ambient occlusion (RTAO)

On GPUs with DXR 1.1, rays replace GTAO (**Ray-traced AO (instead of
GTAO)** in Renderer controls, on by default; GTAO stays on other GPUs). The
result is the same quantity, the share of a cosine-weighted hemisphere that
is open within **AO radius**, but measured against the scene rather than the
depth buffer. Occluders off screen or behind other surfaces count, and there
are no halos where depth jumps. Radius, intensity, the multi-bounce fit and
**Show AO only** work as for GTAO.

1. **Rays** (`PSRtao` in `scene.hlsl`): from each pixel's depth and the
   prepass's normal, **AO rays per pixel** rays (default 1) leave the surface,
   spread with the cosine over the hemisphere, and look for any hit within
   the radius (cutouts alpha-tested). A hit counts fully within the first
   38.5% of the radius and fades out over the rest, as GTAO's samples do.
   - **Stratified:** the 16 pixels of each 4 × 4 block take turns through
     one set of 16 directions per ray, spread evenly over the hemisphere (a
     Fibonacci lattice), so the blur below gathers 16 different directions.
   - **Shifted:** the set moves each frame (an R2 sequence), so frames
     sample different directions.
2. **Blur**: the same 4 × 4 depth-aware average as GTAO.
3. **History** (`PSAoAccumulate`): the blurred AO is averaged with last
   frame's at the same surface, found through the motion vectors, over up to
   16 frames. The history stores each pixel's view depth. If last frame's
   depth there is not where this point was last frame (within 5%), the
   surface was hidden or off screen, and it starts over from this frame
   alone. Two history targets are written in turn, and the lit pass reads the
   newest.

With the history, one ray per pixel is enough: in Sponza at 1080p the AO pass
(rays, blur and history) takes about 0.56 ms against GTAO's 0.92 ms. Without
a history, the 4 × 4 blur alone left visible grain at one ray, and two rays
cost 1.14 ms. The rays themselves cost about 0.5 ms per ray per pixel, so
more rays mainly help moving views, where the history restarts.

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

## Ray-traced reflections

On GPUs with DXR 1.1, reflections come from rays instead of SSR
(**Ray-traced reflections (instead of SSR)** in Renderer controls, on by
default). The rays are traced against the scene itself, so they reflect what
is off screen or hidden behind other objects, and what SSR could not tell
apart. The pass (`PSRayReflections` in `scene.hlsl`) writes the same target
as SSR, and the lit pass blends it in the same way.

1. **The ray**: a full-screen pass after the light clusters reads each
   pixel's depth and the prepass's normal and roughness. It turns them into a
   world position and normal, and reflects the view ray about the normal. With
   TAA, the direction is drawn from the GGX lobe, as for SSR, so rough
   surfaces blur over frames. Pixels at or above **Reflection max roughness**
   (SSR's setting, default 0.6) are skipped and keep the probes' and
   environment's specular.
2. **Tracing**: an inline ray query over every draw finds the closest hit.
   Back faces are culled, as the rasterizer culls them, except on
   double-sided surfaces. Cutouts are alpha-tested as for shadow rays.
3. **Shading the hit** (`ShadeRayHit`): the hit triangle's vertices are read
   through the raw mesh buffers, and its normal and texture coordinates are
   interpolated. The material is read as in the lit pass, at a mip that grows
   with the ray's length. Normal maps are skipped. Lighting at the hit:
   - the sun, with a shadow ray of its own;
   - point and spot lights, with shadow rays within the per-pixel budget (or
     their atlas shadows without ray-traced light shadows). They come from
     the hit's light cluster when the hit is on screen, and from every light
     in view otherwise;
   - ambient light from the sky, probes and irradiance volumes, as in the lit
     pass (no GTAO);
   - emission. Light markers show their flat color.
4. **Miss**: the ray left the scene, so it reads the environment's
   prefiltered light along its direction. That is the sky without its sun:
   the reflecting surface's own sun highlight already adds the sun.
5. **Confidence**: 1, fading out between 60% and 100% of the max roughness.
   On rough surfaces a reflection's luminance is capped at 16, so a rare
   bright hit does not flicker through TAA.

Compared with SSR, the reflections are of this frame, with no screen-edge
fade or thickness guess. Their surfaces are shaded more simply than the lit
pass shades them: no normal maps, no GTAO, and only one bounce, since a
reflected surface shows probes rather than its own reflections. **Show
reflections only** shows them as it does SSR. In Sponza with a high sun at
1920 × 1080, the pass took 0.73 ms against SSR's 0.30 ms. Most of Sponza is
rougher than 0.6 and is skipped. Outdoors, the glossy ground now reflects the
sky and the objects wherever they are, where SSR left black gaps (things off
screen) for the environment to fill.
