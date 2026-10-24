#define MAX_LIGHTS 16
#define SHADOW_CASCADE_COUNT 4
// Must match SHADOW_NORMAL_OFFSET_TEXELS in renderer_shadow.odin.
#define SHADOW_NORMAL_OFFSET_TEXELS 1.0f
#define SHADOW_CASCADE_BLEND_FRACTION 0.1f

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
    float4x4 previous_model; // Last frame's model matrix, for motion vectors.

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
    float4x4 projection; // Includes the TAA jitter when TAA is on.
    // Unjittered, this frame and last, for motion vectors.
    float4x4 view_projection;
    float4x4 previous_view_projection;
    float4x4 cascade_view_projection[SHADOW_CASCADE_COUNT];

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
    uint   shadow_show_cascades;

    // One component per cascade.
    float4 cascade_split_depth;
    float4 cascade_texel_world;
    float4 cascade_texel_depth;

    float ao_radius;
    float ao_intensity;
    uint  ao_enabled;
    uint  ao_show;

    GpuPointLight lights[MAX_LIGHTS];
};

// Which cascade the shadow pass is drawing.
cbuffer ShadowCascade : register(b5)
{
    uint shadow_cascade_index;
};

Texture2D    g_texture : register(t0);
SamplerState g_sampler : register(s0);
SamplerState g_material_sampler : register(s2);
SamplerState g_environment_sampler : register(s3);
Texture2DArray<float> g_shadow_map : register(t1);
SamplerComparisonState g_shadow_sampler : register(s1);
Texture2D<float4> g_irradiance : register(t3);
Texture2D<float4> g_prefiltered_environment : register(t4);
Texture2D<float4> g_normal_map : register(t5);
Texture2D<float4> g_roughness_map : register(t6);
Texture2D<float4> g_metallic_map : register(t7);
// Ambient occlusion: the blurred map in the lit pass, the raw map in the blur.
Texture2D<float> g_ao : register(t8);
Texture2D<float> g_depth : register(t9);

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
    float  view_depth   : TEXCOORD2;
    float4 tangent : TEXCOORD3;
};

// Shared by VSMain and VSDepth so both produce bit-identical depth: the lit
// pass tests LESS_EQUAL against the prepass without writing.
float4 ObjectToClip(float3 position, out float4 world_pos, out float4 view_pos)
{
    world_pos = mul(float4(position, 1.0f), model);
    view_pos = mul(world_pos, view);
    return mul(view_pos, projection);
}

struct VelocityInput
{
    float4 position      : SV_POSITION;
    float4 current_clip  : TEXCOORD0; // Unjittered.
    float4 previous_clip : TEXCOORD1;
};

VelocityInput VSDepth(VSInput input)
{
    VelocityInput output;
    float4 world_pos, view_pos;
    output.position = ObjectToClip(input.position, world_pos, view_pos);
    output.current_clip = mul(world_pos, view_projection);
    float4 previous_world = mul(float4(input.position, 1.0f), previous_model);
    output.previous_clip = mul(previous_world, previous_view_projection);
    return output;
}

// Screen motion since last frame, in UV units (y down). TAA subtracts it to
// find where this pixel's surface was in the history.
float2 PSVelocity(VelocityInput input) : SV_TARGET
{
    float2 current = input.current_clip.xy / input.current_clip.w;
    float2 previous = input.previous_clip.xy / input.previous_clip.w;
    return (current - previous) * float2(0.5f, -0.5f);
}

PSInput VSMain(VSInput input)
{
    PSInput output;

    float4 world_pos, view_pos;
    output.position = ObjectToClip(input.position, world_pos, view_pos);
    output.world_pos = world_pos.xyz;
    // Distance along the camera's forward axis, which selects the cascade.
    output.view_depth = view_pos.z;

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
    return mul(world_pos, cascade_view_projection[shadow_cascade_index]);
}

// 5x5 tent filter from 9 bilinear comparison taps (Ignacio Castano's
// optimized PCF). Bilinear taps at weighted offsets reproduce the tent's
// weights, so edges are smooth without 25 separate samples.
float SampleShadowTent5x5(float2 uv, float depth, uint cascade)
{
    uint width, height, elements;
    g_shadow_map.GetDimensions(width, height, elements);
    float2 size = float2(width, height);

    float2 texel_uv = uv * size;
    float2 base = floor(texel_uv + 0.5f);
    float s = texel_uv.x + 0.5f - base.x;
    float t = texel_uv.y + 0.5f - base.y;
    base = (base - 0.5f) / size;

    float3 u_weight = float3(4.0f - 3.0f * s, 7.0f, 1.0f + 3.0f * s);
    float3 u_offset = float3(
        (3.0f - 2.0f * s) / u_weight.x - 2.0f,
        (3.0f + s) / u_weight.y,
        s / u_weight.z + 2.0f
    );
    float3 v_weight = float3(4.0f - 3.0f * t, 7.0f, 1.0f + 3.0f * t);
    float3 v_offset = float3(
        (3.0f - 2.0f * t) / v_weight.x - 2.0f,
        (3.0f + t) / v_weight.y,
        t / v_weight.z + 2.0f
    );

    float sum = 0.0f;
    [unroll]
    for (uint y = 0u; y < 3u; ++y)
    {
        [unroll]
        for (uint x = 0u; x < 3u; ++x)
        {
            float2 tap = base + float2(u_offset[x], v_offset[y]) / size;
            sum += u_weight[x] * v_weight[y] * g_shadow_map.SampleCmpLevelZero(
                g_shadow_sampler, float3(tap, float(cascade)), depth
            );
        }
    }
    // The weights in each direction sum to 12.
    return sum / 144.0f;
}

// Sun visibility from one cascade; 1 outside its map.
float CascadeVisibility(uint cascade, float3 world_pos, float3 geometric_normal, float tan_angle)
{
    // Look up from slightly off the surface to keep it from shadowing itself.
    float3 offset_pos = world_pos +
        geometric_normal * (SHADOW_NORMAL_OFFSET_TEXELS * cascade_texel_world[cascade]);
    float4 clip = mul(float4(offset_pos, 1.0f), cascade_view_projection[cascade]);
    float3 ndc = clip.xyz / clip.w;
    float2 uv = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);

    // Single exit: FXC reports early returns from inlined helpers as
    // "potentially uninitialized" (X4000).
    float visibility = 1.0f;
    if (all(uv >= 0.0f) && all(uv <= 1.0f) && ndc.z >= 0.0f && ndc.z <= 1.0f)
    {
        float bias = (shadow_bias_constant + shadow_bias_slope * tan_angle) *
                     cascade_texel_depth[cascade];
        visibility = SampleShadowTent5x5(uv, ndc.z - bias, cascade);
    }
    return visibility;
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

    // Occlusion applies to ambient (sky) light only: the sun and point lights
    // have their own shadows or none.
    float ambient_occlusion = 1.0f;
    if (ao_enabled != 0u)
    {
        ambient_occlusion = g_ao.Load(int3(input.position.xy, 0));
    }
    float n_dot_v = max(dot(N, V), 0.0f);
    // Lagarde's specular occlusion: reflections fade with AO, less so at
    // grazing angles and on smooth surfaces.
    float specular_occlusion = saturate(
        // The base is never negative; max() lets the compiler see that (X3571).
        pow(max(n_dot_v + ambient_occlusion, 0.0f), exp2(-16.0f * material_roughness - 1.0f)) -
        1.0f + ambient_occlusion
    );

    float3 result = ambient_kD * albedo * incoming_diffuse * ambient_occlusion;

    float2 environment_brdf = EnvBRDFApprox(n_dot_v, material_roughness);

    result += prefiltered_color * specular_occlusion *
            (ambient_F0 * environment_brdf.x + environment_brdf.y);


    // Use the interpolated geometric normal: normal-map detail does not change
    // the depth stored in the shadow map.
    float3 geometric_normal = normalize(input.normal);
    float geometric_n_dot_l = saturate(dot(geometric_normal, sun_L));
    float tan_angle = min(
        sqrt(1.0f - geometric_n_dot_l * geometric_n_dot_l) /
            max(geometric_n_dot_l, 0.0001f),
        10.0f
    );

    // The first cascade whose slice of the view contains this pixel.
    uint cascade = SHADOW_CASCADE_COUNT;
    [unroll]
    for (uint c = SHADOW_CASCADE_COUNT; c > 0u; --c)
    {
        if (input.view_depth < cascade_split_depth[c - 1u]) cascade = c - 1u;
    }

    float sun_visibility = 1.0f;
    if (cascade < SHADOW_CASCADE_COUNT)
    {
        sun_visibility = CascadeVisibility(
            cascade, input.world_pos, geometric_normal, tan_angle
        );

        // Cross-fade into the next cascade near the end of this one, so the
        // change in texel size does not show as a line.
        float cascade_start = cascade == 0u ? 0.0f : cascade_split_depth[cascade - 1u];
        float cascade_end = cascade_split_depth[cascade];
        float blend_start = cascade_end -
                            (cascade_end - cascade_start) * SHADOW_CASCADE_BLEND_FRACTION;
        if (cascade + 1u < SHADOW_CASCADE_COUNT && input.view_depth > blend_start)
        {
            float next = CascadeVisibility(
                cascade + 1u, input.world_pos, geometric_normal, tan_angle
            );
            sun_visibility = lerp(
                sun_visibility, next,
                saturate((input.view_depth - blend_start) / (cascade_end - blend_start))
            );
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

    if (shadow_show_cascades != 0u)
    {
        // Red, green, blue, yellow by cascade; beyond the last stays untinted.
        static const float3 cascade_tints[SHADOW_CASCADE_COUNT] = {
            float3(1.0f, 0.35f, 0.35f), float3(0.35f, 1.0f, 0.35f),
            float3(0.35f, 0.5f, 1.0f), float3(1.0f, 1.0f, 0.3f),
        };
        if (cascade < SHADOW_CASCADE_COUNT) result *= cascade_tints[cascade];
    }

    if (ao_show != 0u)
    {
        // Linear occlusion in [0, 1]; post-processing tone maps it like any color.
        result = ambient_occlusion;
    }

    return float4(result, 1.0f);
}

// ---------------------------------------------------------------------------
// Screen-space ambient occlusion. Full-screen passes driven by the post-process
// vertex shader; they live here to share FrameConstants.

struct FullscreenInput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

// Row-vector perspective: device depth d = P22 + P32 / z.
float ViewDepthFromDevice(float device_depth)
{
    return projection[3][2] / (device_depth - projection[2][2]);
}

float3 ViewPositionAt(int2 pixel, float2 size)
{
    pixel = clamp(pixel, int2(0, 0), int2(size) - 1);
    float z = ViewDepthFromDevice(g_depth.Load(int3(pixel, 0)));
    float2 ndc = float2(
        (pixel.x + 0.5f) / size.x * 2.0f - 1.0f,
        1.0f - (pixel.y + 0.5f) / size.y * 2.0f
    );
    // Row 2 holds the TAA jitter (zero without TAA); undo it before scaling.
    return float3(
        (ndc.x - projection[2][0]) * z / projection[0][0],
        (ndc.y - projection[2][1]) * z / projection[1][1],
        z
    );
}

// A 4x4 ordered pattern of rotations; the 4x4 blur averages all 16 of them.
static const float AO_ROTATION_PATTERN[16] = {
    0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5
};
#define AO_SAMPLE_COUNT 16

float PSSsao(FullscreenInput input) : SV_TARGET
{
    uint width, height;
    g_depth.GetDimensions(width, height);
    float2 size = float2(width, height);
    int2 pixel = int2(input.position.xy);

    if (g_depth.Load(int3(pixel, 0)) >= 1.0f)
    {
        return 1.0f; // Sky.
    }
    float3 p = ViewPositionAt(pixel, size);

    // Normal from depth: for each axis use the neighbour on the same surface
    // (smaller depth step), so silhouettes do not bend the normal.
    float3 left = ViewPositionAt(pixel - int2(1, 0), size);
    float3 right = ViewPositionAt(pixel + int2(1, 0), size);
    float3 up = ViewPositionAt(pixel - int2(0, 1), size);
    float3 down = ViewPositionAt(pixel + int2(0, 1), size);
    float3 dx = abs(right.z - p.z) < abs(p.z - left.z) ? right - p : p - left;
    float3 dy = abs(down.z - p.z) < abs(p.z - up.z) ? down - p : p - up;
    float3 n = normalize(cross(dx, dy));
    if (dot(n, p) > 0.0f) n = -n; // Face the camera at the view-space origin.

    float3 helper = abs(n.y) < 0.99f ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 t = normalize(cross(helper, n));
    float3 b = cross(n, t);

    float rotation = (AO_ROTATION_PATTERN[(pixel.y & 3) * 4 + (pixel.x & 3)] + 0.5f) /
                     16.0f * 2.0f * PI;
    float bias = 0.025f * ao_radius;

    float occlusion = 0.0f;
    [unroll]
    for (uint i = 0u; i < AO_SAMPLE_COUNT; ++i)
    {
        // Cosine-weighted hemisphere directions, denser near the center.
        float u = (i + 0.5f) / AO_SAMPLE_COUNT;
        float phi = 2.0f * PI * frac(i * 0.618034f) + rotation;
        float radius = sqrt(u);
        float3 direction = float3(radius * cos(phi), radius * sin(phi), sqrt(1.0f - u));
        float distance_t = frac(i * 0.7548777f + 0.5698403f);
        float scale = lerp(0.1f, 1.0f, distance_t * distance_t) * ao_radius;

        float3 sample_pos = p + (t * direction.x + b * direction.y + n * direction.z) * scale;
        float4 clip = mul(float4(sample_pos, 1.0f), projection);
        float2 uv = clip.xy / clip.w * float2(0.5f, -0.5f) + 0.5f;
        if (any(uv < 0.0f) || any(uv > 1.0f))
        {
            continue;
        }

        float scene_z = ViewDepthFromDevice(g_depth.Load(int3(uv * size, 0)));
        // Occluded when the visible surface there is in front of the sample;
        // ignore surfaces far in front of this pixel (another object's silhouette).
        float in_range = smoothstep(0.0f, 1.0f, ao_radius / max(abs(p.z - scene_z), 0.0001f));
        occlusion += (scene_z <= sample_pos.z - bias ? 1.0f : 0.0f) * in_range;
    }

    return pow(saturate(1.0f - occlusion / AO_SAMPLE_COUNT), ao_intensity);
}

// 4x4 average that skips pixels on other surfaces (by relative depth), which
// removes the rotation pattern without blurring across silhouettes.
float PSSsaoBlur(FullscreenInput input) : SV_TARGET
{
    uint width, height;
    g_depth.GetDimensions(width, height);
    int2 pixel = int2(input.position.xy);
    int2 last = int2(width, height) - 1;

    float center_z = ViewDepthFromDevice(g_depth.Load(int3(pixel, 0)));
    float sum = 0.0f;
    float weight_sum = 0.0f;
    [unroll]
    for (int y = -2; y <= 1; ++y)
    {
        [unroll]
        for (int x = -2; x <= 1; ++x)
        {
            int2 q = clamp(pixel + int2(x, y), int2(0, 0), last);
            float z = ViewDepthFromDevice(g_depth.Load(int3(q, 0)));
            float weight = saturate(1.0f - abs(z - center_z) / (0.05f * center_z)) + 0.0001f;
            sum += g_ao.Load(int3(q, 0)) * weight;
            weight_sum += weight;
        }
    }
    return sum / weight_sum;
}
