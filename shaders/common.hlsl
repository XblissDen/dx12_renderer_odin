// Shared by several shaders through #include; never compiled on its own.
// HDR panoramas are 2:1 equirectangular images: u goes once around the
// horizon, v from straight up (0) to straight down (1).

#ifndef COMMON_HLSL
#define COMMON_HLSL

static const float PI = 3.14159265f;

// Where a direction lands in a panorama.
float2 DirectionToUV(float3 direction)
{
    return float2(
        atan2(direction.z, direction.x) / (2.0f * PI) + 0.5f,
        acos(clamp(direction.y, -1.0f, 1.0f)) / PI
    );
}

// The direction a panorama position looks along: DirectionToUV's inverse,
// matching hdri_texel_direction on the CPU.
float3 UVToDirection(float2 uv)
{
    float phi = (uv.x - 0.5f) * 2.0f * PI;
    float theta = uv.y * PI;
    return float3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));
}

// A world direction in the panorama's own frame: undoes the environment's
// rotation about Y, given as its sine and cosine, so lighting and the
// visible sky stay aligned.
float3 EnvironmentRotate(float3 direction, float s, float c)
{
    return float3(c * direction.x - s * direction.z, direction.y, s * direction.x + c * direction.z);
}

#endif
