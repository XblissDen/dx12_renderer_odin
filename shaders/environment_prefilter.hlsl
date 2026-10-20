Texture2D<float4> g_environment : register(t2);
SamplerState g_sampler : register(s3);

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

    uint source_width, source_height, source_mips;
    g_environment.GetDimensions(0, source_width, source_height, source_mips);

    // Downsample the mirror level with its output-pixel footprint too, rather
    // than point-sampling a 4K sun into a lower-resolution reflection map.
    if (material_roughness < 0.001f)
    {
        return g_environment.SampleGrad(
            g_sampler, input.uv, ddx(input.uv), ddy(input.uv)
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

    const uint SAMPLE_COUNT = 1024u;
    [loop]
    for (uint i = 0u; i < SAMPLE_COUNT; ++i)
    {
        // Hammersley samples cover the GGX lobe without the old 16 x 8 grid.
        float2 xi = float2(
            (float(i) + 0.5f) / float(SAMPLE_COUNT),
            float(reversebits(i)) * 2.3283064365386963e-10f
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
            float NdotH = saturate(dot(N, H));
            float VdotH = NdotH; // V = N for the split-sum prefilter.
            float denominator = NdotH * NdotH * (a2 - 1.0f) + 1.0f;
            float D = a2 / max(PI * denominator * denominator, 1.0e-10f);
            float pdf = max(D * NdotH / max(4.0f * VdotH, 1.0e-6f), 1.0e-6f);

            // A panorama texel's solid angle shrinks towards the poles.
            float sin_theta_L = sqrt(saturate(1.0f - L.y * L.y));
            float texel_solid_angle = (2.0f * PI * PI) *
                max(sin_theta_L, sin(0.5f * PI / float(source_height))) /
                (float(source_width) * float(source_height));
            float sample_solid_angle = 1.0f / (float(SAMPLE_COUNT) * pdf);
            // Overlap neighboring sample footprints to avoid resolving the
            // finite sampling pattern around extremely concentrated lights.
            float source_lod = clamp(
                0.5f * log2(sample_solid_angle / texel_solid_angle) + 1.0f,
                0.0f, float(source_mips - 1u)
            );

            sum += g_environment.SampleLevel(
                g_sampler, DirectionToUV(L), source_lod
            ).rgb * weight;
            total_weight += weight;
        }
    }

    return float4(sum / max(total_weight, 0.0001f), 1.0f);
}
