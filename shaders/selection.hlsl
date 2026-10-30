// Selection outline and debug lines. The mask pass draws each selected group
// (a selected entity with its descendants) into an integer target as the
// group's id; the outline pass then colors the pixels just outside each
// group's silhouette. A group's meshes share one id, so the outline goes
// around the group as a whole, not around each mesh in it.

cbuffer SelectionConstants : register(b0)
{
    float4x4 model_view_projection;
    // 1 for the primary selection's group, then 2, 3... Debug lines: 1 while
    // drawing the parts the scene hides.
    uint group;
    float3 camera_position; // Debug lines only.
};

Texture2D<uint> selection_mask : register(t0);

// Outline width in pixels.
static const int OUTLINE_RADIUS = 2;

float4 VSMask(float3 position : POSITION) : SV_POSITION
{
    return mul(float4(position, 1.0f), model_view_projection);
}

uint PSMask() : SV_TARGET
{
    return group;
}

float4 VSOutline(uint vertex_id : SV_VertexID) : SV_POSITION
{
    // One triangle covering the screen.
    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);
    return float4(uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
}

// A pixel within OUTLINE_RADIUS of a group it is not part of takes that
// group's color: orange for the primary selection, darker for the rest. The
// mask is drawn without depth testing, so hidden parts are outlined too.
float4 PSOutline(float4 position : SV_POSITION) : SV_TARGET
{
    uint width, height;
    selection_mask.GetDimensions(width, height);
    int2 pixel = int2(position.xy);
    int2 last = int2(width, height) - 1;
    uint self = selection_mask[pixel];

    uint found = 0;
    [loop] for (int y = -OUTLINE_RADIUS; y <= OUTLINE_RADIUS; y++)
    {
        [loop] for (int x = -OUTLINE_RADIUS; x <= OUTLINE_RADIUS; x++)
        {
            // A round brush.
            if (x * x + y * y > OUTLINE_RADIUS * OUTLINE_RADIUS + 1)
                continue;
            uint other = selection_mask[clamp(pixel + int2(x, y), int2(0, 0), last)];
            if (other != 0 && other != self && found != 1)
                found = other;
        }
    }
    if (found == 0)
        discard;
    return found == 1 ? float4(1.0f, 0.65f, 0.08f, 1.0f) : float4(0.55f, 0.3f, 0.05f, 1.0f);
}

// How much of a debug line's distance from the camera it is pulled towards
// the camera before the depth test, so a line lying on a surface (a box
// around a cube) stays in front of it despite TAA's jittered depth.
static const float LINE_DEPTH_PULL = 0.002f;
// How strongly the parts of a line that the scene hides still show.
static const float LINE_HIDDEN_ALPHA = 0.25f;

struct LineVertex
{
    float4 position : SV_POSITION;
    float4 color : COLOR;
};

LineVertex VSLine(float3 position : POSITION, float4 color : COLOR)
{
    LineVertex output;
    float3 pulled = lerp(position, camera_position, LINE_DEPTH_PULL);
    output.position = mul(float4(pulled, 1.0f), model_view_projection);
    output.color = color;
    return output;
}

float4 PSLine(LineVertex input) : SV_TARGET
{
    float alpha = input.color.a * (group == 1 ? LINE_HIDDEN_ALPHA : 1.0f);
    return float4(input.color.rgb, alpha);
}
