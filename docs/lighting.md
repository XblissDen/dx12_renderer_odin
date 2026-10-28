# Lighting

All lighting happens in one forward pass (`ShadeSurface` in
`shaders/scene.hlsl`): each pixel of each surface sums the sun, the point and
spot lights reaching its cluster, the environment's diffuse and specular
light, and emission. The result goes to the HDR target in linear units;
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
- **Occlusion**: ambient occlusion (SSAO times the material's occlusion map)
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
  the bitangent's sign. The map's xy are scaled by the normal strength.
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
- **Blended** surfaces are drawn after all opaque ones, back to front, with
  alpha = albedo alpha × opacity. They skip SSAO and SSR, which come from the
  opaque surface behind them.

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

### Spot lights

The four shadow-casting spot lights nearest the camera each get a 1024²
perspective map per frame: the outer cone is the field of view and the range
is the far plane. Casters get a slope-scaled rasterizer depth bias, and
receivers look up 1.5 texels off their surface (the texel size grows with
distance from the light). Filtering uses the sun's 5 × 5 tent. The Inspector
says whether a light got a shadow slot this frame.

### Point lights

The four shadow-casting point lights nearest the camera each get a cube map of
six 512² faces: 90° views in D3D's cube layout out to the range, sharing the
spot lights' bias pipelines. The shader picks the face by direction and turns
the receiver's distance along the dominant axis into that face's depth. A 3 × 3
tent of filtered comparisons, one texel apart across the direction, softens
the edges. Each shadowed point light draws its casters six times per frame.

## Image-based lighting and the sky

### Environment panoramas

The environment is an HDR panorama (equirectangular, 2:1). It is decoded,
uploaded with a full mip chain built on the CPU (each level weights rows by
their solid angle, so the panorama's total light is preserved), and baked into
two maps for lighting. **Environment rotation** turns it around the Y axis;
**IBL intensity** scales the light it gives.

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

## Ambient occlusion (SSAO)

SSAO darkens ambient light in creases and where objects meet, from the
prepass depth (`PSSsao` and `PSSsaoBlur` in `scene.hlsl`).

- **Normal**: rebuilt from depth. For each axis it uses the neighbour on the
  same surface (the smaller depth step), so silhouettes do not bend it.
- **Samples**: 16 points in a cosine-weighted hemisphere around the normal, at
  distances up to **AO radius** (world units, default 1), more of them close
  to the surface. The hemisphere is rotated per pixel from a 4 × 4 pattern.
- **Test**: a sample is occluded when the visible surface at its screen
  position is in front of it. Occluders much farther in front of the pixel
  than the radius (another object's silhouette) count less, so objects do not
  cast dark halos onto the background behind them.
- **Blur**: a 4 × 4 average skipping pixels whose depth differs by more than
  5%, which removes the rotation pattern without blurring across edges.
- **Result**: `(1 − occluded fraction) ^ AO intensity` (default 2), multiplied
  by the material's occlusion map in the lit pass. **Show AO only** displays the
  combined occlusion.

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
5. **Blend**: the lit pass mixes the environment's specular light with the SSR
   color by the confidence, before the usual BRDF and specular occlusion.

With TAA, each pixel's ray is drawn from the GGX lobe with noise that changes
every frame, and TAA's history averages them into blurred reflections on rough
surfaces. Without TAA, rays are mirror reflections. **Show reflections only**
displays this frame's raw SSR output at tone mapping, before TAA, so the
noise shows; it does not replace the image SSR reads next frame. Blended
surfaces get no SSR, and nothing off screen or hidden behind a foreground
object can be reflected.
