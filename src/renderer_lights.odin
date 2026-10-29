package main

import "core:fmt"
import "core:math"
import d3d12 "vendor:directx/d3d12"

// Clustered lighting. The point and spot lights in view go into a per-frame
// buffer; a compute pass splits the view into a grid of clusters (screen tiles
// times depth slices, spaced logarithmically) and lists the lights reaching
// each. The lit and blended passes loop over only their cluster's lights.
// Must match scene.hlsl.
LIGHT_CLUSTER_X :: 16
LIGHT_CLUSTER_Y :: 9
LIGHT_CLUSTER_Z :: 24
LIGHT_CLUSTER_COUNT :: LIGHT_CLUSTER_X * LIGHT_CLUSTER_Y * LIGHT_CLUSTER_Z
// Each cluster: its light count, then up to this many light indices. Lights
// past it are dropped from that cluster (the cluster view shows it white).
MAX_LIGHTS_PER_CLUSTER :: 127
LIGHT_CLUSTER_STRIDE :: MAX_LIGHTS_PER_CLUSTER + 1

Light_Cluster_Root_Slot :: enum u32 {
    Frame_Constants, // b4
    Lights,          // t18: root SRV
    Clusters,        // u0: root UAV
}

// The per-frame light buffers, the cluster buffer, and the compute root
// signature. The pipeline is built with the others (renderer_create_pipelines).
renderer_create_light_clusters :: proc() {
    r := &g_renderer

    mapped: rawptr
    r.light_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_LIGHTS * size_of(GpuLight)))
    r.light_mapped_data = ([^]GpuLight)(mapped)

    // Buffers decay to the common state after each frame's command list, so
    // every frame starts from there.
    heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = u64(LIGHT_CLUSTER_COUNT * LIGHT_CLUSTER_STRIDE * size_of(u32)),
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
        Flags = {.ALLOW_UNORDERED_ACCESS},
    }
    dx_check(r.device->CreateCommittedResource(
        &heap, {}, &desc, d3d12.RESOURCE_STATE_COMMON, nil,
        d3d12.IResource_UUID, (^rawptr)(&r.cluster_buffer),
    ))

    params: [Light_Cluster_Root_Slot]d3d12.ROOT_PARAMETER
    params[.Frame_Constants].ParameterType = .CBV
    params[.Frame_Constants].Descriptor = {ShaderRegister = 4}
    params[.Lights].ParameterType = .SRV
    params[.Lights].Descriptor = {ShaderRegister = 18}
    params[.Clusters].ParameterType = .UAV
    params[.Clusters].Descriptor = {ShaderRegister = 0}
    rs_desc := d3d12.ROOT_SIGNATURE_DESC{NumParameters = len(params), pParameters = &params[Light_Cluster_Root_Slot(0)]}
    signature, errors: ^d3d12.IBlob
    hr := d3d12.SerializeRootSignature(&rs_desc, ._1, &signature, &errors)
    if errors != nil {
        fmt.println("Light cluster root signature:", cstring(errors->GetBufferPointer()))
        errors->Release()
    }
    dx_check(hr)
    defer signature->Release()
    dx_check(r.device->CreateRootSignature(
        0, signature->GetBufferPointer(), signature->GetBufferSize(),
        d3d12.IRootSignature_UUID, (^rawptr)(&r.cluster_root_signature),
    ))
}

// The cluster pipeline is released with the others (renderer_pipeline_slots).
renderer_release_light_clusters :: proc() {
    r := &g_renderer
    r.light_buffer->Release()
    r.cluster_buffer->Release()
    r.cluster_root_signature->Release()
}

renderer_light_buffer_address :: proc() -> u64 {
    r := &g_renderer
    return r.light_buffer->GetGPUVirtualAddress() + u64(r.frame_slot) * u64(MAX_LIGHTS * size_of(GpuLight))
}

// This frame's slot of the light buffer, which renderer_prepare_frame fills.
renderer_frame_lights :: proc() -> []GpuLight {
    r := &g_renderer
    start := int(r.frame_slot) * MAX_LIGHTS
    return r.light_mapped_data[start:start + MAX_LIGHTS]
}

// Depth slicing: slice = log2(z) * scale + bias puts the near plane at 0 and
// the far plane at LIGHT_CLUSTER_Z, each slice as deep as it is far times a
// constant.
light_cluster_depth_params :: proc(near, far: f32) -> (scale, bias: f32) {
    scale = f32(LIGHT_CLUSTER_Z) / math.log2(far / near)
    bias = -math.log2(near) * scale
    return
}

// Lists the lights reaching each cluster. Runs before the lit pass, which
// reads the result.
renderer_build_light_clusters :: proc() {
    r := &g_renderer

    renderer_begin_gpu_pass(.Light_Clusters)
    barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    barrier.Transition = {
        pResource = r.cluster_buffer,
        StateBefore = d3d12.RESOURCE_STATE_COMMON,
        StateAfter = {.UNORDERED_ACCESS},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    r.command_list->SetComputeRootSignature(r.cluster_root_signature)
    r.command_list->SetPipelineState(r.cluster_pipeline_state)
    r.command_list->SetComputeRootConstantBufferView(u32(Light_Cluster_Root_Slot.Frame_Constants), renderer_frame_cb_address())
    r.command_list->SetComputeRootShaderResourceView(u32(Light_Cluster_Root_Slot.Lights), renderer_light_buffer_address())
    r.command_list->SetComputeRootUnorderedAccessView(u32(Light_Cluster_Root_Slot.Clusters), r.cluster_buffer->GetGPUVirtualAddress())
    r.command_list->Dispatch(1, 1, LIGHT_CLUSTER_Z)

    barrier.Transition.StateBefore = {.UNORDERED_ACCESS}
    // Read by the lit pass and the fog's compute pass.
    barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE, .NON_PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &barrier)
    renderer_end_gpu_pass(.Light_Clusters)
}

// The cluster-building pipeline; rebuilt by shader hot-reload.
renderer_create_light_cluster_pipeline :: proc() {
    r := &g_renderer
    cs := renderer_compile_shader("shaders/scene.hlsl", "CSBuildLightClusters", "cs_5_1")
    defer cs->Release()
    if renderer_skip_pipeline() do return
    desc := d3d12.COMPUTE_PIPELINE_STATE_DESC{pRootSignature = r.cluster_root_signature, CS = shader_bytecode(cs)}
    renderer_check_pipeline(r.device->CreateComputePipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(&r.cluster_pipeline_state)))
}
