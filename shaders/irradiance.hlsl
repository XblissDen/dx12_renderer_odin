// Bakes the irradiance map, a small panorama of diffuse light: for each
// surface normal, the panorama's light averaged over the hemisphere around
// it, weighted by the cosine.

#include "common.hlsl"

Texture2D<float4> g_environment : register(t2);
SamplerState g_sampler : register(s3);

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

float4 PSMain(VSOutput input) : SV_TARGET
{
    // This output pixel represents one surface-normal direction.
    float3 N = UVToDirection(input.uv);

    // Build two axes perpendicular to N.
    float3 helper = abs(N.y) < 0.99f
        ? float3(0, 1, 0)
        : float3(0, 0, 1);
    float3 tangent = normalize(cross(helper, N));
    float3 bitangent = cross(N, tangent);

    uint source_width, source_height, source_mips;
    g_environment.GetDimensions(0, source_width, source_height, source_mips);
    float3 sum = 0.0f;
    const uint SAMPLE_COUNT = 1024u;
    [loop]
    for (uint i = 0u; i < SAMPLE_COUNT; ++i)
    {
        // Cosine-weighted Hammersley directions: cos(theta)/PI is the PDF,
        // so irradiance/PI is the unweighted mean of the sampled radiance.
        float2 xi = float2(
            (float(i) + 0.5f) / float(SAMPLE_COUNT),
            float(reversebits(i)) * 2.3283064365386963e-10f
        );
        float radius = sqrt(xi.x);
        float azimuth = 2.0f * PI * xi.y;
        float NdotL = sqrt(1.0f - xi.x);
        float3 direction = normalize(
            tangent * (radius * cos(azimuth)) +
            bitangent * (radius * sin(azimuth)) + N * NdotL
        );

        float sin_theta_L = sqrt(saturate(1.0f - direction.y * direction.y));
        float texel_solid_angle = (2.0f * PI * PI) *
            max(sin_theta_L, sin(0.5f * PI / float(source_height))) /
            (float(source_width) * float(source_height));
        float sample_solid_angle = PI / (float(SAMPLE_COUNT) * NdotL);
        // Overlapping footprints keep small HDR suns from exposing the sample pattern.
        float source_lod = clamp(
            0.5f * log2(sample_solid_angle / texel_solid_angle) + 1.0f,
            0.0f, float(source_mips - 1u)
        );
        sum += g_environment.SampleLevel(
            g_sampler, DirectionToUV(direction), source_lod
        ).rgb;
    }

    // Cosine-weighted mean incoming light for this normal.
    return float4(sum / float(SAMPLE_COUNT), 1.0f);
}
