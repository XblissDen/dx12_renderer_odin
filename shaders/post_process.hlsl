Texture2D<float4> g_hdr_texture : register(t0);
Texture2D<float4> g_bloom_texture : register(t1);
SamplerState g_sampler : register(s0);

cbuffer PostConstants : register(b1)
{
    float exposure;
    float bloom_threshold;
    float bloom_strength;
    uint  tone_mapper; // 0 Reinhard, 1 ACES, 2 AgX
};

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