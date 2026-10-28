# Post-processing

After the lit pass, the HDR image goes through, in order:

1. **TAA** resolve (in HDR), when TAA is the anti-aliasing mode.
2. **Auto exposure**, measuring the result.
3. **Bloom**, built from it.
4. **Tone mapping**, which applies exposure, adds bloom, maps HDR to the
   display range and encodes sRGB.
5. **FXAA** or **sharpening**, on the tone-mapped image, when enabled.
6. The selection box and the UI, drawn last so they stay crisp.

The HDR image after step 1 is the *scene color*: TAA's output, or the lit HDR
target without TAA. Exposure, bloom and tone mapping read it, and next frame's
SSR reflects it.

## TAA

Temporal anti-aliasing renders each frame from a slightly different sub-pixel
position and blends it into an accumulated history (`src/renderer_taa.odin`,
`PSTaaResolve` in `shaders/post_process.hlsl`).

- **Jitter**: the projection is offset by a sub-pixel amount each frame, from
  the first eight points of the Halton (2, 3) sequence. Culling and motion
  vectors use the unjittered matrices.
- **Reprojection**: each pixel finds where its surface was last frame using
  the motion vectors from the depth prepass. It takes the motion of the
  nearest surface in its 3 × 3 neighbourhood, so the edges of moving objects
  follow the object rather than the background.
- **History lookup**: a Catmull-Rom filter from five bilinear taps. Plain
  bilinear filtering would soften the image a little more every frame.
- **Ghosting**: the history is clipped towards the colour range of the current
  pixel's 3 × 3 neighbourhood, as mean ± 1.25 standard deviations in YCoCg
  space. A history colour that could not appear here now (a surface that moved
  away, or one newly uncovered) is pulled back into range.
- **Blend**: 10% new frame, 90% history. Colours are blended after a
  reversible compression (`c / (1 + max(r, g, b))`, Karis), so a rare very bright
  pixel cannot dominate its neighbours.
- **Sky motion**: the prepass does not draw the sky, so sky pixels have no
  motion vectors. Where a pixel's whole 3 × 3 neighbourhood is sky, its motion
  comes from camera rotation alone: its far-plane point is reprojected with
  last frame's rotation-only camera (the sky is infinitely far, so moving the
  camera does not move it).
- **Restarts**: pixels that come from outside the screen, the first frame
  after a resize, and switching TAA on all use the current frame alone.

TAA runs before bloom and tone mapping, so those see a stable image; it also
smooths SSAO noise and averages SSR's stochastic rays. Blended surfaces have no
motion vectors, so moving glass can smear slightly.

### Sharpening

The history blend softens detail slightly. With TAA, AMD's contrast-adaptive
sharpening (FidelityFX CAS) runs after tone mapping. Each pixel is pushed away
from its four neighbours, by an amount that shrinks where its 3 × 3
neighbourhood already spans much of the range, so edges get no halos and noise
is not amplified. **Sharpening** goes from 0 (the pass is skipped) to 1;
the default is 0.5.

## FXAA

FXAA follows Lottes' FXAA 3.11 quality path on the tone-mapped image: find
pixels on a high-contrast edge, work out whether the edge is horizontal or
vertical, search along it in both directions for its ends, and shift the
lookup across the edge by how far this pixel is from the nearer end. A
separate subpixel term blends pixels that differ strongly from their 3 × 3
average, for features thinner than a pixel.

FXAA and sharpening both read an intermediate LDR image that tone mapping
writes, and write the back buffer. With neither, tone mapping writes the back
buffer directly.

## Auto exposure

Two compute passes in `shaders/auto_exposure.hlsl` measure the scene color
and adjust the exposure, entirely on the GPU:

1. **Histogram**: every pixel's luminance goes into one of 256 bins on a log2
   scale; bin 0 holds near-black pixels.
2. **Adapt**: the log2 luminance of the pixels between the 50th and 95th
   percentiles is averaged, so dark corners and small bright highlights (the
   sun) do not steer the result. The target exposure brings that average to
   0.36, twice mid grey, since the average covers the brighter half of the
   image.
3. **Easing**: the exposure moves towards the target exponentially, at
   **Adapt to bright** (default 3/s) when the image gets brighter and **Adapt
   to dark** (1/s) when it gets darker; the eye adapts to light faster. The
   result stays within **Min/Max EV**.

The exposure stays in a GPU buffer that bloom and tone mapping read.
**Compensation** (in EV; +1 doubles the brightness) multiplies into it. A copy
is read back for the panel, two frames late. A long pause (a breakpoint, a
dragged window) adapts as if at most a quarter second passed. Turning auto
exposure off returns to the manual **Exposure** slider; turning it back on
jumps straight to the measured exposure.

## Bloom

Bloom follows Jimenez's design from Call of Duty: Advanced Warfare (2014), as
a mip chain at half resolution and below, about 0.1 ms at 1080p.

1. **Prefilter**: keeps what is above **Bloom threshold** into level 0 at half
   resolution. The threshold applies to the exposed image, so what blooms does
   not change as exposure adapts; the output itself stays unexposed. A 13-tap
   filter reads a 4 × 4 texel area as five overlapping 2 × 2 boxes. In this
   first step each box is weighted by `1 / (1 + luminance)` (a Karis average),
   so tiny super-bright pixels such as the sun cannot make the bloom flicker as
   they move.
2. **Downsample**: five more levels, each half the size of the last, with the
   same 13-tap filter, down to 1/64 resolution.
3. **Upsample**: from the smallest level up, a 3 × 3 tent filter blurs each
   level and adds it into the next larger one (additive blending). Level 0
   ends up holding every level: a tight glow near bright parts plus a wide,
   soft halo.

Tone mapping adds level 0, upscaled bilinearly and scaled by **Bloom
strength**, before exposure. Every lookup clamps at the screen edges instead of wrapping. Small
windows get fewer levels.

## Tone mapping

The final full-screen pass adds bloom to the scene color, multiplies by the
exposure, applies the tone mapper, and encodes sRGB:

- **ACES** (fitted, the default): Stephen Hill's fit of the ACES RRT and sRGB
  ODT, including its input and output color matrices.
- **AgX**: Benjamin Wrensch's minimal AgX approximation with the default look.
  It desaturates very bright colors towards white more gracefully than ACES.
- **Reinhard**: `c / (1 + c)`, per channel.

The swap chain is `R8G8B8A8_UNORM` (ImGui draws to it too), so the shader does
the sRGB encoding.
