Texture2D<float4> g_environment : register(t0);
SamplerState g_sampler : register(s3);

cbuffer SkyConstants : register(b2)
{
    float3 sky_forward;
    float  tan_half_fov;

    float3 sky_right;
    float  aspect;

    float3 sky_up;
    float  background_brightness;
    float environment_sin;
    float environment_cos;
    float2 _pad1;
    float3 background_color;
    uint background_mode;
};

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

float4 PSMain(VSOutput input) : SV_TARGET
{
    [branch]
    if (background_mode == 1u) // Solid
        return float4(background_color * background_brightness, 1.0f);

    // From screen coordinates to a direction leaving the camera.
    float screen_x = (input.uv.x * 2.0f - 1.0f) * aspect * tan_half_fov;
    float screen_y = (1.0f - input.uv.y * 2.0f) * tan_half_fov;

    float3 direction = normalize(
        sky_forward + screen_x * sky_right + screen_y * sky_up
    );

    // A direction on a sphere becomes a position in a 2:1 panorama.
    direction = float3(
        environment_cos * direction.x - environment_sin * direction.z,
        direction.y,
        environment_sin * direction.x + environment_cos * direction.z
    );
    float u = atan2(direction.z, direction.x) / (2.0f * 3.14159265f) + 0.5f;
    float v = acos(clamp(direction.y, -1.0f, 1.0f)) / 3.14159265f;

    // Choose the mip from the angle a pixel covers, not from how fast (u, v)
    // change. Plain Sample() goes wrong in two places: u wraps from 1 to 0
    // where atan2 crosses -pi/pi (a line along that meridian), and near the
    // poles u sweeps the whole panorama within a few pixels (a dot at the
    // zenith and nadir). Both select the smallest mip, the sky's average color
    // with the sun in it. A 2:1 panorama has the same texels per radian in u
    // and v, so the angle maps directly to a level; the sampler wraps u, so
    // filtering across the seam stays seamless.
    float angle_x = length(ddx(direction));
    float angle_y = length(ddy(direction));
    float2 uv_dx = float2(angle_x / (2.0f * 3.14159265f), 0.0f);
    float2 uv_dy = float2(0.0f, angle_y / 3.14159265f);

    return float4(g_environment.SampleGrad(g_sampler, float2(u, v), uv_dx, uv_dy).rgb * background_brightness, 1.0f);
}
