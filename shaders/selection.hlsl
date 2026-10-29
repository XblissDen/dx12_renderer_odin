cbuffer SelectionConstants : register(b0)
{
    float4x4 model_view_projection;
    float3 bounds_min;
    float primary; // 1 for the primary selection.
    float3 bounds_max;
    float _pad1;
};

// Corner bits select max X, max Y, and max Z respectively.
static const uint edge_corners[24] = {
    0, 1, 1, 3, 3, 2, 2, 0,
    4, 5, 5, 7, 7, 6, 6, 4,
    0, 4, 1, 5, 2, 6, 3, 7
};

float4 VSMain(uint vertex_id : SV_VertexID) : SV_POSITION
{
    uint corner = edge_corners[vertex_id];
    float3 position = float3(
        (corner & 1u) ? bounds_max.x : bounds_min.x,
        (corner & 2u) ? bounds_max.y : bounds_min.y,
        (corner & 4u) ? bounds_max.z : bounds_min.z
    );
    return mul(float4(position, 1.0f), model_view_projection);
}

// Orange for the primary selection (the Inspector and gizmo's), darker for
// the rest.
float4 PSMain() : SV_TARGET
{
    return primary != 0.0f ? float4(1.0f, 0.65f, 0.08f, 1.0f) : float4(0.55f, 0.3f, 0.05f, 1.0f);
}