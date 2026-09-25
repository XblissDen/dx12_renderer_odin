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
    uint2 _pad2;

    GpuPointLight lights[MAX_LIGHTS];

    float3 sun_direction;
    float  _sun_pad0;
    float3 sun_color;
    float  sun_intensity;
};

Texture2D    g_texture : register(t0);
SamplerState g_sampler : register(s0);

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
};

PSInput VSMain(VSInput input)
{
    PSInput output;

    float4 world_pos = mul(float4(input.position, 1.0f), model);
    output.world_pos = world_pos.xyz;

    float4 pos = world_pos;
    pos = mul(pos, view);
    pos = mul(pos, projection);
    output.position = pos;

    // Нормаль трансформируем матрицей model
    // (упрощение — для неравномерного масштаба нужна inverse-transpose, но нам пока хватит)
    output.normal = mul(input.normal, (float3x3)model);
    output.texcoord = input.texcoord;

    return output;
}

float4 PSMain(PSInput input) : SV_TARGET
{
    if (unlit != 0)
    {
        return float4(material_tint, 1.0f);
    }
    float3 albedo = g_texture.Sample(g_sampler, input.texcoord).rgb * material_tint;

    float3 N = normalize(input.normal);
    float3 V = normalize(view_position - input.world_pos);

    // ambient light
    float3 result = 0.1f * albedo;

    // directional light
    float3 sun_L = normalize(-sun_direction);
    float sun_diffuse = max(dot(N, sun_L), 0.0f);

    float sun_specular = 0.0f;
    if (sun_diffuse > 0.0f)
    {
        float3 sun_R = reflect(-sun_L, N);
        sun_specular = pow(max(dot(V, sun_R), 0.0f), 32.0f) * 0.5f;
    }

    result += (sun_diffuse + sun_specular) * sun_color * sun_intensity * albedo;

    // point light
    for (uint i = 0; i < light_count; ++i)
    {
        float3 to_light = lights[i].position - input.world_pos;
        float distance_squared = dot(to_light, to_light);

        // The minimum keeps normalization well-defined at the light's position.
        float3 L = to_light * rsqrt(max(distance_squared, 0.0001f));
        float attenuation = lights[i].intensity / (1.0f + distance_squared);

        float diffuse = max(dot(N, L), 0.0f);

        float3 R = reflect(-L, N);
        float specular = 0.0f;
        if (diffuse > 0.0f)
        {
            specular = pow(max(dot(V, R), 0.0f), 32.0f) * 0.5f;
        }

        result += (diffuse + specular) * lights[i].color * albedo * attenuation;
    }
    return float4(result, 1.0f);
}