cbuffer SceneConstants : register(b0)
{
    float4x4 model;
    float4x4 view;
    float4x4 projection;
    float3   light_position;
    float    _pad0;
    float3   view_position;
    float    _pad1;
    float3   light_color;
    float    _pad2;
    float3 material_tint;
    float  _pad3;
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
    float3 L = normalize(light_position - input.world_pos);
    float3 V = normalize(view_position - input.world_pos);
    float3 R = reflect(-L, N);

    // Ambient — минимальная базовая подсветка
    float3 ambient = 0.1f * light_color;

    // Diffuse — прямой свет от источника
    float diff = max(dot(N, L), 0.0f);
    float3 diffuse = diff * light_color;

    // Specular — блик
    float spec = pow(max(dot(V, R), 0.0f), 32.0f); // 32 — "shininess"
    float3 specular = spec * light_color * 0.5f;

    float3 result = (ambient + diffuse + specular) * albedo;
    return float4(result, 1.0f);
}