// Auto-exposure: two compute passes over the HDR scene color (after TAA,
// before bloom).
//
// CSHistogram counts every pixel's luminance into a 256-bin histogram on a
// log2 scale. CSAdapt then averages the log2 luminance of the pixels between
// two percentiles, so dark corners and small bright highlights (the sun) do
// not steer the result, picks the exposure that brings that average to
// TARGET_LUMINANCE, and eases the current exposure toward it. Everything
// stays on the GPU; bloom and tone mapping read the result from g_exposure.

#define BIN_COUNT 256
// What the averaged luminance is exposed to: twice the classic mid grey
// (0.18), because the average covers the brighter half of the image. Chosen
// on the default scene and Sponza (indoors and under the open sky); the
// compensation setting adjusts from here.
#define TARGET_LUMINANCE 0.36f

cbuffer ExposureConstants : register(b0)
{
    uint2 image_size;
    // Bin 1 starts at min_log2_luminance; bin 0 holds (near-)black pixels.
    float min_log2_luminance;
    float log2_luminance_range;

    float low_percentile;  // Fractions of all pixels, e.g. 0.5 and 0.95.
    float high_percentile;
    float delta_time;      // Seconds since the last frame.
    float adapt_dark;      // Rates per second: toward more exposure,

    float adapt_bright;    // and toward less (the eye adapts to light faster).
    float min_ev;          // Limits of log2(exposure).
    float max_ev;
    uint  reset;           // Nonzero: jump to the target instead of adapting.
};

Texture2D<float4> g_scene : register(t0);
RWByteAddressBuffer g_histogram : register(u0); // BIN_COUNT uints, kept zeroed between frames.
RWByteAddressBuffer g_exposure : register(u1);  // Exposure (2^ev), then ev.

groupshared uint g_bins[BIN_COUNT];

// Single exit: FXC reports early returns from inlined helpers as
// "potentially uninitialized" (X4000).
uint LuminanceBin(float3 color)
{
    float luminance = dot(color, float3(0.2126f, 0.7152f, 0.0722f));
    uint bin = 0u;
    if (luminance >= 0.00001f)
    {
        float t = saturate((log2(luminance) - min_log2_luminance) / log2_luminance_range);
        bin = uint(t * (BIN_COUNT - 2) + 1.0f);
    }
    return bin;
}

[numthreads(16, 16, 1)]
void CSHistogram(uint3 id : SV_DispatchThreadID, uint index : SV_GroupIndex)
{
    // Count into group memory first: far fewer atomics on the shared buffer.
    g_bins[index] = 0u;
    GroupMemoryBarrierWithGroupSync();

    if (all(id.xy < image_size))
    {
        InterlockedAdd(g_bins[LuminanceBin(g_scene.Load(int3(id.xy, 0)).rgb)], 1u);
    }
    GroupMemoryBarrierWithGroupSync();

    if (g_bins[index] > 0u)
    {
        g_histogram.InterlockedAdd(index * 4u, g_bins[index]);
    }
}

[numthreads(BIN_COUNT, 1, 1)]
void CSAdapt(uint index : SV_GroupIndex)
{
    g_bins[index] = g_histogram.Load(index * 4u);
    g_histogram.Store(index * 4u, 0u); // Ready for the next frame.
    GroupMemoryBarrierWithGroupSync();

    if (index == 0u)
    {
        // Walk the bins in order, keeping the part of each that falls between
        // the two percentiles of all pixels.
        float total = float(image_size.x) * float(image_size.y);
        float low = total * low_percentile;
        float high = total * high_percentile;
        float below = 0.0f;
        float sum = 0.0f;
        float weight = 0.0f;
        for (uint bin = 0u; bin < BIN_COUNT; ++bin)
        {
            float count = float(g_bins[bin]);
            float inside = max(min(below + count, high) - max(below, low), 0.0f);
            // The bin's center; bin 0 (black) counts as the darkest level.
            float log2_luminance = min_log2_luminance;
            if (bin > 0u)
            {
                log2_luminance += (float(bin) - 0.5f) / (BIN_COUNT - 2) * log2_luminance_range;
            }
            sum += log2_luminance * inside;
            weight += inside;
            below += count;
        }
        float average = weight > 0.0f ? sum / weight : 0.0f;

        // Exposure that maps the average to the target, within the limits.
        float target_ev = clamp(log2(TARGET_LUMINANCE) - average, min_ev, max_ev);
        float ev = asfloat(g_exposure.Load(4u));
        if (reset != 0u)
        {
            ev = target_ev;
        }
        else
        {
            float rate = target_ev > ev ? adapt_dark : adapt_bright;
            ev += (target_ev - ev) * (1.0f - exp(-delta_time * rate));
        }
        g_exposure.Store2(0u, uint2(asuint(exp2(ev)), asuint(ev)));
    }
}
