#define MAX_LIGHTS 4

struct GpuPointLight
{
    float3 position;
    float  _pad0;
    float3 color;
    float  intensity;
};

cbuffer SceneConstants : register(b0)
{
    float4x4 model;
    float4x4 view;
    float4x4 projection;

    float3 view_position;
    float  _pad0;

    float3 material_tint;
    float  _pad1;

    uint  light_count;
    uint  unlit;
    float roughness;
    float metallic;

    GpuPointLight lights[MAX_LIGHTS];

    float3 sun_direction;
    float  _sun_pad0;
    float3 sun_color;
    float  sun_intensity;

    float4 _sun_matrix_pad;
    float4x4 sun_view_projection;
};

Texture2D    g_texture : register(t0);
SamplerState g_sampler : register(s0);
Texture2D<float> g_shadow_map : register(t1);
SamplerComparisonState g_shadow_sampler : register(s1);
Texture2D<float4> g_irradiance : register(t3);
Texture2D<float4> g_prefiltered_environment : register(t4);

struct VSInput
{
    float3 position : POSITION;
    float3 normal   : NORMAL;
    float2 texcoord : TEXCOORD;
};

struct PSInput
{
    float4 position     : SV_POSITION;
    float3 world_pos    : TEXCOORD0;
    float3 normal       : NORMAL;
    float2 texcoord     : TEXCOORD1;
    float4 shadow_position : TEXCOORD2;
};

PSInput VSMain(VSInput input)
{
    PSInput output;

    float4 world_pos = mul(float4(input.position, 1.0f), model);
    output.world_pos = world_pos.xyz;
    output.shadow_position = mul(world_pos, sun_view_projection);

    float4 pos = world_pos;
    pos = mul(pos, view);
    pos = mul(pos, projection);
    output.position = pos;

    output.normal = mul(input.normal, (float3x3)model);
    output.texcoord = input.texcoord;

    return output;
}

float4 VSShadow(VSInput input) : SV_POSITION
{
    float4 world_pos = mul(float4(input.position, 1.0f), model);
    return mul(world_pos, sun_view_projection);
}

static const float PI = 3.14159265f;

float3 FresnelSchlick(float cos_theta, float3 F0)
{
    return F0 + (1.0f - F0) * pow(1.0f - saturate(cos_theta), 5.0f);
}

float DistributionGGX(float3 N, float3 H, float material_roughness)
{
    float a = material_roughness * material_roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0f);

    float denominator = NdotH * NdotH * (a2 - 1.0f) + 1.0f;
    return a2 / max(PI * denominator * denominator, 0.000000001f);
}

float GeometrySchlickGGX(float NdotV, float material_roughness)
{
    float r = material_roughness + 1.0f;
    float k = (r * r) / 8.0f;

    return NdotV / (NdotV * (1.0f - k) + k);
}

float GeometrySmith(float3 N, float3 V, float3 L, float material_roughness)
{
    float NdotV = max(dot(N, V), 0.0f);
    float NdotL = max(dot(N, L), 0.0f);

    return GeometrySchlickGGX(NdotV, material_roughness) *
           GeometrySchlickGGX(NdotL, material_roughness);
}

float3 EvaluateDirectLight(
    float3 N,
    float3 V,
    float3 L,
    float3 albedo,
    float material_roughness,
    float material_metallic,
    float3 radiance
)
{
    float NdotL = max(dot(N, L), 0.0f);
    float NdotV = max(dot(N, V), 0.0f);

    float3 halfway = V + L;
    float3 H = halfway * rsqrt(max(dot(halfway, halfway), 0.00000001f));

    float3 F0 = lerp(float3(0.04f, 0.04f, 0.04f), albedo, material_metallic);

    float3 F = FresnelSchlick(max(dot(H, V), 0.0f), F0);
    float D = DistributionGGX(N, H, material_roughness);
    float G = GeometrySmith(N, V, L, material_roughness);

    float3 specular = (D * G * F) / max(4.0f * NdotV * NdotL, 0.0001f);
    float3 diffuse = (1.0f - F) * (1.0f - material_metallic) * albedo / PI;

    return (diffuse + specular) * radiance * NdotL * step(0.00001f, NdotV);
}

float2 EnvBRDFApprox(float NdotV, float material_roughness)
{
    float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f);
    float4 c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = material_roughness * c0 + c1;

    float a004 = min(r.x * r.x, exp2(-9.28f * NdotV)) * r.x + r.y;
    return max(float2(-1.04f, 1.04f) * a004 + r.zw, 0.0f);
}

float4 PSMain(PSInput input) : SV_TARGET
{
    if (unlit != 0)
    {
        return float4(material_tint * 4.0f, 1.0f);
    }

    // Our texture SRV is UNORM, so decode its sRGB-style image values manually.
    float3 texture_color = g_texture.Sample(g_sampler, input.texcoord).rgb;
    float3 albedo = pow(saturate(texture_color), 2.2f) * material_tint;

    float material_roughness = clamp(roughness, 0.08f, 1.0f);
    float material_metallic = saturate(metallic);

    float3 N = normalize(input.normal);
    float3 V = normalize(view_position - input.world_pos);
    float3 sun_L = normalize(-sun_direction);

    // indirect/environment lighting.
    float2 normal_uv = float2(
        atan2(N.z, N.x) / (2.0f * 3.14159265f) + 0.5f,
        acos(clamp(N.y, -1.0f, 1.0f)) / 3.14159265f
    );

    float3 incoming_diffuse = g_irradiance.SampleLevel(
        g_sampler, normal_uv, 0
    ).rgb;

    float3 ambient_F0 = lerp(
        float3(0.04f, 0.04f, 0.04f),
        albedo,
        material_metallic
    );
    float3 ambient_F = FresnelSchlick(
        max(dot(N, V), 0.0f),
        ambient_F0
    );
    float3 ambient_kD = (1.0f - ambient_F) * (1.0f - material_metallic);

    float3 result = ambient_kD * albedo * incoming_diffuse;

    // sample reflections by roughness
    float3 reflection = reflect(-V, N);

    float2 reflection_uv = float2(
        atan2(reflection.z, reflection.x) /
            (2.0f * 3.14159265f) + 0.5f,
        acos(clamp(reflection.y, -1.0f, 1.0f)) / 3.14159265f
    );

    float3 prefiltered_color = g_prefiltered_environment.SampleLevel(
        g_sampler,
        reflection_uv,
        material_roughness * 4.0f
    ).rgb;

    float2 environment_brdf = EnvBRDFApprox(
        max(dot(N, V), 0.0f),
        material_roughness
    );

    result += prefiltered_color *
            (ambient_F0 * environment_brdf.x + environment_brdf.y);


    float sun_visibility = 1.0f;

    if (input.shadow_position.w > 0.0f)
    {
        float3 shadow_ndc =
            input.shadow_position.xyz / input.shadow_position.w;

        float2 shadow_uv = float2(
            shadow_ndc.x * 0.5f + 0.5f,
            0.5f - shadow_ndc.y * 0.5f
        );

        if (all(shadow_uv >= 0.0f) &&
            all(shadow_uv <= 1.0f) &&
            shadow_ndc.z >= 0.0f &&
            shadow_ndc.z <= 1.0f)
        {
            uint shadow_width, shadow_height;
            g_shadow_map.GetDimensions(shadow_width, shadow_height);
            float2 texel_size = 1.0f / float2(shadow_width, shadow_height);

            float shadow_bias = 0.001f;

            sun_visibility = 0.0f;

            for (int y = -1; y <= 1; ++y)
            {
                for (int x = -1; x <= 1; ++x)
                {
                    float2 sample_uv = shadow_uv + float2(x, y) * texel_size;

                    sun_visibility += g_shadow_map.SampleCmpLevelZero(
                        g_shadow_sampler,
                        sample_uv,
                        shadow_ndc.z - shadow_bias
                    );
                }
            }

            sun_visibility /= 9.0f;
        }
    }

    float3 sun_radiance = sun_color * sun_intensity * sun_visibility;
    result += EvaluateDirectLight(
        N, V, sun_L, albedo,
        material_roughness, material_metallic,
        sun_radiance
    );

    for (uint i = 0; i < light_count; ++i)
    {
        float3 to_light = lights[i].position - input.world_pos;
        float distance_squared = dot(to_light, to_light);
        float3 L = to_light * rsqrt(max(distance_squared, 0.0001f));

        float attenuation = lights[i].intensity / (1.0f + distance_squared);
        float3 radiance = lights[i].color * attenuation;

        result += EvaluateDirectLight(
            N, V, L, albedo,
            material_roughness, material_metallic,
            radiance
        );
    }

    return float4(result, 1.0f);
}