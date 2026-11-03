// Irradiance volumes (renderer_probes.odin): reduces a cell's cube capture to
// L1 spherical harmonics in the volume atlas, and clears a volume's block.
//
// The atlas holds a 32^3 block of cells per volume, one after another along
// z. Each block has four planes along x: the red, green and blue
// coefficients, then the cell's validity and the offset it was captured
// from. The coefficients are stored times the validity, so that the lit pass
// can weight cells and divide by the weighted validity.

#define VOLUME_MAX_CELLS 32u
// The capture level read: VOLUME_SH_LEVEL of the 256 x 256 capture.
#define FACE_SIZE 32u
#define FACE_TEXELS (FACE_SIZE * FACE_SIZE)
#define GROUP_SIZE 256u
// A cell is valid while at most this share of its view is back faces, and
// invalid from BACKFACE_INVALID on (inside a wall or a closed model).
#define BACKFACE_VALID 0.1f
#define BACKFACE_INVALID 0.3f

cbuffer VolumePass : register(b0)
{
    uint3 g_cell;    // The cell in its block.
    uint g_first_z;  // The block's first slice.
    float3 g_offset; // Where it was captured from, in cells from its center.
    float _pad;
};

// The capture level as six slices, one per cube face.
Texture2DArray<float4> g_capture : register(t0);
RWTexture3D<float4> g_atlas : register(u0);
// The cell's validity and back-face share, read back by the CPU, which
// captures an invalid cell again from another point.
RWStructuredBuffer<float4> g_result : register(u1);

// The direction through face coordinates (s right, t down, both -1 to 1) of
// a cube face, as TextureCube addresses them.
float3 FaceDirection(uint face, float s, float t)
{
    switch (face)
    {
        case 0u: return float3(1.0f, -t, -s);
        case 1u: return float3(-1.0f, -t, s);
        case 2u: return float3(s, 1.0f, t);
        case 3u: return float3(s, -1.0f, -t);
        case 4u: return float3(s, -t, 1.0f);
        default: return float3(-s, -t, -1.0f);
    }
}

// Per thread, then reduced: the red, green and blue coefficients (constant
// term, then x, y, z), and the solid angle seen and the part of it that is
// front faces.
groupshared float4 gs_red[GROUP_SIZE];
groupshared float4 gs_green[GROUP_SIZE];
groupshared float4 gs_blue[GROUP_SIZE];
groupshared float2 gs_coverage[GROUP_SIZE];

// One group per cell. Each texel's radiance is weighted by the solid angle
// it covers and the basis functions along its direction.
[numthreads(GROUP_SIZE, 1, 1)]
void CSProjectCell(uint thread : SV_GroupIndex)
{
    float4 red = 0.0f, green = 0.0f, blue = 0.0f;
    float2 coverage = 0.0f;
    for (uint i = thread; i < 6u * FACE_TEXELS; i += GROUP_SIZE)
    {
        uint face = i / FACE_TEXELS;
        uint2 xy = uint2(i % FACE_SIZE, (i % FACE_TEXELS) / FACE_SIZE);
        float2 st = (float2(xy) + 0.5f) / FACE_SIZE * 2.0f - 1.0f;
        float3 direction = FaceDirection(face, st.x, st.y);
        // A texel's solid angle: its area (2 / size)^2 over the cube of its
        // distance from the center.
        float length_squared = dot(direction, direction);
        float solid_angle = 4.0f / FACE_TEXELS / (length_squared * sqrt(length_squared));
        direction *= rsqrt(length_squared);

        // Back-face texels hold zero light and coverage (PSCaptureVolume).
        float4 texel = g_capture.Load(int4(xy, face, 0));
        // Y00 = 0.282095; Y1m = 0.488603 times x, y or z.
        float4 basis = solid_angle * float4(0.282095f, 0.488603f * direction);
        red += texel.r * basis;
        green += texel.g * basis;
        blue += texel.b * basis;
        coverage += solid_angle * float2(1.0f, texel.a);
    }
    gs_red[thread] = red;
    gs_green[thread] = green;
    gs_blue[thread] = blue;
    gs_coverage[thread] = coverage;
    GroupMemoryBarrierWithGroupSync();

    for (uint stride = GROUP_SIZE / 2u; stride > 0u; stride /= 2u)
    {
        if (thread < stride)
        {
            gs_red[thread] += gs_red[thread + stride];
            gs_green[thread] += gs_green[thread + stride];
            gs_blue[thread] += gs_blue[thread + stride];
            gs_coverage[thread] += gs_coverage[thread + stride];
        }
        GroupMemoryBarrierWithGroupSync();
    }
    if (thread != 0u) return;

    float backface = 1.0f - gs_coverage[0].y / gs_coverage[0].x;
    float validity = saturate((BACKFACE_INVALID - backface) / (BACKFACE_INVALID - BACKFACE_VALID));
    // Ready to evaluate: the cosine-weighted average radiance along normal N
    // (irradiance / pi) is Y00 L00 + 2/3 (Y1 . N) L1, with the cosine
    // lobe's convolution (pi and 2 pi / 3) divided by pi.
    float4 scale = validity * float4(0.282095f, (2.0f / 3.0f) * 0.488603f.xxx);
    uint3 cell = uint3(g_cell.xy, g_first_z + g_cell.z);
    g_atlas[cell] = gs_red[0] * scale;
    g_atlas[cell + uint3(VOLUME_MAX_CELLS, 0u, 0u)] = gs_green[0] * scale;
    g_atlas[cell + uint3(2u * VOLUME_MAX_CELLS, 0u, 0u)] = gs_blue[0] * scale;
    g_atlas[cell + uint3(3u * VOLUME_MAX_CELLS, 0u, 0u)] = float4(validity, g_offset);
    g_result[0] = float4(validity, backface, 0.0f, 0.0f);
}

// Zeroes one volume's block: no cell has light or validity.
[numthreads(4, 4, 4)]
void CSClearSlot(uint3 id : SV_DispatchThreadID)
{
    g_atlas[uint3(id.xy, g_first_z + id.z)] = 0.0f;
}
