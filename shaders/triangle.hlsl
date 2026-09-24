#define MAX_LIGHTS 4

struct GpuPointLight
{
    float3 position;
    float  _pad0;
    float3 color;
    float  _pad1;
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
    uint3 _pad2;

    GpuPointLight lights[MAX_LIGHTS];
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
    float3 albedo = g_texture.Sample(g_sampler, input.texcoord).rgb * material_tint;

    float3 N = normalize(input.normal);
    float3 V = normalize(view_position - input.world_pos);

    float3 result = 0.1f * albedo;

    for (uint i = 0; i < light_count; ++i)
    {
        float3 L = normalize(lights[i].position - input.world_pos);
        float diffuse = max(dot(N, L), 0.0f);

        float3 R = reflect(-L, N);
        float specular = 0.0f;
        if (diffuse > 0.0f)
        {
            specular = pow(max(dot(V, R), 0.0f), 32.0f) * 0.5f;
        }

        result += (diffuse + specular) * lights[i].color * albedo;
    }
    return float4(result, 1.0f);
}