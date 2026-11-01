// Bakes one mip of a prefiltered specular map (the split-sum approximation):
// for each reflection direction, the incoming light averaged over the GGX
// lobe of this mip's roughness. PSMain filters the HDR panorama; the probe
// entry points filter a reflection probe's capture (renderer_probes.odin),
// one cube face per draw.

#include "common.hlsl"

Texture2D<float4> g_environment : register(t2);
// A probe capture: as a cube for prefiltering, and one level's six faces as
// slices for building the next level.
TextureCube<float4> g_probe_capture : register(t0);
Texture2DArray<float4> g_probe_capture_level : register(t1);
SamplerState g_sampler : register(s3);

cbuffer PrefilterConstants : register(b3)
{
    float material_roughness;
    uint face; // Probes: the cube face being drawn.
    uint sample_count;
    float _pad0;
};

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

// The direction through a point of a cube face, in D3D's face order and
// orientation (+X, -X, +Y, -Y, +Z, -Z; v runs down each face).
float3 CubeFaceDirection(uint cube_face, float2 uv)
{
    float s = uv.x * 2.0f - 1.0f;
    float t = uv.y * 2.0f - 1.0f;
    float3 directions[6] = {
        float3(1.0f, -t, -s), float3(-1.0f, -t, s),
        float3(s, 1.0f, t), float3(s, -1.0f, -t),
        float3(s, -t, 1.0f), float3(-s, -t, -1.0f),
    };
    return normalize(directions[cube_face]);
}

// The source's light around N over the GGX lobe of material_roughness, from
// sample_count importance samples. Each sample reads the source at the mip
// whose texels match its share of the lobe, so a few samples cover it
// without picking out single bright texels. `cube` chooses the probe capture
// over the panorama.
float3 PrefilterGGX(float3 N, bool cube)
{
    uint source_width, source_height, source_mips;
    if (cube) g_probe_capture.GetDimensions(0, source_width, source_height, source_mips);
    else g_environment.GetDimensions(0, source_width, source_height, source_mips);

    float3 helper = abs(N.y) < 0.99f
        ? float3(0, 1, 0)
        : float3(0, 0, 1);
    float3 tangent = normalize(cross(helper, N));
    float3 bitangent = cross(N, tangent);

    float3 sum = 0.0f;
    float total_weight = 0.0f;

    float a = max(material_roughness * material_roughness, 0.001f);
    float a2 = a * a;

    [loop]
    for (uint i = 0u; i < sample_count; ++i)
    {
        // Hammersley points, spread evenly over the GGX lobe.
        float2 xi = float2(
            (float(i) + 0.5f) / float(sample_count),
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

            // A panorama texel's solid angle shrinks towards the poles; a
            // cube's is close to even (a sixth of the sphere per face).
            float texel_solid_angle;
            if (cube)
            {
                texel_solid_angle = 4.0f * PI / (6.0f * float(source_width) * float(source_width));
            }
            else
            {
                float sin_theta_L = sqrt(saturate(1.0f - L.y * L.y));
                texel_solid_angle = (2.0f * PI * PI) *
                    max(sin_theta_L, sin(0.5f * PI / float(source_height))) /
                    (float(source_width) * float(source_height));
            }
            float sample_solid_angle = 1.0f / (float(sample_count) * pdf);
            // Overlap neighboring sample footprints to avoid resolving the
            // finite sampling pattern around extremely concentrated lights.
            float source_lod = clamp(
                0.5f * log2(sample_solid_angle / texel_solid_angle) + 1.0f,
                0.0f, float(source_mips - 1u)
            );

            float3 sample_color = cube
                ? g_probe_capture.SampleLevel(g_sampler, L, source_lod).rgb
                : g_environment.SampleLevel(g_sampler, DirectionToUV(L), source_lod).rgb;
            sum += sample_color * weight;
            total_weight += weight;
        }
    }

    return sum / max(total_weight, 0.0001f);
}

float4 PSMain(VSOutput input) : SV_TARGET
{
    // Downsample the mirror level with its output-pixel footprint too, rather
    // than point-sampling a 4K sun into a lower-resolution reflection map.
    if (material_roughness < 0.001f)
    {
        return g_environment.SampleGrad(
            g_sampler, input.uv, ddx(input.uv), ddy(input.uv)
        );
    }
    return float4(PrefilterGGX(UVToDirection(input.uv), false), 1.0f);
}

// One face of a probe level. The mirror level is the capture itself, at the
// same size.
float4 PSProbePrefilter(VSOutput input) : SV_TARGET
{
    float3 N = CubeFaceDirection(face, input.uv);
    if (material_roughness < 0.001f)
    {
        return float4(g_probe_capture.SampleLevel(g_sampler, N, 0.0f).rgb, 1.0f);
    }
    return float4(PrefilterGGX(N, true), 1.0f);
}

// One face of the next capture level: the average of the 2 x 2 texels above.
float4 PSProbeDownsample(VSOutput input) : SV_TARGET
{
    int2 texel = int2(input.position.xy) * 2;
    float4 sum = 0.0f;
    [unroll]
    for (int y = 0; y < 2; ++y)
        [unroll]
        for (int x = 0; x < 2; ++x)
            sum += g_probe_capture_level.Load(int4(texel + int2(x, y), face, 0));
    return sum * 0.25f;
}
