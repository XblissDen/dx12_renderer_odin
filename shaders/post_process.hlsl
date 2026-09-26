Texture2D<float4> g_hdr_texture : register(t0);
SamplerState g_sampler : register(s0);

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

VSOutput VSMain(uint vertex_id : SV_VertexID)
{
    // One triangle large enough to cover the entire screen.
    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);

    VSOutput output;
    output.position = float4(
        uv.x * 2.0f - 1.0f,
        1.0f - uv.y * 2.0f,
        0.0f,
        1.0f
    );
    output.uv = uv;
    return output;
}

float4 PSMain(VSOutput input) : SV_TARGET
{
    float3 hdr_color = g_hdr_texture.Sample(g_sampler, input.uv).rgb;

    float3 mapped = hdr_color / (hdr_color + 1.0f);
    float3 display_color = pow(saturate(mapped), 1.0f / 2.2f);

    return float4(display_color, 1.0f);
}