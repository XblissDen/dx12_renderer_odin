#include "common.hlsl"

// Clustered lighting; must match renderer_lights.odin. The view is split into
// a grid of cells, 16x9 across the screen and 24 slices in depth (spaced
// logarithmically), and each cell lists the lights that reach it.
#define LIGHT_CLUSTER_X 16
#define LIGHT_CLUSTER_Y 9
#define LIGHT_CLUSTER_Z 24
// Each cell: its light count, then up to this many light indices.
#define MAX_LIGHTS_PER_CLUSTER 127
#define LIGHT_CLUSTER_STRIDE (MAX_LIGHTS_PER_CLUSTER + 1)
// Shadow slots; must match renderer_shadow.odin.
#define SHADOW_CASCADE_COUNT 4
#define SPOT_SHADOW_COUNT 4
#define POINT_SHADOW_COUNT 4
#define POINT_SHADOW_FACES 6
// Receivers look up a shadow map this many texels off their surface, along
// the geometric normal, which removes most acne without a large depth bias:
// sun cascades, and spot and point lights (texels at the receiver's
// distance from the light).
#define SHADOW_NORMAL_OFFSET_TEXELS 1.0f
#define SPOT_SHADOW_NORMAL_OFFSET_TEXELS 1.5f
// Each cascade blends into the next over this last fraction of its depth range.
#define SHADOW_CASCADE_BLEND_FRACTION 0.1f

// A point or spot light (renderer.odin's GpuLight).
struct GpuLight
{
    float3 position;
    float  range;       // Fades out completely here.
    float3 radiance;    // Color times intensity.
    // Cone fade: saturate(cos * spot_scale + spot_offset)^2, with cos taken
    // to the cone's axis. Point lights: scale 0, offset 1.
    float  spot_offset;
    float3 direction;
    float  spot_scale;
    int    shadow_index;       // Spot shadow slot or point shadow cube, or -1.
    float  shadow_texel_scale; // Texel size per unit of distance along the axis.
    float  shadow_near;        // Point lights: the cube faces' near plane.
    float  _light_pad;
};

// Per-draw data (renderer.odin's ObjectData): one per submesh of each entity,
// in g_objects. A draw call draws instances of one submesh; instance i is the
// object g_instance_draws[instance_base + i].
struct ObjectData
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
    uint use_occlusion_map;
    float occlusion_strength;

    float3 emissive; // Color times strength; zero for none.
    float  alpha_cutoff; // Used by the cutout pipelines only.

    float opacity; // Blended materials: multiplies albedo alpha.

    // The material's textures, as indices into g_textures (the SRV heap).
    // Unused maps are neutral textures (white, flat normal).
    uint albedo_texture;
    uint normal_texture;
    uint roughness_texture;
    uint metallic_texture;
    uint emissive_texture;
    uint occlusion_texture;
    float _object_pad; // Up to the 288 bytes Odin gives the struct.
};

StructuredBuffer<ObjectData> g_objects : register(t20);
StructuredBuffer<uint> g_instance_draws : register(t21);

cbuffer DrawConstants : register(b0)
{
    uint instance_base; // This draw call's first entry in g_instance_draws.
};

// The object being drawn; every entry point loads it first.
static ObjectData g_object;

// For vertex shaders: loads the instance's object and returns its index,
// which the pixel shader gets as `draw`.
uint LoadInstanceObject(uint instance)
{
    uint draw = g_instance_draws[instance_base + instance];
    g_object = g_objects[draw];
    return draw;
}

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

    // Screen-space reflections (renderer_ssr.odin): view-space ray length and
    // surface thickness, and the roughness above which there are none.
    float ssr_max_distance;
    float ssr_thickness;
    float ssr_max_roughness;
    uint  ssr_enabled;
    uint  ssr_stochastic; // With TAA: rays spread over the GGX lobe, averaged over frames.
    uint  ssr_frame;
    float2 _ssr_pad;

    // Clustered lighting: the depth slice of view depth z is
    // log2(z) * cluster_depth_scale + cluster_depth_bias.
    float2 cluster_screen_size;
    float  cluster_depth_scale;
    float  cluster_depth_bias;
    // Nonzero shows each pixel's cluster light count instead of lighting.
    uint   light_show_clusters;
    float3 _cluster_pad;

    // Volumetric fog (renderer_fog.odin). Density is extinction per unit at
    // or below fog_height, falling off exponentially above it.
    float3 fog_albedo;
    float  fog_density;
    float3 fog_ambient; // Radiance reaching the fog evenly from every direction.
    float  fog_height;
    float  fog_height_falloff;
    float  fog_anisotropy; // Henyey-Greenstein g.
    float  fog_max_distance;
    uint   fog_history_valid;
    uint   fog_frame;
    float3 _fog_pad;

    float4x4 spot_shadow_view_projection[SPOT_SHADOW_COUNT];
    float4x4 point_shadow_face_view_projection[POINT_SHADOW_COUNT * POINT_SHADOW_FACES];
};

// The visible point and spot lights (light_count of them), and each light
// cluster's count and light indices, built by CSBuildLightClusters.
StructuredBuffer<GpuLight> g_lights : register(t18);
StructuredBuffer<uint> g_cluster_lights : register(t19);

// The first element of the cluster holding this pixel (SV_Position.xy) at
// this view depth.
uint LightClusterBase(float2 pixel, float view_depth)
{
    uint2 tile = min(
        uint2(pixel / cluster_screen_size * float2(LIGHT_CLUSTER_X, LIGHT_CLUSTER_Y)),
        uint2(LIGHT_CLUSTER_X - 1, LIGHT_CLUSTER_Y - 1)
    );
    // Before the first slice (closer than the near plane) counts as the first.
    float slice = log2(max(view_depth, 0.0001f)) * cluster_depth_scale + cluster_depth_bias;
    uint z = uint(clamp(slice, 0.0f, float(LIGHT_CLUSTER_Z - 1)));
    return ((z * LIGHT_CLUSTER_Y + tile.y) * LIGHT_CLUSTER_X + tile.x) * LIGHT_CLUSTER_STRIDE;
}

// Light cluster view: black for none, then blue, green, yellow, red as the
// count rises, and white for a full cluster (lights past it are dropped).
float3 ClusterHeatColor(uint count)
{
    static const float3 heat[5] = {
        float3(0.0f, 0.0f, 0.0f), float3(0.0f, 0.2f, 1.0f), float3(0.0f, 1.0f, 0.2f),
        float3(1.0f, 1.0f, 0.0f), float3(1.0f, 0.0f, 0.0f),
    };
    float3 color = float3(1.0f, 1.0f, 1.0f);
    if (count < MAX_LIGHTS_PER_CLUSTER)
    {
        // Steps at 1, 4, 16 and 64 lights.
        float level = count == 0u ? 0.0f : 1.0f + log2(float(count)) * 0.5f;
        uint low = min(uint(level), 3u);
        color = lerp(heat[low], heat[low + 1u], saturate(level - float(low)));
    }
    return color;
}

// Which shadow view the shadow pass is drawing: a cascade, a spot slot or a
// point light's cube face (see VSShadow).
cbuffer ShadowView : register(b5)
{
    uint shadow_view_index;
};

// Bindless textures: the whole SRV heap (root slot Textures), indexed by the
// object's texture indices. Instances of one draw call can use different
// textures, so the index may differ across a wave: NonUniformResourceIndex.
Texture2D<float4> g_textures[] : register(t22);

#define g_texture       g_textures[NonUniformResourceIndex(g_object.albedo_texture)]
#define g_normal_map    g_textures[NonUniformResourceIndex(g_object.normal_texture)]
#define g_roughness_map g_textures[NonUniformResourceIndex(g_object.roughness_texture)]
#define g_metallic_map  g_textures[NonUniformResourceIndex(g_object.metallic_texture)]
#define g_emissive_map  g_textures[NonUniformResourceIndex(g_object.emissive_texture)]
#define g_occlusion_map g_textures[NonUniformResourceIndex(g_object.occlusion_texture)]

SamplerState g_sampler : register(s0);
SamplerState g_material_sampler : register(s2);
SamplerState g_environment_sampler : register(s3);
Texture2DArray<float> g_shadow_map : register(t1);
Texture2DArray<float> g_spot_shadow_map : register(t5); // One slice per spot shadow slot.
TextureCubeArray<float> g_point_shadow_map : register(t6); // One cube per point shadow slot.
SamplerComparisonState g_shadow_sampler : register(s1);
Texture2D<float4> g_irradiance : register(t3);
Texture2D<float4> g_prefiltered_environment : register(t4);
// Ambient occlusion: the blurred map in the lit pass, the raw map in the blur.
Texture2D<float> g_ao : register(t8);
Texture2D<float> g_depth : register(t9);
// Written by the prepass: view-space shading normal and specular roughness.
Texture2D<float4> g_surface : register(t7);
// SSR: reflected color premultiplied by its confidence, which the lit pass
// blends over the environment's specular.
Texture2D<float4> g_reflections : register(t17);
// SSR's inputs: last frame's HDR image and this frame's motion vectors.
Texture2D<float4> g_scene_color : register(t0);
Texture2D<float2> g_velocity : register(t8);
SamplerState g_clamp_sampler : register(s4);

struct VSInput
{
    float3 position : POSITION;
    float3 normal   : NORMAL;
    float2 texcoord : TEXCOORD;
    float4 tangent : TANGENT;
    uint instance : SV_InstanceID;
};

struct PSInput
{
    nointerpolation uint draw : DRAW; // Index of the object in g_objects.
    float4 position     : SV_POSITION;
    float3 world_pos    : TEXCOORD0;
    float3 normal       : NORMAL;
    float2 texcoord     : TEXCOORD1;
    float  view_depth   : TEXCOORD2;
    float4 tangent : TEXCOORD3;
    // Unjittered, this frame and last: blended surfaces write their own
    // motion vectors (PSTransparent).
    float4 current_clip  : TEXCOORD4;
    float4 previous_clip : TEXCOORD5;
};

// Shared by VSMain and VSDepth so both produce bit-identical depth: the lit
// pass tests LESS_EQUAL against the prepass without writing.
float4 ObjectToClip(float3 position, out float4 world_pos, out float4 view_pos)
{
    world_pos = mul(float4(position, 1.0f), g_object.model);
    view_pos = mul(world_pos, view);
    return mul(view_pos, projection);
}

// Cutout materials: discards the pixel where albedo alpha is below the
// cutoff. Mip maps average alpha toward the cutoff, which would make thin
// cutouts (leaves, chains) thin out and vanish with distance; scaling alpha
// up with the mip level keeps their coverage (Ben Golus, "Anti-aliased Alpha
// Test").
void ClipAlpha(float2 texcoord)
{
    float2 uv = texcoord * g_object.uv_scale;
    float alpha = g_texture.Sample(g_material_sampler, uv).a;
    float mip = g_texture.CalculateLevelOfDetail(g_material_sampler, uv);
    alpha *= 1.0f + max(mip, 0.0f) * 0.25f;
    clip(alpha - g_object.alpha_cutoff);
}

struct VelocityInput
{
    float4 position      : SV_POSITION;
    float4 current_clip  : TEXCOORD0; // Unjittered.
    float4 previous_clip : TEXCOORD1;
    float2 texcoord      : TEXCOORD2;
    // World space, for the surface buffer's shading normal.
    float3 normal        : NORMAL;
    float4 tangent       : TEXCOORD3;
    nointerpolation uint draw : DRAW;
};

VelocityInput VSDepth(VSInput input)
{
    VelocityInput output;
    output.draw = LoadInstanceObject(input.instance);
    float4 world_pos, view_pos;
    output.position = ObjectToClip(input.position, world_pos, view_pos);
    output.current_clip = mul(world_pos, view_projection);
    float4 previous_world = mul(float4(input.position, 1.0f), g_object.previous_model);
    output.previous_clip = mul(previous_world, previous_view_projection);
    output.texcoord = input.texcoord;
    output.normal = mul(input.normal, (float3x3)g_object.normal_matrix);
    output.tangent = float4(mul(input.tangent.xyz, (float3x3)g_object.model), input.tangent.w);
    return output;
}

// Screen motion since last frame, in UV units (y down), from a surface's
// unjittered clip position this frame and last. TAA subtracts it to find
// where this pixel's surface was in the history.
float2 ScreenMotion(float4 current_clip, float4 previous_clip)
{
    float2 current = current_clip.xy / current_clip.w;
    float2 previous = previous_clip.xy / previous_clip.w;
    return (current - previous) * float2(0.5f, -0.5f);
}

float2 Velocity(VelocityInput input)
{
    return ScreenMotion(input.current_clip, input.previous_clip);
}

PSInput VSMain(VSInput input)
{
    PSInput output;
    output.draw = LoadInstanceObject(input.instance);

    float4 world_pos, view_pos;
    output.position = ObjectToClip(input.position, world_pos, view_pos);
    output.world_pos = world_pos.xyz;
    // Distance along the camera's forward axis, which selects the cascade.
    output.view_depth = view_pos.z;

    output.normal = mul(input.normal, (float3x3)g_object.normal_matrix);
    output.texcoord = input.texcoord;
    output.tangent = float4(
        mul(input.tangent.xyz, (float3x3)g_object.model),
        input.tangent.w
    );
    output.current_clip = mul(world_pos, view_projection);
    output.previous_clip = mul(mul(float4(input.position, 1.0f), g_object.previous_model), previous_view_projection);

    return output;
}

struct ShadowInput
{
    float4 position : SV_POSITION;
    float2 texcoord : TEXCOORD0; // Read by cutouts only.
    nointerpolation uint draw : DRAW;
};

ShadowInput VSShadow(VSInput input)
{
    ShadowInput output;
    output.draw = LoadInstanceObject(input.instance);
    float4 world_pos = mul(float4(input.position, 1.0f), g_object.model);
    // Views: the sun's cascades, the spot shadow slots, then the point
    // shadow cube faces.
    uint view = shadow_view_index;
    float4x4 light_view_projection;
    if (view < SHADOW_CASCADE_COUNT)
    {
        light_view_projection = cascade_view_projection[view];
    }
    else if (view < SHADOW_CASCADE_COUNT + SPOT_SHADOW_COUNT)
    {
        light_view_projection = spot_shadow_view_projection[view - SHADOW_CASCADE_COUNT];
    }
    else
    {
        light_view_projection = point_shadow_face_view_projection[view - SHADOW_CASCADE_COUNT - SPOT_SHADOW_COUNT];
    }
    output.position = mul(world_pos, light_view_projection);
    output.texcoord = input.texcoord;
    return output;
}

// Cutouts cast shadows through their holes. Opaque casters have no pixel shader.
void PSShadowMasked(ShadowInput input)
{
    g_object = g_objects[input.draw];
    ClipAlpha(input.texcoord);
}

// 5x5 tent filter from 9 bilinear comparison taps (Ignacio Castano's
// optimized PCF). Bilinear taps at weighted offsets reproduce the tent's
// weights, so edges are smooth without 25 separate samples.
float SampleShadowTent5x5(Texture2DArray<float> shadow_map, float2 uv, float depth, uint slice)
{
    uint width, height, elements;
    shadow_map.GetDimensions(width, height, elements);
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
            sum += u_weight[x] * v_weight[y] * shadow_map.SampleCmpLevelZero(
                g_shadow_sampler, float3(tap, float(slice)), depth
            );
        }
    }
    // The weights in each direction sum to 12.
    return sum / 144.0f;
}

// How much of a spot light reaches this point past shadow casters; 1 when the
// light has no shadow slot. The lookup starts slightly off the surface along
// its normal, by texels at this distance from the light; the casters' own
// slope-scaled bias does the rest. Single exit: see CascadeVisibility.
float SpotShadowVisibility(GpuLight light, float3 world_pos, float3 geometric_normal)
{
    float visibility = 1.0f;
    if (light.shadow_index >= 0)
    {
        float axis_distance = max(dot(world_pos - light.position, light.direction), 0.0f);
        float3 offset_pos = world_pos + geometric_normal *
            (SPOT_SHADOW_NORMAL_OFFSET_TEXELS * light.shadow_texel_scale * axis_distance);
        float4 clip = mul(float4(offset_pos, 1.0f), spot_shadow_view_projection[light.shadow_index]);
        if (clip.w > 0.0f)
        {
            float3 ndc = clip.xyz / clip.w;
            float2 uv = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
            // Outside the map is outside the cone, which is dark anyway.
            if (all(uv >= 0.0f) && all(uv <= 1.0f) && ndc.z <= 1.0f)
            {
                visibility = SampleShadowTent5x5(g_spot_shadow_map, uv, ndc.z, uint(light.shadow_index));
            }
        }
    }
    return visibility;
}

// How much of a point light reaches this point past shadow casters; 1 when
// the light has no shadow slot. The cube face is picked by direction (the
// faces follow D3D's cube layout), and the receiver's depth is put into that
// face's projection: its distance along the dominant axis. A 3x3 tent of
// filtered comparisons, one texel apart across the direction, softens edges.
// Single exit: see CascadeVisibility.
float PointShadowVisibility(GpuLight light, float3 world_pos, float3 geometric_normal)
{
    float visibility = 1.0f;
    if (light.shadow_index >= 0)
    {
        float3 to_point = world_pos - light.position;
        float axis_distance = max(max(abs(to_point.x), abs(to_point.y)), abs(to_point.z));
        float3 direction = to_point + geometric_normal *
            (SPOT_SHADOW_NORMAL_OFFSET_TEXELS * light.shadow_texel_scale * axis_distance);
        float face_depth = max(max(abs(direction.x), abs(direction.y)), abs(direction.z));

        // perspective_lh's depth: far / (far - near) - near * far / ((far - near) * z).
        float near = light.shadow_near;
        float far = light.range;
        float depth = (far - near * far / max(face_depth, near)) / (far - near);

        float3 axis = normalize(direction);
        float3 helper = abs(axis.y) < 0.99f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f);
        float3 tangent = normalize(cross(helper, axis));
        float3 bitangent = cross(axis, tangent);
        float texel = light.shadow_texel_scale * face_depth;

        float sum = 0.0f;
        [unroll]
        for (int y = -1; y <= 1; ++y)
        {
            [unroll]
            for (int x = -1; x <= 1; ++x)
            {
                float weight = float((2 - abs(x)) * (2 - abs(y)));
                float3 tap = direction + (tangent * float(x) + bitangent * float(y)) * texel;
                sum += weight * g_point_shadow_map.SampleCmpLevelZero(
                    g_shadow_sampler, float4(tap, float(light.shadow_index)), depth
                );
            }
        }
        visibility = sum / 16.0f;
    }
    return visibility;
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
        visibility = SampleShadowTent5x5(g_shadow_map, uv, ndc.z - bias, cascade);
    }
    return visibility;
}

float3 EnvironmentDirection(float3 direction)
{
    return EnvironmentRotate(direction, environment_sin, environment_cos);
}

// How much of a point or spot light reaches a surface `to_light` away from
// it, before shadows; also gives the direction to the light. Inverse-square
// falloff, windowed to reach exactly zero at the range ((1 - (d / range)^4)^2,
// as in Unreal and Frostbite) and close to 1 well inside it, times the spot
// cone (smooth from the inner to the outer angle; 1 for point lights).
float LightAttenuation(GpuLight light, float3 to_light, out float3 L)
{
    float distance_squared = dot(to_light, to_light);
    L = to_light * rsqrt(max(distance_squared, 0.0001f));
    float distance_ratio_squared = distance_squared / (light.range * light.range);
    float window = saturate(1.0f - distance_ratio_squared * distance_ratio_squared);
    float cone = saturate(dot(-L, light.direction) * light.spot_scale + light.spot_offset);
    return window * window / (1.0f + distance_squared) * cone * cone;
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

// The shading normal (normal map applied) and specular roughness, shared by
// the lit pass and the prepass's surface buffer so SSR traces what is lit.
// Back faces (visible only on double-sided materials) are lit from their own
// side: the whole surface basis flips, as in the glTF sample viewer.
void SurfaceNormalRoughness(
    float3 interpolated_normal,
    float4 tangent,
    float2 material_uv,
    bool is_front_face,
    out float3 geometric_normal,
    out float3 N,
    out float material_roughness
)
{
    float roughness_value = g_object.roughness;
    if (g_object.use_roughness_map != 0)
    {
        roughness_value *= g_roughness_map.Sample(
            g_material_sampler, material_uv
        ).r;
    }
    material_roughness = clamp(roughness_value, 0.08f, 1.0f);

    float face_sign = is_front_face ? 1.0f : -1.0f;
    geometric_normal = normalize(interpolated_normal) * face_sign;
    N = geometric_normal;
    if (g_object.normal_strength > 0.0f)
    {
        // Rebuild an orthogonal surface basis after interpolation.
        float3 T = normalize(
            tangent.xyz - N * dot(N, tangent.xyz)
        ) * face_sign;
        float3 B = cross(N, T) * tangent.w * face_sign;

        // Normal maps encode signed directions in unsigned channels. Only x
        // and y are read (BC5 stores nothing else); z is the unit length's
        // remainder, as tangent-space normals point out of the surface.
        float2 normal_xy = g_normal_map.Sample(
            g_material_sampler, material_uv
        ).xy * 2.0f - 1.0f;
        float3 tangent_normal = float3(normal_xy, sqrt(saturate(1.0f - dot(normal_xy, normal_xy))));

        tangent_normal.xy *= g_object.normal_strength;

        N = normalize(
            T * tangent_normal.x +
            B * tangent_normal.y +
            N * tangent_normal.z
        );
    }
    material_roughness = FilterSpecularRoughness(material_roughness, N);
}

struct PrepassOutput
{
    float2 velocity : SV_TARGET0;
    float4 surface  : SV_TARGET1; // View-space shading normal, roughness.
};

// The depth prepass's outputs: motion for TAA and the surface for SSR.
// Unlit surfaces get roughness 1, which SSR skips.
PrepassOutput Prepass(VelocityInput input, bool is_front_face)
{
    float3 geometric_normal, N;
    float material_roughness;
    SurfaceNormalRoughness(
        input.normal, input.tangent, input.texcoord * g_object.uv_scale, is_front_face,
        geometric_normal, N, material_roughness
    );

    PrepassOutput output;
    output.velocity = Velocity(input);
    output.surface = float4(
        mul(N, (float3x3)view),
        g_object.unlit != 0 ? 1.0f : material_roughness
    );
    return output;
}

PrepassOutput PSPrepass(VelocityInput input, bool is_front_face : SV_IsFrontFace)
{
    g_object = g_objects[input.draw];
    return Prepass(input, is_front_face);
}

// The prepass for cutouts: their depth only where alpha passes. The lit pass
// then shades exactly those pixels (EQUAL depth test).
PrepassOutput PSPrepassMasked(VelocityInput input, bool is_front_face : SV_IsFrontFace)
{
    g_object = g_objects[input.draw];
    ClipAlpha(input.texcoord);
    return Prepass(input, is_front_face);
}

// Lit surface color; `transparent` adds coverage in alpha for blending.
// Unlit materials are handled by the entry points: an early return here makes
// FXC report X4000 (see CascadeVisibility).
float4 ShadeSurface(PSInput input, bool is_front_face, bool transparent)
{
    // Albedo SRVs are _SRGB, so the sampler returns filtered linear values.
    float2 material_uv = input.texcoord * g_object.uv_scale;

    float4 albedo_sample = g_texture.Sample(
        g_material_sampler, material_uv
    );
    float3 albedo = albedo_sample.rgb * g_object.material_tint;

    float metallic_value = g_object.metallic;
    if (g_object.use_metallic_map != 0)
    {
        metallic_value *= g_metallic_map.Sample(
            g_material_sampler, material_uv
        ).r;
    }
    float material_metallic = saturate(metallic_value);

    float3 geometric_normal, N;
    float material_roughness;
    SurfaceNormalRoughness(
        input.normal, input.tangent, material_uv, is_front_face,
        geometric_normal, N, material_roughness
    );
    float3 V = normalize(view_position - input.world_pos);
    float3 sun_L = normalize(-sun_direction);

    // A constant-color environment supplies both diffuse and specular radiance,
    // keeping metals illuminated even without a panorama.
    float3 incoming_diffuse = ambient_color * ambient_intensity;
    float3 prefiltered_color = incoming_diffuse;
    [branch]
    if (ambient_mode == 0u) // HDRI
    {
        incoming_diffuse = g_irradiance.SampleLevel(
            g_environment_sampler, DirectionToUV(EnvironmentDirection(N)), 0
        ).rgb * environment_intensity;

        float3 reflection = EnvironmentDirection(reflect(-V, N));
        prefiltered_color = g_prefiltered_environment.SampleLevel(
            g_environment_sampler, DirectionToUV(reflection), material_roughness * 4.0f
        ).rgb * environment_intensity;
    }
    // Where SSR found the reflected surface, it replaces the environment.
    // Like SSAO it is per pixel of the opaque surface, so blended ones skip it.
    if (ssr_enabled != 0u && !transparent)
    {
        // Color is premultiplied by confidence.
        float4 screen_reflection = g_reflections.Load(int3(input.position.xy, 0));
        prefiltered_color = prefiltered_color * (1.0f - screen_reflection.a) + screen_reflection.rgb;
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
    // SSAO comes from the prepass depth, which holds what is behind a
    // blended surface, not the surface itself.
    if (ao_enabled != 0u && !transparent)
    {
        ambient_occlusion = g_ao.Load(int3(input.position.xy, 0));
    }
    // Baked occlusion (glTF's definition: red channel, blended in by strength)
    // adds the detail SSAO cannot see, such as creases inside a model.
    if (g_object.use_occlusion_map != 0u)
    {
        float baked = g_occlusion_map.Sample(g_material_sampler, material_uv).r;
        ambient_occlusion *= 1.0f + g_object.occlusion_strength * (baked - 1.0f);
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

    // Only the lights listed for this pixel's cluster can reach it.
    uint cluster_base = LightClusterBase(input.position.xy, input.view_depth);
    uint cluster_light_count = g_cluster_lights[cluster_base];
    for (uint i = 0; i < cluster_light_count; ++i)
    {
        GpuLight light = g_lights[g_cluster_lights[cluster_base + 1u + i]];
        float3 L;
        float attenuation = LightAttenuation(light, light.position - input.world_pos, L);
        // Spot lights have a cone (spot_scale > 0); point lights have none.
        float shadow = 1.0f;
        [branch]
        if (light.spot_scale > 0.0f)
        {
            shadow = SpotShadowVisibility(light, input.world_pos, geometric_normal);
        }
        else
        {
            shadow = PointShadowVisibility(light, input.world_pos, geometric_normal);
        }
        float3 radiance = light.radiance * attenuation * shadow;

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

    // Emission is not lit or shadowed; bloom picks up its bright parts.
    [branch]
    if (any(g_object.emissive > 0.0f))
    {
        result += g_object.emissive * g_emissive_map.Sample(g_material_sampler, material_uv).rgb;
    }

    if (ao_show != 0u)
    {
        // Linear occlusion in [0, 1]; post-processing tone maps it like any color.
        result = ambient_occlusion;
    }
    if (light_show_clusters != 0u)
    {
        result = ClusterHeatColor(cluster_light_count);
    }

    return float4(result, transparent ? saturate(albedo_sample.a * g_object.opacity) : 1.0f);
}

// Unlit materials (light markers): a bright flat color.
float4 UnlitColor()
{
    return float4(g_object.material_tint * 4.0f, 1.0f);
}

float4 PSMain(PSInput input, bool is_front_face : SV_IsFrontFace) : SV_TARGET
{
    g_object = g_objects[input.draw];
    if (g_object.unlit != 0) return UnlitColor();
    return ShadeSurface(input, is_front_face, false);
}

// A blended surface takes over the pixel's motion vector where it covers at
// least this much; thinner glass leaves the motion of what is seen through it.
#define TRANSPARENT_MOTION_COVERAGE 0.5f

struct TransparentOutput
{
    float4 color  : SV_TARGET0; // Blended by alpha.
    // Motion in xy; alpha 1 replaces the pixel's motion, 0 keeps it.
    float4 motion : SV_TARGET1;
};

// Blended materials, drawn over the opaque image (alpha blending).
TransparentOutput PSTransparent(PSInput input, bool is_front_face : SV_IsFrontFace)
{
    g_object = g_objects[input.draw];
    TransparentOutput output;
    output.color = g_object.unlit != 0 ? UnlitColor() : ShadeSurface(input, is_front_face, true);
    output.motion = float4(
        ScreenMotion(input.current_clip, input.previous_clip), 0.0f,
        output.color.a >= TRANSPARENT_MOTION_COVERAGE ? 1.0f : 0.0f
    );
    return output;
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

// ---------------------------------------------------------------------------
// Screen-space reflections: march the reflected ray through the depth buffer,
// and where it passes behind a surface, read that surface's color from last
// frame's HDR image (moved by its motion vector). Runs before the lit pass,
// which blends the result over the environment's specular.

#define SSR_MAX_STEPS 64
#define SSR_REFINE_STEPS 5
// Fraction of the screen over which hits fade out towards its edges.
#define SSR_EDGE_FADE 0.1f

// Jorge Jimenez's interleaved gradient noise: well spread over neighbouring
// pixels, so TAA (or the eye) averages it quickly.
float InterleavedGradientNoise(float2 pixel)
{
    return frac(52.9829189f * frac(dot(pixel, float2(0.06711056f, 0.00583715f))));
}

float2 ClipToUv(float4 clip)
{
    return clip.xy / clip.w * float2(0.5f, -0.5f) + 0.5f;
}

float SceneViewDepth(float2 uv, float2 size)
{
    int2 pixel = clamp(int2(uv * size), int2(0, 0), int2(size) - 1);
    return ViewDepthFromDevice(g_depth.Load(int3(pixel, 0)));
}

// Color (premultiplied) and confidence of the reflection at `pixel`; zero where the ray
// leaves the screen or passes behind nothing. Single exit: see CascadeVisibility.
float4 TraceReflection(int2 pixel, float2 size, float3 N, float surface_roughness)
{
    float3 P = ViewPositionAt(pixel, size);
    float3 V = normalize(P); // From the camera to the surface.

    // Per-pixel noise, changing every frame when TAA will average it.
    float2 noise_pixel = float2(pixel) + (ssr_stochastic != 0u ? float(ssr_frame % 64u) * 5.588238f : 0.0f);
    float march_noise = InterleavedGradientNoise(noise_pixel);

    float3 R = reflect(V, N);
    if (ssr_stochastic != 0u)
    {
        // A microfacet normal from the GGX distribution (Walter et al.), so
        // over many frames the rays cover the specular lobe: rough surfaces
        // get blurred reflections instead of mirror images.
        float alpha = surface_roughness * surface_roughness;
        float u1 = InterleavedGradientNoise(noise_pixel + float2(47.0f, 13.0f));
        float u2 = InterleavedGradientNoise(noise_pixel + float2(-29.0f, 71.0f));
        float cos_theta = sqrt((1.0f - u1) / (1.0f + (alpha * alpha - 1.0f) * u1));
        float sin_theta = sqrt(max(1.0f - cos_theta * cos_theta, 0.0f));
        float phi = 2.0f * PI * u2;
        float3 helper = abs(N.y) < 0.99f ? float3(0, 1, 0) : float3(1, 0, 0);
        float3 T = normalize(cross(helper, N));
        float3 B = cross(N, T);
        float3 H = T * (sin_theta * cos(phi)) + B * (sin_theta * sin(phi)) + N * cos_theta;
        float3 sampled = reflect(V, H);
        // Directions below the surface would only hit the surface itself.
        if (dot(sampled, N) > 0.0f) R = sampled;
    }

    // Stop the ray before it crosses the near plane, where it cannot be projected.
    float near_z = ViewDepthFromDevice(0.0f);
    float ray_length = ssr_max_distance;
    if (R.z < 0.0f) ray_length = min(ray_length, max(P.z - near_z * 1.5f, 0.0f) / -R.z);
    float3 end = P + R * ray_length;

    // March in screen space; view depth along the ray is linear in 1/z there.
    float2 start_uv = ClipToUv(mul(float4(P, 1.0f), projection));
    float2 end_uv = ClipToUv(mul(float4(end, 1.0f), projection));
    float2 pixel_delta = (end_uv - start_uv) * size;
    uint steps = uint(clamp(max(abs(pixel_delta.x), abs(pixel_delta.y)), 1.0f, float(SSR_MAX_STEPS)));
    float step_t = 1.0f / float(steps);
    float inverse_start_z = 1.0f / P.z;
    float inverse_end_z = 1.0f / end.z;

    float previous_t = 0.0f;
    float previous_z = P.z;
    float hit_t = -1.0f;
    [loop]
    for (uint i = 0u; i < steps; ++i)
    {
        // The first sample is at least a step out, past the surface itself.
        float t = (float(i) + 0.5f + march_noise) * step_t;
        float2 uv = lerp(start_uv, end_uv, t);
        if (any(uv < 0.0f) || any(uv > 1.0f) || t > 1.0f)
        {
            break;
        }
        float ray_z = 1.0f / lerp(inverse_start_z, inverse_end_z, t);
        float scene_z = SceneViewDepth(uv, size);
        // Hit when the segment since the last sample passes behind the
        // visible surface, but not so far behind that it went around it.
        if (max(previous_z, ray_z) >= scene_z && min(previous_z, ray_z) <= scene_z + ssr_thickness)
        {
            hit_t = t;
            break;
        }
        previous_t = t;
        previous_z = ray_z;
    }

    float4 result = 0.0f;
    [branch]
    if (hit_t >= 0.0f)
    {
        // Narrow the crossing down between the last two samples.
        float low = previous_t;
        float high = hit_t;
        [unroll]
        for (uint j = 0u; j < SSR_REFINE_STEPS; ++j)
        {
            float middle = 0.5f * (low + high);
            float ray_z = 1.0f / lerp(inverse_start_z, inverse_end_z, middle);
            if (ray_z >= SceneViewDepth(lerp(start_uv, end_uv, middle), size)) high = middle;
            else low = middle;
        }

        float2 hit_uv = lerp(start_uv, end_uv, high);
        int2 hit_pixel = clamp(int2(hit_uv * size), int2(0, 0), int2(size) - 1);
        // Where that surface was last frame, in the image being read.
        float2 previous_uv = hit_uv - g_velocity.Load(int3(hit_pixel, 0));
        float3 hit_normal = g_surface.Load(int3(hit_pixel, 0)).xyz;

        float2 edge = min(previous_uv, 1.0f - previous_uv);
        float confidence = saturate(min(edge.x, edge.y) / SSR_EDGE_FADE);
        // Fade towards the end of the ray, so the cutoff does not show.
        confidence *= 1.0f - high * high;
        // A surface facing away is the back of something; its color is unknown.
        confidence *= saturate(-dot(hit_normal, R) * 4.0f);
        // Smoothly hand rough surfaces over to the environment.
        confidence *= 1.0f - smoothstep(0.6f * ssr_max_roughness, ssr_max_roughness, surface_roughness);

        float3 color = g_scene_color.SampleLevel(g_clamp_sampler, saturate(previous_uv), 0).rgb;
        result = float4(color * confidence, confidence);
    }
    return result;
}

float4 PSSsr(FullscreenInput input) : SV_TARGET
{
    uint width, height;
    g_depth.GetDimensions(width, height);
    int2 pixel = int2(input.position.xy);

    // The prepass clears the sky to roughness 1, so this skips it too.
    float4 surface = g_surface.Load(int3(pixel, 0));
    float4 result = 0.0f;
    [branch]
    if (surface.w < ssr_max_roughness)
    {
        result = TraceReflection(pixel, float2(width, height), normalize(surface.xyz), surface.w);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Light clusters: one thread per cluster (a group per depth slice) tests every
// visible light against the cluster's view-space box and lists those that
// reach it. The lit and blended passes then loop over their cluster's list.

RWStructuredBuffer<uint> g_cluster_lights_out : register(u0);

// View-space point at view depth z on the screen at `ndc` (y up), with the
// projection's TAA jitter undone like ViewPositionAt.
float3 ViewPointAtNdc(float2 ndc, float z)
{
    return float3(
        (ndc.x - projection[2][0]) * z / projection[0][0],
        (ndc.y - projection[2][1]) * z / projection[1][1],
        z
    );
}

// Whether a sphere misses a spot light's cone (Bart Wronski, "Cull that
// cone!"); `cos_angle`/`sin_angle` describe the outer angle. Positions and
// the axis are in view space.
bool SphereOutsideCone(float3 center, float radius, float3 apex, float3 axis, float range, float cos_angle, float sin_angle)
{
    float3 to_center = center - apex;
    float along = dot(to_center, axis);
    float across = sqrt(max(dot(to_center, to_center) - along * along, 0.0f));
    float distance_to_cone = cos_angle * across - along * sin_angle;
    return distance_to_cone > radius || along > range + radius || along < -radius;
}

[numthreads(LIGHT_CLUSTER_X, LIGHT_CLUSTER_Y, 1)]
void CSBuildLightClusters(uint3 id : SV_DispatchThreadID)
{
    // The cluster's corners: its tile at the slice's near and far depth.
    float near_z = exp2((float(id.z) - cluster_depth_bias) / cluster_depth_scale);
    float far_z = exp2((float(id.z) + 1.0f - cluster_depth_bias) / cluster_depth_scale);
    float2 tile_size = 2.0f / float2(LIGHT_CLUSTER_X, LIGHT_CLUSTER_Y);
    float2 ndc_min = float2(-1.0f + float(id.x) * tile_size.x, 1.0f - float(id.y + 1u) * tile_size.y);
    float2 ndc_max = ndc_min + tile_size;

    float3 box_min = ViewPointAtNdc(ndc_min, near_z);
    float3 box_max = box_min;
    [unroll]
    for (uint corner = 0u; corner < 8u; ++corner)
    {
        float2 ndc = float2((corner & 1u) ? ndc_max.x : ndc_min.x, (corner & 2u) ? ndc_max.y : ndc_min.y);
        float3 p = ViewPointAtNdc(ndc, (corner & 4u) ? far_z : near_z);
        box_min = min(box_min, p);
        box_max = max(box_max, p);
    }
    float3 box_center = 0.5f * (box_min + box_max);
    float box_radius = length(box_max - box_center);

    uint base = ((id.z * LIGHT_CLUSTER_Y + id.y) * LIGHT_CLUSTER_X + id.x) * LIGHT_CLUSTER_STRIDE;
    uint count = 0u;
    for (uint i = 0u; i < light_count && count < MAX_LIGHTS_PER_CLUSTER; ++i)
    {
        GpuLight light = g_lights[i];
        float3 center = mul(float4(light.position, 1.0f), view).xyz;
        // The light's range sphere against the box.
        float3 nearest = clamp(center, box_min, box_max);
        float3 offset = nearest - center;
        bool reaches = dot(offset, offset) <= light.range * light.range;
        if (reaches && light.spot_scale > 0.0f)
        {
            // cone = saturate(cos * scale + offset) is zero at the outer angle.
            float cos_outer = clamp(-light.spot_offset / light.spot_scale, -1.0f, 1.0f);
            float3 axis = mul(light.direction, (float3x3)view);
            reaches = !SphereOutsideCone(
                box_center, box_radius, center, axis, light.range,
                cos_outer, sqrt(1.0f - cos_outer * cos_outer)
            );
        }
        if (reaches)
        {
            g_cluster_lights_out[base + 1u + count] = i;
            ++count;
        }
    }
    g_cluster_lights_out[base] = count;
}

// ---------------------------------------------------------------------------
// Volumetric fog: a grid of view-aligned cells (froxels) out to
// fog_max_distance. CSFogInject computes each cell's density and the light it
// scatters towards the camera, blended with last frame's result;
// CSFogIntegrate accumulates scattering and transmittance front to back; and
// PSFogApply blends the result over the lit image. Must match renderer_fog.odin.

#define FOG_X 160
#define FOG_Y 90
#define FOG_Z 64
// Share of the new frame when blending with the reprojected history.
#define FOG_HISTORY_BLEND 0.1f

// Inject: last frame's cells. Integrate: this frame's. Apply: the integrated
// volume.
Texture3D<float4> g_fog_volume : register(t0);
RWTexture3D<float4> g_fog_output : register(u0);

// Cell depth is quadratic in the slice coordinate w (0 to 1), so cells are
// thin near the camera, where detail shows, and deep in the distance.
float FogSliceDepth(float w)
{
    return fog_max_distance * w * w;
}

float FogSliceCoordinate(float view_depth)
{
    return sqrt(saturate(view_depth / fog_max_distance));
}

// Share of light scattered by angle theta from its direction of travel.
float HenyeyGreenstein(float cos_theta, float g)
{
    float g2 = g * g;
    return (1.0f - g2) / (4.0f * PI * pow(max(1.0f + g2 - 2.0f * g * cos_theta, 0.0001f), 1.5f));
}

float FogDensity(float3 world_pos)
{
    return fog_density * exp(-fog_height_falloff * max(world_pos.y - fog_height, 0.0f));
}

// Sun visibility from the shadow cascades: one comparison tap, since the fog
// is soft and the history averages the cells' jittered positions.
float FogSunVisibility(float3 world_pos, float view_depth, float view_distance)
{
    uint cascade = SHADOW_CASCADE_COUNT;
    [unroll]
    for (uint c = SHADOW_CASCADE_COUNT; c > 0u; --c)
    {
        if (view_depth < cascade_split_depth[c - 1u]) cascade = c - 1u;
    }
    float visibility = 1.0f;
    if (cascade < SHADOW_CASCADE_COUNT)
    {
        float4 clip = mul(float4(world_pos, 1.0f), cascade_view_projection[cascade]);
        float3 ndc = clip.xyz / clip.w;
        float2 uv = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
        if (all(uv >= 0.0f) && all(uv <= 1.0f) && ndc.z <= 1.0f)
        {
            float bias = shadow_bias_constant * cascade_texel_depth[cascade];
            visibility = g_shadow_map.SampleCmpLevelZero(
                g_shadow_sampler, float3(uv, float(cascade)), ndc.z - bias
            );
        }
    }
    // Fades out like the lit pass's sun shadows.
    float fade = saturate((view_distance - shadow_fade_start) / max(shadow_fade_end - shadow_fade_start, 0.0001f));
    return lerp(visibility, 1.0f, fade);
}

// The world position at slice coordinate w in the column of `cell`.
float3 FogCellWorldPosition(uint2 cell, float w, out float view_depth, out float view_distance)
{
    float2 uv = (float2(cell) + 0.5f) / float2(FOG_X, FOG_Y);
    view_depth = max(FogSliceDepth(w), ViewDepthFromDevice(0.0f));
    float3 view_pos = ViewPointAtNdc(float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f), view_depth);
    view_distance = length(view_pos);
    // The view matrix is orthonormal: its transpose rotates back to world.
    return view_position + mul((float3x3)view, view_pos);
}

[numthreads(8, 8, 1)]
void CSFogInject(uint3 id : SV_DispatchThreadID)
{
    if (any(id >= uint3(FOG_X, FOG_Y, FOG_Z))) return;

    // Sample at a different depth within the cell each frame; the history
    // blend averages them, so thin shadows do not band between slices.
    float jitter = 0.5f;
    if (fog_history_valid != 0u)
    {
        jitter = frac(InterleavedGradientNoise(float2(id.xy) + float(id.z) * 7.13f) + float(fog_frame % 64u) * 0.618034f);
    }
    float view_depth, view_distance;
    float3 world_pos = FogCellWorldPosition(id.xy, (float(id.z) + jitter) / FOG_Z, view_depth, view_distance);
    float3 to_camera = normalize(view_position - world_pos);
    float density = FogDensity(world_pos);

    // Sky light arrives evenly from all directions, so its phase integrates to 1.
    float3 light = fog_ambient;

    float3 sun_L = normalize(-sun_direction);
    light += sun_color * sun_intensity *
             FogSunVisibility(world_pos, view_depth, view_distance) *
             HenyeyGreenstein(dot(-sun_L, to_camera), fog_anisotropy);

    // Point and spot lights through the light clusters, with their shadows.
    float2 cluster_pixel = (float2(id.xy) + 0.5f) / float2(FOG_X, FOG_Y) * cluster_screen_size;
    uint cluster_base = LightClusterBase(cluster_pixel, view_depth);
    uint cluster_light_count = g_cluster_lights[cluster_base];
    for (uint i = 0u; i < cluster_light_count; ++i)
    {
        GpuLight local = g_lights[g_cluster_lights[cluster_base + 1u + i]];
        float3 L;
        float attenuation = LightAttenuation(local, local.position - world_pos, L);
        float shadow = 1.0f;
        [branch]
        if (attenuation > 0.0f)
        {
            shadow = local.spot_scale > 0.0f
                ? SpotShadowVisibility(local, world_pos, float3(0.0f, 0.0f, 0.0f))
                : PointShadowVisibility(local, world_pos, float3(0.0f, 0.0f, 0.0f));
        }
        light += local.radiance * attenuation * shadow *
                 HenyeyGreenstein(dot(-L, to_camera), fog_anisotropy);
    }

    // Light scattered towards the camera per unit length, and extinction.
    float4 result = float4(fog_albedo * density * light, density);

    // Blend with where this cell's center was in last frame's volume.
    if (fog_history_valid != 0u)
    {
        float center_depth, center_distance;
        float3 center = FogCellWorldPosition(id.xy, (float(id.z) + 0.5f) / FOG_Z, center_depth, center_distance);
        float4 previous_clip = mul(float4(center, 1.0f), previous_view_projection);
        if (previous_clip.w > 0.0f)
        {
            float3 previous = float3(ClipToUv(previous_clip), FogSliceCoordinate(previous_clip.w));
            if (all(previous >= 0.0f) && all(previous <= 1.0f))
            {
                float4 history = g_fog_volume.SampleLevel(g_clamp_sampler, previous, 0);
                result = lerp(history, result, FOG_HISTORY_BLEND);
            }
        }
    }
    g_fog_output[id] = result;
}

// Marches each column of cells front to back. Each cell stores the light
// scattered towards the camera and the transmittance from the camera to its
// far end.
[numthreads(8, 8, 1)]
void CSFogIntegrate(uint3 id : SV_DispatchThreadID)
{
    if (any(id.xy >= uint2(FOG_X, FOG_Y))) return;

    // Distance along this column's ray per unit of view depth.
    float2 uv = (float2(id.xy) + 0.5f) / float2(FOG_X, FOG_Y);
    float ray_scale = length(ViewPointAtNdc(float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f), 1.0f));

    float3 scattered = 0.0f;
    float transmittance = 1.0f;
    float previous_depth = 0.0f;
    for (uint z = 0u; z < FOG_Z; ++z)
    {
        float depth = FogSliceDepth(float(z + 1u) / FOG_Z);
        float thickness = (depth - previous_depth) * ray_scale;
        previous_depth = depth;

        float4 cell = g_fog_volume.Load(int4(id.xy, z, 0));
        float extinction = max(cell.a, 0.000001f);
        float cell_transmittance = exp(-extinction * thickness);
        // Scattering integrated over the cell, dimmed by the cell itself
        // (Hillaire, "Physically Based and Unified Volumetric Rendering in
        // Frostbite", 2015), then by everything in front of it.
        scattered += transmittance * (cell.rgb - cell.rgb * cell_transmittance) / extinction;
        transmittance *= cell_transmittance;
        g_fog_output[uint3(id.xy, z)] = float4(scattered, transmittance);
    }
}

// Blends the fog in front of each pixel over the lit image: the pipeline
// computes fog.rgb + scene * fog.a.
float4 PSFogApply(FullscreenInput input) : SV_TARGET
{
    float view_depth = ViewDepthFromDevice(g_depth.Load(int3(input.position.xy, 0)));
    float w = FogSliceCoordinate(view_depth);
    // Cell z holds the fog up to its far end, its texel center plus half a
    // cell. Closer than the first cell's end, fade in from no fog.
    float4 fog = g_fog_volume.SampleLevel(
        g_clamp_sampler, float3(input.uv, max(w - 0.5f / FOG_Z, 0.5f / FOG_Z)), 0
    );
    return lerp(float4(0.0f, 0.0f, 0.0f, 1.0f), fog, saturate(w * FOG_Z));
}
