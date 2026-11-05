// The physical sky (renderer_environment.odin), after Hillaire, "A Scalable
// and Production Ready Sky and Atmosphere Rendering Technique" (2020). Earth's
// atmosphere is a shell of air (Rayleigh scattering), haze (Mie scattering and
// absorption) and ozone (absorption) around a planet, with densities that
// fall off with height. Three passes, all in kilometers:
//   PSTransmittance:      how much light gets from a height, along a direction,
//                         out to space (Bruneton's parameterization);
//   PSMultipleScattering: the light scattered twice or more, per height and
//                         sun angle (Hillaire's isotropic approximation);
//   PSSkyPanorama:        the sky seen from just above the ground, ray-marched
//                         into a panorama with both tables. The sun's disc is
//                         left out: the background draws it, and the lit
//                         surfaces get the sun as a directional light.

#include "common.hlsl"

cbuffer AtmosphereConstants : register(b3)
{
    float3 sun_direction;  // Toward the sun.
    float  haze;           // Multiplies the Mie density.
    float3 sun_irradiance; // Above the atmosphere.
    float  viewer_height;  // Above the ground, in km.
    float  ground_albedo;
    float3 _pad;
};

Texture2D<float4> g_transmittance : register(t0);
Texture2D<float4> g_multiple_scattering : register(t1);
SamplerState g_clamp_sampler : register(s4);

struct VSOutput
{
    float4 position : SV_POSITION;
    float2 uv       : TEXCOORD0;
};

// Must match renderer_environment.odin's SKY_* values.
#define PLANET_RADIUS 6360.0f
#define ATMOSPHERE_RADIUS 6460.0f
static const float3 RAYLEIGH_SCATTERING = float3(5.802e-3f, 13.558e-3f, 33.1e-3f);
#define RAYLEIGH_HEIGHT 8.0f
#define MIE_SCATTERING 3.996e-3f
#define MIE_ABSORPTION 4.40e-3f
#define MIE_HEIGHT 1.2f
#define MIE_G 0.8f
static const float3 OZONE_ABSORPTION = float3(0.650e-3f, 1.881e-3f, 0.085e-3f);
#define TRANSMITTANCE_STEPS 40u
#define MULTIPLE_SCATTERING_STEPS 20u
#define MULTIPLE_SCATTERING_DIRECTIONS 8u // squared
#define SKY_STEPS 32u

// The air at a height: Rayleigh and Mie scattering, and the total extinction.
struct Medium
{
    float3 rayleigh;
    float  mie;
    float3 extinction;
};

Medium SampleMedium(float height)
{
    float rayleigh_density = exp(-height / RAYLEIGH_HEIGHT);
    float mie_density = exp(-height / MIE_HEIGHT) * haze;
    // Ozone: a layer 30 km thick, densest at 25 km.
    float ozone_density = max(0.0f, 1.0f - abs(height - 25.0f) / 15.0f);
    Medium medium;
    medium.rayleigh = RAYLEIGH_SCATTERING * rayleigh_density;
    medium.mie = MIE_SCATTERING * mie_density;
    medium.extinction = medium.rayleigh + (MIE_SCATTERING + MIE_ABSORPTION) * mie_density +
                        OZONE_ABSORPTION * ozone_density;
    return medium;
}

// Distance along the ray to the sphere of this radius around the planet's
// center (the nearest crossing ahead), or -1.
float RaySphere(float3 origin, float3 direction, float radius)
{
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    float discriminant = b * b - c;
    float result = -1.0f;
    if (discriminant >= 0.0f)
    {
        float s = sqrt(discriminant);
        if (-b - s >= 0.0f) result = -b - s;
        else if (-b + s >= 0.0f) result = -b + s;
    }
    return result;
}

// Bruneton's mapping of (distance from the center r, cosine of the zenith
// angle mu) to the transmittance table: u by the distance to the top of the
// atmosphere between its least and greatest for this r, v by the height.
// It keeps precision near the horizon, where transmittance changes fastest.
float2 TransmittanceUv(float r, float mu)
{
    float H = sqrt(ATMOSPHERE_RADIUS * ATMOSPHERE_RADIUS - PLANET_RADIUS * PLANET_RADIUS);
    float rho = sqrt(max(r * r - PLANET_RADIUS * PLANET_RADIUS, 0.0f));
    float discriminant = r * r * (mu * mu - 1.0f) + ATMOSPHERE_RADIUS * ATMOSPHERE_RADIUS;
    float d = max(-r * mu + sqrt(max(discriminant, 0.0f)), 0.0f);
    float d_min = ATMOSPHERE_RADIUS - r;
    float d_max = rho + H;
    return float2((d - d_min) / (d_max - d_min), rho / H);
}

float3 Transmittance(float r, float mu)
{
    return g_transmittance.SampleLevel(g_clamp_sampler, TransmittanceUv(r, mu), 0).rgb;
}

float3 MultipleScattering(float r, float mu)
{
    float2 uv = float2(mu * 0.5f + 0.5f, saturate((r - PLANET_RADIUS) / (ATMOSPHERE_RADIUS - PLANET_RADIUS)));
    return g_multiple_scattering.SampleLevel(g_clamp_sampler, uv, 0).rgb;
}

float RayleighPhase(float cos_angle)
{
    return 3.0f / (16.0f * PI) * (1.0f + cos_angle * cos_angle);
}

// Cornette-Shanks: Henyey-Greenstein, corrected towards Mie theory.
float MiePhase(float cos_angle)
{
    float g2 = MIE_G * MIE_G;
    float denominator = pow(max(1.0f + g2 - 2.0f * MIE_G * cos_angle, 1.0e-4f), 1.5f);
    return 3.0f / (8.0f * PI) * (1.0f - g2) * (1.0f + cos_angle * cos_angle) / ((2.0f + g2) * denominator);
}

// The table's texel: (r, mu) back from the mapping above, then the optical
// depth to the top of the atmosphere along that ray.
float4 PSTransmittance(VSOutput input) : SV_TARGET
{
    float H = sqrt(ATMOSPHERE_RADIUS * ATMOSPHERE_RADIUS - PLANET_RADIUS * PLANET_RADIUS);
    float rho = H * input.uv.y;
    float r = sqrt(rho * rho + PLANET_RADIUS * PLANET_RADIUS);
    float d_min = ATMOSPHERE_RADIUS - r;
    float d_max = rho + H;
    float d = d_min + input.uv.x * (d_max - d_min);
    float mu = d == 0.0f ? 1.0f : (H * H - rho * rho - d * d) / (2.0f * r * d);
    mu = clamp(mu, -1.0f, 1.0f);

    float3 origin = float3(0.0f, r, 0.0f);
    float3 direction = float3(sqrt(1.0f - mu * mu), mu, 0.0f);
    float ray_length = max(RaySphere(origin, direction, ATMOSPHERE_RADIUS), 0.0f);
    float3 depth = 0.0f;
    for (uint i = 0u; i < TRANSMITTANCE_STEPS; ++i)
    {
        float3 p = origin + direction * ((float(i) + 0.5f) / float(TRANSMITTANCE_STEPS) * ray_length);
        depth += SampleMedium(length(p) - PLANET_RADIUS).extinction;
    }
    return float4(exp(-depth * ray_length / float(TRANSMITTANCE_STEPS)), 1.0f);
}

// Light scattered twice or more, at a height (v) with the sun at a zenith
// cosine (u), per unit of sun irradiance. Hillaire's approximation: the
// second-order light L2 arriving at a point, averaged over every direction
// with an isotropic phase, and the share f of light a point scatters back to
// itself; every further order scales by f again, so all orders sum to
// L2 / (1 - f). Rays that reach the ground add the light it reflects.
float4 PSMultipleScattering(VSOutput input) : SV_TARGET
{
    float mu_sun = input.uv.x * 2.0f - 1.0f;
    float r = PLANET_RADIUS + max(input.uv.y * (ATMOSPHERE_RADIUS - PLANET_RADIUS), 0.01f);
    float3 origin = float3(0.0f, r, 0.0f);
    float3 sun = float3(sqrt(saturate(1.0f - mu_sun * mu_sun)), mu_sun, 0.0f);
    const float isotropic = 1.0f / (4.0f * PI);

    float3 light = 0.0f;
    float3 transfer = 0.0f;
    for (uint y = 0u; y < MULTIPLE_SCATTERING_DIRECTIONS; ++y)
    {
        for (uint x = 0u; x < MULTIPLE_SCATTERING_DIRECTIONS; ++x)
        {
            // Directions spread evenly over the sphere.
            float cos_theta = 1.0f - 2.0f * (float(y) + 0.5f) / float(MULTIPLE_SCATTERING_DIRECTIONS);
            float phi = 2.0f * PI * (float(x) + 0.5f) / float(MULTIPLE_SCATTERING_DIRECTIONS);
            float sin_theta = sqrt(saturate(1.0f - cos_theta * cos_theta));
            float3 direction = float3(sin_theta * cos(phi), cos_theta, sin_theta * sin(phi));

            float ground = RaySphere(origin, direction, PLANET_RADIUS);
            float ray_length = ground >= 0.0f ? ground : max(RaySphere(origin, direction, ATMOSPHERE_RADIUS), 0.0f);
            float step = ray_length / float(MULTIPLE_SCATTERING_STEPS);
            float3 throughput = 1.0f;
            for (uint i = 0u; i < MULTIPLE_SCATTERING_STEPS; ++i)
            {
                float3 p = origin + direction * ((float(i) + 0.5f) * step);
                float height = length(p);
                Medium medium = SampleMedium(height - PLANET_RADIUS);
                float3 scattering = medium.rayleigh + medium.mie;
                float3 extinction = max(medium.extinction, 1.0e-7f);
                float3 sample_transmittance = exp(-extinction * step);
                float mu = dot(p / height, sun);
                float lit = RaySphere(p, sun, PLANET_RADIUS) >= 0.0f ? 0.0f : 1.0f;
                float3 source = Transmittance(height, mu) * lit * scattering * isotropic;
                // Integrated exactly over the step, as if the medium were even.
                light += throughput * (source - source * sample_transmittance) / extinction;
                transfer += throughput * (scattering - scattering * sample_transmittance) / extinction;
                throughput *= sample_transmittance;
            }
            if (ground >= 0.0f)
            {
                float3 p = origin + direction * ground;
                float3 up = normalize(p);
                float mu = dot(up, sun);
                light += throughput * Transmittance(PLANET_RADIUS, mu) * saturate(mu) * ground_albedo / PI;
            }
        }
    }
    // Averaged over the sphere, with the isotropic phase toward this point.
    const float count = float(MULTIPLE_SCATTERING_DIRECTIONS * MULTIPLE_SCATTERING_DIRECTIONS);
    float3 second_order = light / count;
    float3 f = transfer / count;
    return float4(second_order / max(1.0f - f, 1.0e-3f), 1.0f);
}

// The sky in one panorama direction, seen from viewer_height above the
// ground: in-scattered sunlight (single scattering with the phase functions,
// in the planet's shadow or not, plus the multiple-scattering table) marched
// along the view ray to space or to the ground, which then adds the sunlight
// it reflects. Steps get longer with distance, where the air thins.
float4 PSSkyPanorama(VSOutput input) : SV_TARGET
{
    float3 direction = UVToDirection(input.uv);
    float3 origin = float3(0.0f, PLANET_RADIUS + viewer_height, 0.0f);
    float ground = RaySphere(origin, direction, PLANET_RADIUS);
    float ray_length = ground >= 0.0f ? ground : max(RaySphere(origin, direction, ATMOSPHERE_RADIUS), 0.0f);

    float cos_angle = dot(direction, sun_direction);
    float rayleigh_phase = RayleighPhase(cos_angle);
    float mie_phase = MiePhase(cos_angle);

    float3 radiance = 0.0f;
    float3 throughput = 1.0f;
    for (uint i = 0u; i < SKY_STEPS; ++i)
    {
        float t0 = float(i) / float(SKY_STEPS);
        float t1 = float(i + 1u) / float(SKY_STEPS);
        float start = t0 * t0 * ray_length;
        float end = t1 * t1 * ray_length;
        float3 p = origin + direction * (0.5f * (start + end));
        float height = length(p);
        Medium medium = SampleMedium(height - PLANET_RADIUS);
        float3 extinction = max(medium.extinction, 1.0e-7f);
        float3 sample_transmittance = exp(-extinction * (end - start));
        float mu = dot(p / height, sun_direction);
        float lit = RaySphere(p, sun_direction, PLANET_RADIUS) >= 0.0f ? 0.0f : 1.0f;
        float3 single = Transmittance(height, mu) * lit * (medium.rayleigh * rayleigh_phase + medium.mie * mie_phase);
        float3 multiple = MultipleScattering(height, mu) * (medium.rayleigh + medium.mie);
        float3 source = sun_irradiance * (single + multiple);
        radiance += throughput * (source - source * sample_transmittance) / extinction;
        throughput *= sample_transmittance;
    }
    if (ground >= 0.0f)
    {
        float3 up = normalize(origin + direction * ground);
        float mu = dot(up, sun_direction);
        radiance += throughput * sun_irradiance * Transmittance(PLANET_RADIUS, mu) * saturate(mu) * ground_albedo / PI;
    }
    return float4(radiance, 1.0f);
}
