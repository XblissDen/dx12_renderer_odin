Texture2D<float4> g_hdr_texture : register(t0);
Texture2D<float4> g_bloom_texture : register(t1);
SamplerState g_sampler : register(s0);

cbuffer PostConstants : register(b1)
{
    float exposure;
    float bloom_threshold;
    float bloom_strength;
    uint  tone_mapper; // 0 Reinhard, 1 ACES, 2 AgX
    float2 texel_size; // One pixel in UV units.
    uint  taa_history_valid;
    float taa_blend;   // Share of the new frame in each TAA blend.
};

// TAA inputs; the history is bound in the bloom slot (t1).
Texture2D<float2> g_velocity : register(t8);
Texture2D<float> g_depth : register(t9);

SamplerState g_clamp_sampler : register(s4);

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

float4 PSExtract(VSOutput input) : SV_TARGET
{
    float3 color = g_hdr_texture.Sample(g_sampler, input.uv).rgb;
    float luminance = dot(color, float3(0.2126f, 0.7152f, 0.0722f));

    // Retain only the energy above a brightness threshold
    float weight = max(luminance - bloom_threshold, 0.0f) /
               max(luminance, 0.0001f);

    return float4(color * weight, 1.0f);
}

float3 Blur(float2 uv, float2 direction)
{
    uint width, height;
    g_hdr_texture.GetDimensions(width, height);

    float2 dimensions = float2(width, height);
    float2 step_uv = direction * 2.0f / dimensions;

    // Keep samples inside the image; our existing sampler uses WRAP.
    float2 min_uv = 0.5f / dimensions;
    float2 max_uv = 1.0f - min_uv;

    static const float weights[5] = {
        0.227027f, 0.1945946f, 0.1216216f, 0.054054f, 0.016216f
    };

    float3 result = g_hdr_texture.Sample(
        g_sampler, clamp(uv, min_uv, max_uv)
    ).rgb * weights[0];

    [unroll]
    for (int i = 1; i <= 4; ++i)
    {
        float2 offset = step_uv * i;

        result += g_hdr_texture.Sample(
            g_sampler, clamp(uv + offset, min_uv, max_uv)
        ).rgb * weights[i];

        result += g_hdr_texture.Sample(
            g_sampler, clamp(uv - offset, min_uv, max_uv)
        ).rgb * weights[i];
    }

    return result;
}

float4 PSBlurHorizontal(VSOutput input) : SV_TARGET
{
    return float4(Blur(input.uv, float2(1.0f, 0.0f)), 1.0f);
}

float4 PSBlurVertical(VSOutput input) : SV_TARGET
{
    return float4(Blur(input.uv, float2(0.0f, 1.0f)), 1.0f);
}

VSOutput VSMain(uint vertex_id : SV_VertexID)
{
    // One triangle large enough to cover the entire screen.
    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);

    VSOutput output;
    output.position = float4(
        uv.x * 2.0f - 1.0f,
        1.0f - uv.y * 2.0f,
        0.0f,
        1.0f
    );
    output.uv = uv;
    return output;
}

float3 LinearToSrgb(float3 value)
{
    float3 low = value * 12.92f;
    float3 high = 1.055f * pow(value, 1.0f / 2.4f) - 0.055f;
    // FXC evaluates a vector ternary per component.
    return value <= 0.0031308f ? low : high;
}

// Stephen Hill's fit of the ACES RRT + sRGB ODT. Matrices convert linear
// sRGB into and out of the fit's working space; rows are listed here.
static const float3x3 ACES_INPUT = float3x3(
    0.59719f, 0.35458f, 0.04823f,
    0.07600f, 0.90834f, 0.01566f,
    0.02840f, 0.13383f, 0.83777f
);
static const float3x3 ACES_OUTPUT = float3x3(
     1.60475f, -0.53108f, -0.07367f,
    -0.10208f,  1.10813f, -0.00605f,
    -0.00327f, -0.07276f,  1.07602f
);

float3 ToneMapACES(float3 color)
{
    color = mul(ACES_INPUT, color);
    float3 a = color * (color + 0.0245786f) - 0.000090537f;
    float3 b = color * (0.983729f * color + 0.4329510f) + 0.238081f;
    return mul(ACES_OUTPUT, a / b);
}

// Benjamin Wrensch's minimal AgX approximation (default look). The GLSL
// matrices are column-major, so their columns are the rows used with mul(v, M).
static const float3x3 AGX_INPUT = float3x3(
    0.842479062253094f, 0.0423282422610123f, 0.0423756549057051f,
    0.0784335999999992f, 0.878468636469772f, 0.0784336f,
    0.0792237451477643f, 0.0791661274605434f, 0.879142973793104f
);
static const float3x3 AGX_OUTPUT = float3x3(
    1.19687900512017f, -0.0528968517574562f, -0.0529716355144438f,
    -0.0980208811401368f, 1.15190312990417f, -0.0980434501171241f,
    -0.0990297440797205f, -0.0989611768448433f, 1.15107367264116f
);

float3 AgXContrast(float3 x)
{
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return 15.5f * x4 * x2 - 40.14f * x4 * x + 31.96f * x4 -
           6.868f * x2 * x + 0.4298f * x2 + 0.1191f * x - 0.00232f;
}

float3 ToneMapAgX(float3 color)
{
    const float min_ev = -12.47393f;
    const float max_ev = 4.026069f;

    color = mul(color, AGX_INPUT);
    color = clamp(log2(max(color, 1e-10f)), min_ev, max_ev);
    color = (color - min_ev) / (max_ev - min_ev);
    color = AgXContrast(color);
    color = mul(color, AGX_OUTPUT);

    // AgX's display encoding is a 2.2 power; return linear for LinearToSrgb.
    return pow(saturate(color), 2.2f);
}

float4 PSMain(VSOutput input) : SV_TARGET
{
    float3 hdr_color = g_hdr_texture.Sample(g_sampler, input.uv).rgb;
    float3 bloom_color = g_bloom_texture.Sample(g_sampler, input.uv).rgb;

    hdr_color += bloom_color * bloom_strength;

    float3 exposed_color = max(hdr_color * exposure, 0.0f);
    float3 mapped;
    [branch]
    if (tone_mapper == 1u)
    {
        mapped = ToneMapACES(exposed_color);
    }
    else if (tone_mapper == 2u)
    {
        mapped = ToneMapAgX(exposed_color);
    }
    else
    {
        mapped = exposed_color / (exposed_color + 1.0f);
    }

    // The back buffer is UNORM (ImGui draws to it too), so encode sRGB here.
    return float4(LinearToSrgb(saturate(mapped)), 1.0f);
}
// ---------------------------------------------------------------------------
// FXAA, following the published algorithm (Lottes' FXAA 3.11 quality path):
// find pixels on a contrasting edge, work out the edge's direction, search
// along it for both ends, and shift the lookup across the edge by how far this
// pixel is from the nearer end. Subpixel blending handles thin features.
// Input is the tone-mapped, display-encoded frame (g_hdr_texture slot, t0).

#define FXAA_EDGE_THRESHOLD      0.125f  // Minimum contrast, relative to the brightest neighbour.
#define FXAA_EDGE_THRESHOLD_MIN  0.0312f // Ignore contrast in very dark areas.
#define FXAA_SUBPIXEL_QUALITY    0.75f
#define FXAA_SEARCH_STEPS        12

static const float FXAA_STEP_SIZES[FXAA_SEARCH_STEPS] = {
    1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.5f, 2.0f, 2.0f, 2.0f, 2.0f, 4.0f, 8.0f
};

float FxaaLuma(float3 color)
{
    // The input is already perceptually encoded, so plain weights suffice.
    return dot(color, float3(0.299f, 0.587f, 0.114f));
}

float FxaaLumaAt(float2 uv, int2 offset)
{
    return FxaaLuma(g_hdr_texture.SampleLevel(g_clamp_sampler, uv, 0, offset).rgb);
}

float4 PSFxaa(VSOutput input) : SV_TARGET
{
    float2 uv = input.uv;
    float3 center_color = g_hdr_texture.SampleLevel(g_clamp_sampler, uv, 0).rgb;
    float luma_center = FxaaLuma(center_color);

    // Screen space: north is up (-y), south is down (+y).
    float luma_n = FxaaLumaAt(uv, int2(0, -1));
    float luma_s = FxaaLumaAt(uv, int2(0, 1));
    float luma_w = FxaaLumaAt(uv, int2(-1, 0));
    float luma_e = FxaaLumaAt(uv, int2(1, 0));

    float luma_min = min(luma_center, min(min(luma_n, luma_s), min(luma_w, luma_e)));
    float luma_max = max(luma_center, max(max(luma_n, luma_s), max(luma_w, luma_e)));
    float luma_range = luma_max - luma_min;
    if (luma_range < max(FXAA_EDGE_THRESHOLD_MIN, luma_max * FXAA_EDGE_THRESHOLD))
    {
        return float4(center_color, 1.0f);
    }

    float luma_nw = FxaaLumaAt(uv, int2(-1, -1));
    float luma_ne = FxaaLumaAt(uv, int2(1, -1));
    float luma_sw = FxaaLumaAt(uv, int2(-1, 1));
    float luma_se = FxaaLumaAt(uv, int2(1, 1));

    // Second derivatives across rows versus across columns pick the edge's
    // orientation: a horizontal edge changes most from north to south.
    float edge_horizontal =
        abs(luma_nw + luma_sw - 2.0f * luma_w) +
        abs(luma_n + luma_s - 2.0f * luma_center) * 2.0f +
        abs(luma_ne + luma_se - 2.0f * luma_e);
    float edge_vertical =
        abs(luma_nw + luma_ne - 2.0f * luma_n) +
        abs(luma_w + luma_e - 2.0f * luma_center) * 2.0f +
        abs(luma_sw + luma_se - 2.0f * luma_s);
    bool horizontal = edge_horizontal >= edge_vertical;

    // The edge lies between this pixel and its steeper neighbour across it.
    float luma_negative = horizontal ? luma_n : luma_w;
    float luma_positive = horizontal ? luma_s : luma_e;
    float gradient_negative = luma_negative - luma_center;
    float gradient_positive = luma_positive - luma_center;
    bool negative_steeper = abs(gradient_negative) >= abs(gradient_positive);
    float gradient_scaled = 0.25f * max(abs(gradient_negative), abs(gradient_positive));

    float step_across = horizontal ? texel_size.y : texel_size.x;
    float luma_local_average;
    if (negative_steeper)
    {
        step_across = -step_across;
        luma_local_average = 0.5f * (luma_negative + luma_center);
    }
    else
    {
        luma_local_average = 0.5f * (luma_positive + luma_center);
    }

    // Walk along the edge from its midline in both directions.
    float2 edge_uv = uv;
    if (horizontal) edge_uv.y += step_across * 0.5f;
    else edge_uv.x += step_across * 0.5f;
    float2 step_along = horizontal ? float2(texel_size.x, 0.0f) : float2(0.0f, texel_size.y);

    float2 uv_negative = edge_uv - step_along;
    float2 uv_positive = edge_uv + step_along;
    float luma_end_negative = 0.0f;
    float luma_end_positive = 0.0f;
    bool done_negative = false;
    bool done_positive = false;

    [loop]
    for (int i = 0; i < FXAA_SEARCH_STEPS; ++i)
    {
        if (!done_negative)
        {
            luma_end_negative = FxaaLuma(
                g_hdr_texture.SampleLevel(g_clamp_sampler, uv_negative, 0).rgb
            ) - luma_local_average;
            done_negative = abs(luma_end_negative) >= gradient_scaled;
        }
        if (!done_positive)
        {
            luma_end_positive = FxaaLuma(
                g_hdr_texture.SampleLevel(g_clamp_sampler, uv_positive, 0).rgb
            ) - luma_local_average;
            done_positive = abs(luma_end_positive) >= gradient_scaled;
        }
        if (done_negative && done_positive) break;

        float next_step = i + 1 < FXAA_SEARCH_STEPS ? FXAA_STEP_SIZES[i + 1] : 1.0f;
        if (!done_negative) uv_negative -= step_along * next_step;
        if (!done_positive) uv_positive += step_along * next_step;
    }

    float distance_negative = horizontal ? uv.x - uv_negative.x : uv.y - uv_negative.y;
    float distance_positive = horizontal ? uv_positive.x - uv.x : uv_positive.y - uv.y;
    bool negative_closer = distance_negative < distance_positive;
    float distance_final = min(distance_negative, distance_positive);
    float edge_length = distance_negative + distance_positive;

    // Only shift if the nearer end's luma moves the way the centre does;
    // otherwise this pixel is not the one the edge passes through.
    bool center_below_average = luma_center < luma_local_average;
    float luma_end = negative_closer ? luma_end_negative : luma_end_positive;
    bool correct_variation = (luma_end < 0.0f) != center_below_average;
    float edge_offset = correct_variation ? 0.5f - distance_final / edge_length : 0.0f;

    // Subpixel aliasing: how much the centre differs from its 3x3 average.
    float luma_average = (1.0f / 12.0f) * (
        2.0f * (luma_n + luma_s + luma_w + luma_e) +
        luma_nw + luma_ne + luma_sw + luma_se
    );
    float subpixel = saturate(abs(luma_average - luma_center) / luma_range);
    subpixel = (-2.0f * subpixel + 3.0f) * subpixel * subpixel;
    float subpixel_offset = subpixel * subpixel * FXAA_SUBPIXEL_QUALITY;

    float offset = max(edge_offset, subpixel_offset);
    float2 final_uv = uv;
    if (horizontal) final_uv.y += offset * step_across;
    else final_uv.x += offset * step_across;

    return float4(g_hdr_texture.SampleLevel(g_clamp_sampler, final_uv, 0).rgb, 1.0f);
}

// ---------------------------------------------------------------------------
// TAA resolve. The scene is rendered with a different sub-pixel jitter each
// frame; this blends it into the history found through per-pixel motion. To
// avoid ghosting, the history is clipped to the colour range of the current
// pixel's neighbourhood. Runs in HDR before bloom and tone mapping.

#define g_history g_bloom_texture
#define TAA_CLIP_SIGMA 1.25f

// Blending HDR values directly lets rare very bright pixels dominate; this
// reversible compression evens them out (Karis' weighting).
float3 TaaCompress(float3 c)
{
    return c / (1.0f + max(c.r, max(c.g, c.b)));
}

float3 TaaDecompress(float3 c)
{
    return c / max(1.0f - max(c.r, max(c.g, c.b)), 0.0001f);
}

float3 RgbToYCoCg(float3 c)
{
    return float3(
        dot(c, float3(0.25f, 0.5f, 0.25f)),
        dot(c, float3(0.5f, 0.0f, -0.5f)),
        dot(c, float3(-0.25f, 0.5f, -0.25f))
    );
}

float3 YCoCgToRgb(float3 c)
{
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// Pulls `value` toward the box center until it lies inside the box.
float3 ClipToBox(float3 value, float3 box_min, float3 box_max)
{
    float3 center = 0.5f * (box_max + box_min);
    float3 extents = 0.5f * (box_max - box_min) + 0.00001f;
    float3 offset = value - center;
    float3 ratio = abs(offset / extents);
    float largest = max(ratio.x, max(ratio.y, ratio.z));
    return largest > 1.0f ? center + offset / largest : value;
}

// Catmull-Rom history lookup from five bilinear taps: sharper than plain
// bilinear, which would soften the image a little more every frame.
float3 SampleHistoryCatmullRom(float2 uv)
{
    float2 size = 1.0f / texel_size;
    float2 sample_pos = uv * size;
    float2 center = floor(sample_pos - 0.5f) + 0.5f;
    float2 f = sample_pos - center;

    float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
    float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
    float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
    float2 w3 = f * f * (-0.5f + 0.5f * f);

    // The middle two taps per axis merge into one bilinear lookup.
    float2 w12 = w1 + w2;
    float2 uv0 = (center - 1.0f) * texel_size;
    float2 uv3 = (center + 2.0f) * texel_size;
    float2 uv12 = (center + w2 / w12) * texel_size;

    float3 result =
        g_history.SampleLevel(g_clamp_sampler, float2(uv12.x, uv0.y), 0).rgb * (w12.x * w0.y) +
        g_history.SampleLevel(g_clamp_sampler, float2(uv0.x, uv12.y), 0).rgb * (w0.x * w12.y) +
        g_history.SampleLevel(g_clamp_sampler, uv12, 0).rgb * (w12.x * w12.y) +
        g_history.SampleLevel(g_clamp_sampler, float2(uv3.x, uv12.y), 0).rgb * (w3.x * w12.y) +
        g_history.SampleLevel(g_clamp_sampler, float2(uv12.x, uv3.y), 0).rgb * (w12.x * w3.y);
    float total = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return max(result / total, 0.0f); // The filter can undershoot slightly.
}

float4 PSTaaResolve(VSOutput input) : SV_TARGET
{
    int2 pixel = int2(input.position.xy);
    int2 last = int2(1.0f / texel_size) - 1;
    float3 current = g_hdr_texture.Load(int3(pixel, 0)).rgb;
    if (taa_history_valid == 0u)
    {
        return float4(current, 1.0f);
    }

    // Neighbourhood colour statistics, and the nearest surface's motion so
    // edges of moving objects follow the object rather than the background.
    float3 moment1 = 0.0f;
    float3 moment2 = 0.0f;
    float closest_depth = 1.0f;
    int2 closest_pixel = pixel;
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            int2 q = clamp(pixel + int2(x, y), int2(0, 0), last);
            float3 c = RgbToYCoCg(TaaCompress(g_hdr_texture.Load(int3(q, 0)).rgb));
            moment1 += c;
            moment2 += c * c;
            float depth = g_depth.Load(int3(q, 0));
            if (depth < closest_depth)
            {
                closest_depth = depth;
                closest_pixel = q;
            }
        }
    }
    float3 mean = moment1 / 9.0f;
    float3 sigma = sqrt(max(moment2 / 9.0f - mean * mean, 0.0f));
    float3 box_min = mean - TAA_CLIP_SIGMA * sigma;
    float3 box_max = mean + TAA_CLIP_SIGMA * sigma;

    float2 history_uv = input.uv - g_velocity.Load(int3(closest_pixel, 0));
    if (any(history_uv < 0.0f) || any(history_uv > 1.0f))
    {
        return float4(current, 1.0f); // Newly revealed at the screen edge.
    }

    float3 history = RgbToYCoCg(TaaCompress(SampleHistoryCatmullRom(history_uv)));
    history = YCoCgToRgb(ClipToBox(history, box_min, box_max));

    float3 blended = lerp(history, TaaCompress(current), taa_blend);
    return float4(TaaDecompress(blended), 1.0f);
}
