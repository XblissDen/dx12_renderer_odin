Texture2D<float4> g_environment : register(t2);
SamplerState g_sampler : register(s0);

cbuffer PrefilterConstants : register(b3)
{
    float material_roughness;
    float3 _pad0;
};

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

float2 DirectionToUV(float3 direction)
{
    return float2(
        atan2(direction.z, direction.x) / (2.0f * 3.14159265f) + 0.5f,
        acos(clamp(direction.y, -1.0f, 1.0f)) / 3.14159265f
    );
}

float4 PSMain(VSOutput input) : SV_TARGET
{
    const float PI = 3.14159265f;

    float phi = (input.uv.x - 0.5f) * 2.0f * PI;
    float theta = input.uv.y * PI;

    float3 N = float3(
        sin(theta) * cos(phi),
        cos(theta),
        sin(theta) * sin(phi)
    );

    // The smoothest mip is a direct reflection of the panorama.
    if (material_roughness < 0.001f)
    {
        return g_environment.SampleLevel(
            g_sampler, DirectionToUV(N), 0
        );
    }

    float3 helper = abs(N.y) < 0.99f
        ? float3(0, 1, 0)
        : float3(0, 0, 1);
    float3 tangent = normalize(cross(helper, N));
    float3 bitangent = cross(N, tangent);

    float3 sum = 0.0f;
    float total_weight = 0.0f;

    float a = max(material_roughness * material_roughness, 0.001f);
    float a2 = a * a;

    // 16 × 8 samples, concentrated according to GGX roughness.
    for (uint i = 0u; i < 128u; ++i)
    {
        float2 xi = float2(
            (float(i & 15u) + 0.5f) / 16.0f,
            (float(i >> 4) + 0.5f) / 8.0f
        );

        float azimuth = 2.0f * PI * xi.x;
        float cos_theta = sqrt(
            (1.0f - xi.y) / (1.0f + (a2 - 1.0f) * xi.y)
        );
        float sin_theta = sqrt(max(1.0f - cos_theta * cos_theta, 0.0f));

        float3 H = normalize(
            tangent * (sin_theta * cos(azimuth)) +
            bitangent * (sin_theta * sin(azimuth)) +
            N * cos_theta
        );

        // Approximate the view direction as N during prefiltering.
        float3 L = normalize(2.0f * dot(N, H) * H - N);
        float weight = max(dot(N, L), 0.0f);

        if (weight > 0.0f)
        {
            sum += g_environment.SampleLevel(
                g_sampler, DirectionToUV(L), 0
            ).rgb * weight;
            total_weight += weight;
        }
    }

    return float4(sum / max(total_weight, 0.0001f), 1.0f);
}