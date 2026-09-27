Texture2D<float4> g_environment : register(t2);
SamplerState g_sampler : register(s0);

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

    // This output pixel represents one surface-normal direction.
    float phi = (input.uv.x - 0.5f) * 2.0f * PI;
    float theta = input.uv.y * PI;
    float3 N = float3(
        sin(theta) * cos(phi),
        cos(theta),
        sin(theta) * sin(phi)
    );

    // Build two axes perpendicular to N.
    float3 helper = abs(N.y) < 0.99f
        ? float3(0, 1, 0)
        : float3(0, 0, 1);
    float3 tangent = normalize(cross(helper, N));
    float3 bitangent = cross(N, tangent);

    float3 sum = 0.0f;
    float total_weight = 0.0f;

    // Sample 128 directions across the hemisphere above N.
    for (int t = 0; t < 8; ++t)
    {
        float a = (float(t) + 0.5f) * (0.5f * PI / 8.0f);
        float s = sin(a);
        float c = cos(a);
        float weight = s * c;

        for (int p = 0; p < 16; ++p)
        {
            float b = (float(p) + 0.5f) * (2.0f * PI / 16.0f);
            float3 direction = normalize(
                tangent * (s * cos(b)) +
                bitangent * (s * sin(b)) +
                N * c
            );

            sum += g_environment.SampleLevel(
                g_sampler, DirectionToUV(direction), 0
            ).rgb * weight;
            total_weight += weight;
        }
    }

    // Cosine-weighted mean incoming light for this normal.
    return float4(sum / max(total_weight, 0.0001f), 1.0f);
}