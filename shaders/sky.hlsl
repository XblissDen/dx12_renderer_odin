Texture2D<float4> g_environment : register(t0);
SamplerState g_sampler : register(s0);

cbuffer SkyConstants : register(b2)
{
    float3 sky_forward;
    float  tan_half_fov;

    float3 sky_right;
    float  aspect;

    float3 sky_up;
    float  _pad0;
};

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

float4 PSMain(VSOutput input) : SV_TARGET
{
    // From screen coordinates to a direction leaving the camera.
    float screen_x = (input.uv.x * 2.0f - 1.0f) * aspect * tan_half_fov;
    float screen_y = (1.0f - input.uv.y * 2.0f) * tan_half_fov;

    float3 direction = normalize(
        sky_forward + screen_x * sky_right + screen_y * sky_up
    );

    // A direction on a sphere becomes a position in a 2:1 panorama.
    float u = atan2(direction.z, direction.x) / (2.0f * 3.14159265f) + 0.5f;
    float v = acos(clamp(direction.y, -1.0f, 1.0f)) / 3.14159265f;

    return g_environment.Sample(g_sampler, float2(u, v));
}