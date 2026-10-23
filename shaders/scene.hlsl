#define MAX_LIGHTS 16

struct GpuPointLight
{
    float3 position;
    float  _pad0;
    float3 color;
    float  intensity;
};

// Per-draw data.
cbuffer ObjectConstants : register(b0)
{
    float4x4 model;
    // Upper 3x3 is the inverse model matrix; mul(normal, it) applies the
    // inverse transpose, which keeps normals correct under non-uniform scale.
    float4x4 normal_matrix;

    float3 material_tint;
    float  uv_scale;

    float roughness;
    float metallic;
    float normal_strength;
    uint  unlit;

    uint use_roughness_map;
    uint use_metallic_map;
    float2 _object_pad;
};

// Shared by every draw in a frame.
cbuffer FrameConstants : register(b4)
{
    float4x4 view;
    float4x4 projection;
    float4x4 sun_view_projection;

    float3 view_position;
    uint   light_count;

    float3 sun_direction;
    float  sun_intensity;

    float3 sun_color;
    float  environment_intensity;

    float environment_sin;
    float environment_cos;
    float ambient_intensity;
    uint  ambient_mode;

    float3 ambient_color;
    float  shadow_bias_constant;

    float  shadow_bias_slope;
    float  shadow_fade_start;
    float  shadow_fade_end;
    float  _frame_pad;

    GpuPointLight lights[MAX_LIGHTS];
};

Texture2D    g_texture : register(t0);
SamplerState g_sampler : register(s0);
SamplerState g_material_sampler : register(s2);
SamplerState g_environment_sampler : register(s3);
Texture2D<float> g_shadow_map : register(t1);
SamplerComparisonState g_shadow_sampler : register(s1);
Texture2D<float4> g_irradiance : register(t3);
Texture2D<float4> g_prefiltered_environment : register(t4);
Texture2D<float4> g_normal_map : register(t5);
Texture2D<float4> g_roughness_map : register(t6);
Texture2D<float4> g_metallic_map : register(t7);

struct VSInput
{
    float3 position : POSITION;
    float3 normal   : NORMAL;
    float2 texcoord : TEXCOORD;
    float4 tangent : TANGENT;
};

struct PSInput
{
    float4 position     : SV_POSITION;
    float3 world_pos    : TEXCOORD0;
    float3 normal       : NORMAL;
    float2 texcoord     : TEXCOORD1;
    float4 shadow_position : TEXCOORD2;
    float4 tangent : TEXCOORD3;
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

    output.normal = mul(input.normal, (float3x3)normal_matrix);
    output.texcoord = input.texcoord;
    output.tangent = float4(
        mul(input.tangent.xyz, (float3x3)model),
        input.tangent.w
    );

    return output;
}

float4 VSShadow(VSInput input) : SV_POSITION
{
    float4 world_pos = mul(float4(input.position, 1.0f), model);
    return mul(world_pos, sun_view_projection);
}

static const float PI = 3.14159265f;

float3 EnvironmentDirection(float3 direction)
{
    // Inverse world Y rotation keeps lighting and the visible panorama aligned.
    return float3(
        environment_cos * direction.x - environment_sin * direction.z,
        direction.y,
        environment_sin * direction.x + environment_cos * direction.z
    );
}

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

float FilterSpecularRoughness(float material_roughness, float3 N)
{
    // Unresolved normal-map detail needs a wider specular lobe, not isolated
    // subpixel glints. GGX alpha is perceptual roughness squared.
    float3 normal_dx = ddx(N);
    float3 normal_dy = ddy(N);
    float variance = 0.5f * (dot(normal_dx, normal_dx) + dot(normal_dy, normal_dy));
    float kernel = min(2.0f * variance, 0.18f);
    float alpha = material_roughness * material_roughness;
    return pow(saturate(alpha * alpha + kernel), 0.25f);
}

float4 PSMain(PSInput input) : SV_TARGET
{
    if (unlit != 0)
    {
        return float4(material_tint * 4.0f, 1.0f);
    }

    // Albedo SRVs are _SRGB, so the sampler returns filtered linear values.
    float2 material_uv = input.texcoord * uv_scale;

    float3 albedo = g_texture.Sample(
        g_material_sampler, material_uv
    ).rgb * material_tint;

    float roughness_value = roughness;

    if (use_roughness_map != 0)
    {
        roughness_value *= g_roughness_map.Sample(
            g_material_sampler, material_uv
        ).r;
    }

    float material_roughness = clamp(roughness_value, 0.08f, 1.0f);
    
    float metallic_value = metallic;
    if (use_metallic_map != 0)
    {
        metallic_value *= g_metallic_map.Sample(
            g_material_sampler, material_uv
        ).r;
    }
    float material_metallic = saturate(metallic_value);
    
    float3 N = normalize(input.normal);
    if (normal_strength > 0.0f)
    {
        // Rebuild an orthogonal surface basis after interpolation.
        float3 T = normalize(
            input.tangent.xyz - N * dot(N, input.tangent.xyz)
        );
        float3 B = cross(N, T) * input.tangent.w;

        // Normal maps encode signed directions in unsigned RGB channels.
        float3 tangent_normal = g_normal_map.Sample(
            g_material_sampler, material_uv
        ).xyz * 2.0f - 1.0f;

        tangent_normal.xy *= normal_strength;

        N = normalize(
            T * tangent_normal.x +
            B * tangent_normal.y +
            N * tangent_normal.z
        );
    }
    material_roughness = FilterSpecularRoughness(material_roughness, N);
    float3 V = normalize(view_position - input.world_pos);
    float3 sun_L = normalize(-sun_direction);

    // A constant-color environment supplies both diffuse and specular radiance,
    // keeping metals illuminated even without a panorama.
    float3 incoming_diffuse = ambient_color * ambient_intensity;
    float3 prefiltered_color = incoming_diffuse;
    [branch]
    if (ambient_mode == 0u) // HDRI
    {
        float3 environment_normal = EnvironmentDirection(N);
        float2 normal_uv = float2(
            atan2(environment_normal.z, environment_normal.x) / (2.0f * PI) + 0.5f,
            acos(clamp(environment_normal.y, -1.0f, 1.0f)) / PI
        );
        incoming_diffuse = g_irradiance.SampleLevel(
            g_environment_sampler, normal_uv, 0
        ).rgb * environment_intensity;

        float3 reflection = EnvironmentDirection(reflect(-V, N));
        float2 reflection_uv = float2(
            atan2(reflection.z, reflection.x) / (2.0f * PI) + 0.5f,
            acos(clamp(reflection.y, -1.0f, 1.0f)) / PI
        );
        prefiltered_color = g_prefiltered_environment.SampleLevel(
            g_environment_sampler, reflection_uv, material_roughness * 4.0f
        ).rgb * environment_intensity;
    }

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

            // Use the interpolated geometric normal: normal-map detail does
            // not change the depth stored in the shadow map.
            float geometric_n_dot_l = saturate(
                dot(normalize(input.normal), sun_L)
            );
            float tan_angle = min(
                sqrt(1.0f - geometric_n_dot_l * geometric_n_dot_l) /
                    max(geometric_n_dot_l, 0.0001f),
                10.0f
            );
            float shadow_bias = shadow_bias_constant +
                                shadow_bias_slope * tan_angle;

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

    // The shadow map covers the view up to the shadow distance; fade out
    // before its edge instead of cutting off along a visible line.
    float view_distance = length(view_position - input.world_pos);
    float shadow_fade = saturate(
        (view_distance - shadow_fade_start) /
        max(shadow_fade_end - shadow_fade_start, 0.0001f)
    );
    sun_visibility = lerp(sun_visibility, 1.0f, shadow_fade);

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
