// Builds one mip level of a material texture from the level above it with a
// 2x2 box filter. For odd sizes the last row or column of the larger level is
// dropped, as D3D's mip sizes (half, rounded down) imply.
//
// Both levels are bound as plain UNORM views, so the shader sees the stored
// bytes and does the sRGB conversion and the rounding itself. The hardware's
// sRGB encode and float-to-UNORM rounding are only specified within a
// tolerance, and the error would grow level after level. Doing both here
// matches an exact CPU box filter: data maps bit for bit, colors and normals
// apart from a few texels one step off (pow and normalize precision).

Texture2D<float4> g_source_mip : register(t0);

#define MIP_DATA   0u // Linear values (roughness, metallic, occlusion).
#define MIP_SRGB   1u // sRGB color with linear alpha (albedo, emissive).
#define MIP_NORMAL 2u // Tangent-space directions.

cbuffer MipConstants : register(b6)
{
    uint mip_mode;
};

struct FullscreenInput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

// The exact sRGB transfer functions.
float SrgbToLinear(float value)
{
    // The bases are never negative; max() lets the compiler see that (X3571).
    return value <= 0.04045f ? value / 12.92f : pow(max((value + 0.055f) / 1.055f, 0.0f), 2.4f);
}

float LinearToSrgb(float value)
{
    return value <= 0.0031308f ? value * 12.92f : 1.055f * pow(max(value, 0.0f), 1.0f / 2.4f) - 0.055f;
}

// The nearest 8-bit value, halves rounding up, which the target then stores
// exactly.
float4 Quantize(float4 value)
{
    return floor(saturate(value) * 255.0f + 0.5f) / 255.0f;
}

float4 PSDownsample(FullscreenInput input) : SV_TARGET
{
    uint width, height;
    g_source_mip.GetDimensions(width, height);
    int2 last = int2(width, height) - 1;
    int2 base = int2(input.position.xy) * 2;

    float4 sum = 0.0f;
    float3 normal = 0.0f;
    [unroll]
    for (int y = 0; y < 2; ++y)
    {
        [unroll]
        for (int x = 0; x < 2; ++x)
        {
            // Clamped: a 1-pixel-wide level repeats its only column.
            float4 texel = g_source_mip.Load(int3(min(base + int2(x, y), last), 0));
            if (mip_mode == MIP_NORMAL)
            {
                normal += texel.xyz * 2.0f - 1.0f;
            }
            else if (mip_mode == MIP_SRGB)
            {
                sum += float4(SrgbToLinear(texel.r), SrgbToLinear(texel.g), SrgbToLinear(texel.b), texel.a);
            }
            else
            {
                sum += texel;
            }
        }
    }

    if (mip_mode == MIP_NORMAL)
    {
        // Average directions, not encoded values.
        normal = dot(normal, normal) > 0.00000001f ? normalize(normal) : float3(0.0f, 0.0f, 1.0f);
        return Quantize(float4(normal * 0.5f + 0.5f, 1.0f));
    }
    float4 average = sum * 0.25f;
    if (mip_mode == MIP_SRGB)
    {
        average.rgb = float3(LinearToSrgb(average.r), LinearToSrgb(average.g), LinearToSrgb(average.b));
    }
    return Quantize(average);
}
