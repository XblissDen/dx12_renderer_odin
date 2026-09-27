Texture2D<float4> g_hdr_texture : register(t0);
Texture2D<float4> g_bloom_texture : register(t1);
SamplerState g_sampler : register(s0);

cbuffer PostConstants : register(b1)
{
    float exposure;
    float bloom_threshold;
    float bloom_strength;
    float _pad0;
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

float4 PSMain(VSOutput input) : SV_TARGET
{
    float3 hdr_color = g_hdr_texture.Sample(g_sampler, input.uv).rgb;
    float3 bloom_color = g_bloom_texture.Sample(g_sampler, input.uv).rgb;

    hdr_color += bloom_color * bloom_strength;

    float3 exposed_color = hdr_color * exposure;
    float3 mapped = exposed_color / (exposed_color + 1.0f);
    float3 display_color = pow(saturate(mapped), 1.0f / 2.2f);

    return float4(display_color, 1.0f);
}