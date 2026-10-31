package main

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// Volumetric fog. The view out to the fog distance is divided into a grid of
// cells (froxels), FOG_X x FOG_Y across the screen and FOG_Z deep. Each frame
// a compute pass works out every cell's density and the light it scatters
// towards the camera (sun with shadows, sky, point and spot lights through
// the light clusters), blended with last frame's result reprojected; a second
// pass accumulates it front to back; and after the lit pass a full-screen
// blend applies it. Must match scene.hlsl.
FOG_X :: 160
FOG_Y :: 90
FOG_Z :: 64
FOG_FORMAT :: dxgi.FORMAT.R16G16B16A16_FLOAT
// [0] and [1]: each cell's scattering and extinction, written in turn (one is
// the history). [2]: the integrated volume.
FOG_VOLUME_COUNT :: 3

DEFAULT_FOG_DENSITY :: f32(0.01)
DEFAULT_FOG_HEIGHT :: f32(0)
DEFAULT_FOG_HEIGHT_FALLOFF :: f32(0.15)
DEFAULT_FOG_ANISOTROPY :: f32(0.6)
DEFAULT_FOG_AMBIENT :: f32(1)
DEFAULT_FOG_DISTANCE :: f32(64)
MAX_FOG_DENSITY :: f32(0.2)
MIN_FOG_HEIGHT :: f32(-100)
MAX_FOG_HEIGHT :: f32(100)
MAX_FOG_HEIGHT_FALLOFF :: f32(2)
MAX_FOG_ANISOTROPY :: f32(0.9)
MAX_FOG_AMBIENT :: f32(4)
MIN_FOG_DISTANCE :: f32(8)
MAX_FOG_DISTANCE :: f32(300)

// Saved with the scene. Absent in older files, which load with fog off.
FogSettings :: struct {
    enabled: bool,
    density: f32,
    height: f32,
    height_falloff: f32,
    color: [3]f32,
    anisotropy: f32,
    ambient: f32,
    distance: f32,
}

renderer_default_fog_settings :: proc() -> FogSettings {
    return {
        enabled = true,
        density = DEFAULT_FOG_DENSITY,
        height = DEFAULT_FOG_HEIGHT,
        height_falloff = DEFAULT_FOG_HEIGHT_FALLOFF,
        color = {1, 1, 1},
        anisotropy = DEFAULT_FOG_ANISOTROPY,
        ambient = DEFAULT_FOG_AMBIENT,
        distance = DEFAULT_FOG_DISTANCE,
    }
}

fog_settings_valid :: proc(s: FogSettings) -> bool {
    return s.density >= 0 && s.density <= MAX_FOG_DENSITY &&
           s.height >= MIN_FOG_HEIGHT && s.height <= MAX_FOG_HEIGHT &&
           s.height_falloff >= 0 && s.height_falloff <= MAX_FOG_HEIGHT_FALLOFF &&
           s.color.r >= 0 && s.color.r <= 1 && s.color.g >= 0 && s.color.g <= 1 && s.color.b >= 0 && s.color.b <= 1 &&
           s.anisotropy >= -MAX_FOG_ANISOTROPY && s.anisotropy <= MAX_FOG_ANISOTROPY &&
           s.ambient >= 0 && s.ambient <= MAX_FOG_AMBIENT &&
           s.distance >= MIN_FOG_DISTANCE && s.distance <= MAX_FOG_DISTANCE
}

Fog_Root_Slot :: enum u32 {
    Frame_Constants, // b4
    Lights,          // t18: root SRV
    Cluster_Lights,  // t19: root SRV
    Cascades,        // t1
    Spot_Shadows,    // t5
    Point_Shadows,   // t6
    Input,           // t0: the volume read
    Output,          // u0: the volume written
}

// The compute root signature, before the pipelines are built.
renderer_create_fog_root_signature :: proc() {
    r := &g_renderer

    table_ranges := [Fog_Root_Slot]d3d12.DESCRIPTOR_RANGE{
        .Frame_Constants = {},
        .Lights = {},
        .Cluster_Lights = {},
        .Cascades = {RangeType = .SRV, NumDescriptors = 1, BaseShaderRegister = 1},
        .Spot_Shadows = {RangeType = .SRV, NumDescriptors = 1, BaseShaderRegister = 5},
        .Point_Shadows = {RangeType = .SRV, NumDescriptors = 1, BaseShaderRegister = 6},
        .Input = {RangeType = .SRV, NumDescriptors = 1, BaseShaderRegister = 0},
        .Output = {RangeType = .UAV, NumDescriptors = 1, BaseShaderRegister = 0},
    }
    params: [Fog_Root_Slot]d3d12.ROOT_PARAMETER
    params[.Frame_Constants].ParameterType = .CBV
    params[.Frame_Constants].Descriptor = {ShaderRegister = 4}
    params[.Lights].ParameterType = .SRV
    params[.Lights].Descriptor = {ShaderRegister = 18}
    params[.Cluster_Lights].ParameterType = .SRV
    params[.Cluster_Lights].Descriptor = {ShaderRegister = 19}
    for slot in Fog_Root_Slot.Cascades..=Fog_Root_Slot.Output {
        params[slot].ParameterType = .DESCRIPTOR_TABLE
        params[slot].DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &table_ranges[slot]}
    }

    // The same registers and settings as the main root signature's.
    samplers := [2]d3d12.STATIC_SAMPLER_DESC{
        {
            Filter = .COMPARISON_MIN_MAG_LINEAR_MIP_POINT,
            AddressU = .BORDER, AddressV = .BORDER, AddressW = .BORDER,
            ComparisonFunc = .LESS_EQUAL,
            BorderColor = .OPAQUE_WHITE,
            ShaderRegister = 1,
        },
        {
            Filter = .MIN_MAG_MIP_LINEAR,
            AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP,
            MaxLOD = 16,
            ShaderRegister = 4,
        },
    }
    rs_desc := d3d12.ROOT_SIGNATURE_DESC{
        NumParameters = len(params),
        pParameters = &params[Fog_Root_Slot(0)],
        NumStaticSamplers = len(samplers),
        pStaticSamplers = &samplers[0],
    }
    r.fog_root_signature = create_root_signature(&rs_desc, "Fog")
}

// The volumes and their views, once the SRV heap exists. Their size does not
// depend on the window.
renderer_create_fog_volumes :: proc() {
    r := &g_renderer
    r.fog_srv_start = renderer_alloc_srv(FOG_VOLUME_COUNT)
    r.fog_uav_start = renderer_alloc_srv(FOG_VOLUME_COUNT)

    heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE3D,
        Width = FOG_X,
        Height = FOG_Y,
        DepthOrArraySize = FOG_Z,
        MipLevels = 1,
        Format = FOG_FORMAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_UNORDERED_ACCESS},
    }
    for i in 0..<FOG_VOLUME_COUNT {
        dx_check(r.device->CreateCommittedResource(
            &heap, {}, &desc, renderer_fog_rest_state(i), nil,
            d3d12.IResource_UUID, (^rawptr)(&r.fog_volumes[i]),
        ))

        srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC{
            Format = FOG_FORMAT,
            ViewDimension = .TEXTURE3D,
            Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
        }
        srv_desc.Texture3D = {MipLevels = 1}
        r.device->CreateShaderResourceView(r.fog_volumes[i], &srv_desc, renderer_srv_cpu(r.fog_srv_start + u32(i)))

        uav_desc := d3d12.UNORDERED_ACCESS_VIEW_DESC{Format = FOG_FORMAT, ViewDimension = .TEXTURE3D}
        uav_desc.Texture3D = {WSize = FOG_Z}
        r.device->CreateUnorderedAccessView(r.fog_volumes[i], nil, &uav_desc, renderer_srv_cpu(r.fog_uav_start + u32(i)))
    }
    r.fog_history_ready = false
}

// Between frames, the cell volumes are read by the next inject pass (compute)
// and the integrated one by the apply pass (pixel shader).
renderer_fog_rest_state :: proc(index: int) -> d3d12.RESOURCE_STATES {
    return {.PIXEL_SHADER_RESOURCE} if index == 2 else {.NON_PIXEL_SHADER_RESOURCE}
}

renderer_release_fog :: proc() {
    r := &g_renderer
    for volume in r.fog_volumes do volume->Release()
    r.fog_root_signature->Release()
}

// The inject and integrate pipelines; rebuilt by shader hot-reload. The apply
// pipeline is a full-screen one (renderer_create_pipelines).
renderer_create_fog_pipelines :: proc() {
    r := &g_renderer
    entries := [2]cstring{"CSFogInject", "CSFogIntegrate"}
    pipelines := [2]^^d3d12.IPipelineState{&r.fog_inject_pipeline_state, &r.fog_integrate_pipeline_state}
    for entry, i in entries {
        cs := renderer_compile_shader("shaders/scene.hlsl", entry, "cs_5_1")
        defer cs->Release()
        if renderer_skip_pipeline() do continue
        desc := d3d12.COMPUTE_PIPELINE_STATE_DESC{pRootSignature = r.fog_root_signature, CS = shader_bytecode(cs)}
        renderer_check_pipeline(r.device->CreateComputePipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(pipelines[i])))
    }
}

// Whether this frame has fog: the volume is built and the lit image gets it.
renderer_fog_active :: proc() -> bool {
    return g_renderer.fog.enabled && g_renderer.fog.density > 0
}

// Builds this frame's fog volume. Runs after the shadow maps and light
// clusters, before the lit pass.
renderer_render_fog :: proc() {
    r := &g_renderer

    renderer_begin_gpu_pass(.Fog)
    defer renderer_end_gpu_pass(.Fog)
    if !renderer_fog_active() {
        // Turning fog back on starts without history.
        r.fog_history_ready = false
        return
    }

    write := r.fog_write_index
    read := 1 - write
    barriers := [2]d3d12.RESOURCE_BARRIER{
        resource_transition(r.fog_volumes[write], renderer_fog_rest_state(write), {.UNORDERED_ACCESS}),
        resource_transition(r.fog_volumes[2], renderer_fog_rest_state(2), {.UNORDERED_ACCESS}),
    }
    r.command_list->ResourceBarrier(len(barriers), &barriers[0])

    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetComputeRootSignature(r.fog_root_signature)
    r.command_list->SetComputeRootConstantBufferView(u32(Fog_Root_Slot.Frame_Constants), renderer_frame_cb_address())
    r.command_list->SetComputeRootShaderResourceView(u32(Fog_Root_Slot.Lights), renderer_light_buffer_address())
    r.command_list->SetComputeRootShaderResourceView(u32(Fog_Root_Slot.Cluster_Lights), r.cluster_buffer->GetGPUVirtualAddress())
    r.command_list->SetComputeRootDescriptorTable(u32(Fog_Root_Slot.Cascades), renderer_srv_gpu(r.shadow_srv_index))
    r.command_list->SetComputeRootDescriptorTable(u32(Fog_Root_Slot.Spot_Shadows), renderer_srv_gpu(r.spot_shadow_srv_index))
    r.command_list->SetComputeRootDescriptorTable(u32(Fog_Root_Slot.Point_Shadows), renderer_srv_gpu(r.point_shadow_srv_index))

    // Each cell's light, blended with the history in the other volume.
    r.command_list->SetComputeRootDescriptorTable(u32(Fog_Root_Slot.Input), renderer_srv_gpu(r.fog_srv_start + u32(read)))
    r.command_list->SetComputeRootDescriptorTable(u32(Fog_Root_Slot.Output), renderer_srv_gpu(r.fog_uav_start + u32(write)))
    r.command_list->SetPipelineState(r.fog_inject_pipeline_state)
    r.command_list->Dispatch((FOG_X + 7) / 8, (FOG_Y + 7) / 8, FOG_Z)

    barriers[0] = resource_transition(r.fog_volumes[write], {.UNORDERED_ACCESS}, {.NON_PIXEL_SHADER_RESOURCE})
    r.command_list->ResourceBarrier(1, &barriers[0])

    // Accumulated front to back into the integrated volume.
    r.command_list->SetComputeRootDescriptorTable(u32(Fog_Root_Slot.Input), renderer_srv_gpu(r.fog_srv_start + u32(write)))
    r.command_list->SetComputeRootDescriptorTable(u32(Fog_Root_Slot.Output), renderer_srv_gpu(r.fog_uav_start + 2))
    r.command_list->SetPipelineState(r.fog_integrate_pipeline_state)
    r.command_list->Dispatch((FOG_X + 7) / 8, (FOG_Y + 7) / 8, 1)

    barriers[1] = resource_transition(r.fog_volumes[2], {.UNORDERED_ACCESS}, renderer_fog_rest_state(2))
    r.command_list->ResourceBarrier(1, &barriers[1])

    r.fog_write_index = read
    r.fog_history_ready = true
    r.fog_history_distance = r.fog.distance
}

// Blends the fog over the HDR target, which must be bound as the render
// target with the main root signature and frame constants.
renderer_apply_fog :: proc() {
    r := &g_renderer
    if !renderer_fog_active() do return
    r.command_list->SetPipelineState(r.fog_apply_pipeline_state)
    renderer_bind_srv(.Texture_T0, r.fog_srv_start + 2)
    renderer_bind_srv(.Depth, r.depth_srv_index)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->DrawInstanced(3, 1, 0, 0)
}
