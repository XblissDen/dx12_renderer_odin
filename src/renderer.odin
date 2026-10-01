package main

import "base:runtime"
import "core:fmt"
import win32 "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"
import "core:math"
import alg "core:math/linalg"

import "core:image"
import "core:image/png"

FRAME_COUNT :: 2

SHADOW_MAP_SIZE :: 2048
SHADOW_SRV_INDEX  :: TEXTURE_COUNT
HDR_SRV_INDEX  :: TEXTURE_COUNT + 1

BLOOM_TARGET_COUNT :: 2
BLOOM_SRV_START :: HDR_SRV_INDEX + 1

ENVIRONMENT_SRV_INDEX :: BLOOM_SRV_START + BLOOM_TARGET_COUNT

IRRADIANCE_WIDTH :: 64
IRRADIANCE_HEIGHT :: 32
IRRADIANCE_SRV_INDEX :: ENVIRONMENT_SRV_INDEX + 1

PREFILTER_WIDTH :: 512
PREFILTER_HEIGHT :: 256
PREFILTER_MIP_COUNT :: 5
PREFILTER_SRV_INDEX :: IRRADIANCE_SRV_INDEX + 1

GPU_PASS_COUNT :: 6
GPU_TIMESTAMP_COUNT :: GPU_PASS_COUNT * 2

GPU_Pass :: enum u32{
    Shadow,
    Scene,
    Bloom_Extract,
    Bloom_Horizontal,
    Bloom_Vertical,
    Post_Process,
}

Vertex :: struct {
    position:   [3]f32,
    normal:     [3]f32,
    texcoord:   [2]f32,
    tangent:   [4]f32,
}

GpuPointLight :: struct {
    position: [3]f32,
    _pad0: f32,
    color: [3]f32,
    intensity: f32,
}

GpuMesh :: struct {
    vertex_buffer: ^d3d12.IResource,
    vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW,

    index_buffer: ^d3d12.IResource,
    index_buffer_view: d3d12.INDEX_BUFFER_VIEW,
    index_count: u32,
}

SceneConstants :: struct #align(256) {
    model: alg.Matrix4f32,
    view: alg.Matrix4f32,
    projection: alg.Matrix4f32,

    view_position: [3]f32,
    normal_strength: f32,

    material_tint: [3]f32,
    uv_scale: f32,

    light_count: u32,
    unlit: u32,
    roughness: f32,
    metallic: f32,

    lights: [MAX_LIGHTS]GpuPointLight,

    sun_direction: [3]f32,
    use_roughness_map: u32,
    sun_color: [3]f32,
    sun_intensity: f32,

    _sun_matrix_pad: [4]f32,
    sun_view_projection : alg.Matrix4f32,
}

PostConstants :: struct #align(256) {
    exposure: f32,
    bloom_threshold: f32,
    bloom_strength: f32,
    _pad0: f32,
}

SkyConstants :: struct #align(256) {
    forward: [3]f32,
    tan_half_fov: f32,

    right: [3]f32,
    aspect: f32,

    up: [3]f32,
    _pad0: f32,
}

PrefilterConstants :: struct #align(256) {
    roughness: f32,
    _pad0: [3]f32,
}

Renderer :: struct {
    device: ^d3d12.IDevice,
    swap_chain: ^dxgi.ISwapChain3,
    command_queue: ^d3d12.ICommandQueue,

    width: u32,
    height: u32,

    rtv_heap: ^d3d12.IDescriptorHeap,
    rtv_descriptor_size: u32,
    render_targets: [FRAME_COUNT]^d3d12.IResource,

    command_allocators: [FRAME_COUNT]^d3d12.ICommandAllocator,
    command_list: ^d3d12.IGraphicsCommandList,

    fence: ^d3d12.IFence,
    fence_value: u64,
    fence_event: win32.HANDLE,

    root_signature: ^d3d12.IRootSignature,

    viewport: d3d12.VIEWPORT,
    scissor_rect: d3d12.RECT,

    constant_buffer: ^d3d12.IResource,
    cb_mapped_data: [^]SceneConstants,

    depth_buffer: ^d3d12.IResource,
    dsv_heap: ^d3d12.IDescriptorHeap,

    meshes: [MESH_COUNT]GpuMesh,

    textures: [TEXTURE_COUNT]^d3d12.IResource,
    srv_heap: ^d3d12.IDescriptorHeap,
    srv_descriptor_size: u32,

    shadow_map: ^d3d12.IResource,
    shadow_dsv_heap: ^d3d12.IDescriptorHeap,
    shadow_pipeline_state: ^d3d12.IPipelineState,

    hdr_texture: ^d3d12.IResource,
    hdr_rtv_heap: ^d3d12.IDescriptorHeap,

    hdr_pipeline_state: ^d3d12.IPipelineState,
    post_pipeline_state: ^d3d12.IPipelineState,

    bloom_targets: [BLOOM_TARGET_COUNT]^d3d12.IResource,
    bloom_rtv_heap: ^d3d12.IDescriptorHeap,

    // Extract, horizontal blur, vertical blur.
    bloom_pipeline_states: [3]^d3d12.IPipelineState,

    post_constant_buffer: ^d3d12.IResource,
    post_cb_mapped_data: ^PostConstants,

    post_exposure: f32,
    post_threshold: f32,
    post_strength: f32,

    timestamp_heap: ^d3d12.IQueryHeap,
    timestamp_readback: ^d3d12.IResource,
    timestamp_frequency: u64,

    gpu_pass_ms: [GPU_PASS_COUNT]f32,
    fps: f32,
    frame_ms: f32,

    environment_texture: ^d3d12.IResource,
    sky_pipeline_state: ^d3d12.IPipelineState,

    sky_constant_buffer: ^d3d12.IResource,
    sky_cb_mapped_data: ^SkyConstants,

    irradiance_texture: ^d3d12.IResource,
    irradiance_rtv_heap: ^d3d12.IDescriptorHeap,
    irradiance_pipeline_state: ^d3d12.IPipelineState,

    prefilter_texture: ^d3d12.IResource,
    prefilter_rtv_heap: ^d3d12.IDescriptorHeap,
    prefilter_pipeline_state: ^d3d12.IPipelineState,

    prefilter_constant_buffer: ^d3d12.IResource,
    prefilter_cb_mapped_data: [^]PrefilterConstants,

    frame_index: u32,
}

g_renderer: Renderer

dx_check:: proc(hr: win32.HRESULT, loc := #caller_location){
    if hr < 0{
        fmt.panicf("DX12 error 0x%X at %v", u32(hr), loc)
    }
}

renderer_init :: proc() {
    r := &g_renderer

    r.width = WINDOW_WIDTH
    r.height = WINDOW_HEIGHT

    r.post_exposure = 1.0
    r.post_threshold = 1.0
    r.post_strength = 0.6

    // DEBUG LAYER
    when ODIN_DEBUG {
        debug: ^d3d12.IDebug
        if win32.SUCCEEDED(d3d12.GetDebugInterface(d3d12.IDebug_UUID, (^rawptr)(&debug))) {
            debug->EnableDebugLayer()
            debug->Release()
        }
    }

    // FACTORY
    factory_flags: dxgi.CREATE_FACTORY
    when ODIN_DEBUG {
        factory_flags = { .DEBUG }
    }

    factory: ^dxgi.IFactory6
    dx_check(dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory6_UUID, (^rawptr)(&factory)))
    defer factory->Release()

    // ADAPTER
    adapter: ^dxgi.IAdapter1
    dx_check(factory->EnumAdapterByGpuPreference(
        0,
        .HIGH_PERFORMANCE,
        dxgi.IAdapter1_UUID,
        (^rawptr)(&adapter),
    ))
    defer adapter->Release()

    // DEVICE
    dx_check(d3d12.CreateDevice(adapter, ._12_0, d3d12.IDevice_UUID, (^rawptr)(&r.device)))

    // COMMAND QUEUE
    queue_desc := d3d12.COMMAND_QUEUE_DESC{
        Type = .DIRECT,
        Flags = {},
    }
    dx_check(r.device->CreateCommandQueue(&queue_desc, d3d12.ICommandQueue_UUID, (^rawptr)(&r.command_queue)))

    // SWAP CHAIN
    sc_desc := dxgi.SWAP_CHAIN_DESC1{
        BufferCount = FRAME_COUNT,
        Width = r.width,
        Height = r.height,
        Format = .R8G8B8A8_UNORM,
        BufferUsage = {.RENDER_TARGET_OUTPUT},
        SwapEffect = .FLIP_DISCARD,
        SampleDesc = { Count = 1, Quality = 0},
    }

    swap_chain1: ^dxgi.ISwapChain1
    dx_check(factory->CreateSwapChainForHwnd(
        r.command_queue,
        g_hwnd,
        &sc_desc,
        nil, nil,
        &swap_chain1
    ))
    defer swap_chain1->Release()

    factory->MakeWindowAssociation(g_hwnd, {.NO_ALT_ENTER})

    dx_check(swap_chain1->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&r.swap_chain)))
    r.frame_index = r.swap_chain->GetCurrentBackBufferIndex()

    // RTV DESCRIPTOR HEAP
    rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = FRAME_COUNT,
        Type = .RTV,
        Flags = {},
    }
    dx_check(r.device->CreateDescriptorHeap(&rtv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&r.rtv_heap)))
    
    r.rtv_descriptor_size = r.device->GetDescriptorHandleIncrementSize(.RTV)

    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)
    for i in 0..<FRAME_COUNT {
        dx_check(r.swap_chain->GetBuffer(u32(i), d3d12.IResource_UUID, (^rawptr)(&r.render_targets[i])))
        r.device->CreateRenderTargetView(r.render_targets[i], nil, rtv_handle)
        rtv_handle.ptr += uint(r.rtv_descriptor_size)
    }

    // COMMAND ALLOCATORS
    for i in 0..<FRAME_COUNT{
        dx_check(r.device->CreateCommandAllocator(
            .DIRECT,
            d3d12.ICommandAllocator_UUID,
            (^rawptr)(&r.command_allocators[i]),
        ))
    }

    // COMMAND LIST
    dx_check(r.device->CreateCommandList(
        0,
        .DIRECT,
        r.command_allocators[0],
        nil,
        d3d12.IGraphicsCommandList_UUID,
        (^rawptr)(&r.command_list),
    ))
    r.command_list->Close()

    // FENCE
    dx_check(r.device->CreateFence(0, {}, d3d12.IFence_UUID, (^rawptr)(&r.fence)))

    r.fence_event = win32.CreateEventW(nil, false, false, nil)
    if r.fence_event == nil{
        panic("Failed to create fence event")
    }

    dx_check(r.command_queue->GetTimestampFrequency(&r.timestamp_frequency))

    query_desc := d3d12.QUERY_HEAP_DESC{
        Type = .TIMESTAMP,
        Count = GPU_TIMESTAMP_COUNT,
    }
    dx_check(r.device->CreateQueryHeap(
        &query_desc,
        d3d12.IQueryHeap_UUID,
        (^rawptr)(&r.timestamp_heap),
    ))

    readback_heap := d3d12.HEAP_PROPERTIES{Type = .READBACK}
    readback_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = u64(GPU_TIMESTAMP_COUNT * size_of(u64)),
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }

    dx_check(r.device->CreateCommittedResource(
        &readback_heap,
        {},
        &readback_desc,
        {.COPY_DEST},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.timestamp_readback),
    ))
}

renderer_load_assets :: proc(){
    r := &g_renderer

    root_param := d3d12.ROOT_PARAMETER{}
    root_param.ParameterType = .CBV
    root_param.ShaderVisibility = .ALL
    root_param.Descriptor = { ShaderRegister = 0, RegisterSpace = 0}

    // ROOT SIGNATURE
    cbv_param := d3d12.ROOT_PARAMETER{}
    cbv_param.ParameterType = .CBV
    cbv_param.ShaderVisibility = .ALL
    cbv_param.Descriptor = {ShaderRegister = 0}

    srv_range := d3d12.DESCRIPTOR_RANGE{
        RangeType = .SRV,
        NumDescriptors = 1,
        BaseShaderRegister = 0,
        OffsetInDescriptorsFromTableStart = 0,
    }

    srv_param := d3d12.ROOT_PARAMETER{}
    srv_param.ParameterType = .DESCRIPTOR_TABLE
    srv_param.ShaderVisibility = .PIXEL
    srv_param.DescriptorTable = { NumDescriptorRanges = 1, pDescriptorRanges = &srv_range}

    shadow_range := d3d12.DESCRIPTOR_RANGE{
        RangeType = .SRV,
        NumDescriptors = 1,
        BaseShaderRegister = 1,
        OffsetInDescriptorsFromTableStart = 0,
    }

    shadow_param := d3d12.ROOT_PARAMETER{}
    shadow_param.ParameterType = .DESCRIPTOR_TABLE
    shadow_param.ShaderVisibility = .PIXEL
    shadow_param.DescriptorTable = {
        NumDescriptorRanges = 1,
        pDescriptorRanges = &shadow_range,
    }

    post_cbv_param := d3d12.ROOT_PARAMETER{}
    post_cbv_param.ParameterType = .CBV
    post_cbv_param.ShaderVisibility = .PIXEL
    post_cbv_param.Descriptor = {ShaderRegister = 1}

    sky_cbv_param := d3d12.ROOT_PARAMETER{}
    sky_cbv_param.ParameterType = .CBV
    sky_cbv_param.ShaderVisibility = .PIXEL
    sky_cbv_param.Descriptor = {ShaderRegister = 2}

    environment_range := d3d12.DESCRIPTOR_RANGE{
        RangeType = .SRV,
        NumDescriptors = 1,
        BaseShaderRegister = 2,
        OffsetInDescriptorsFromTableStart = 0,
    }
    environment_param := d3d12.ROOT_PARAMETER{}
    environment_param.ParameterType = .DESCRIPTOR_TABLE
    environment_param.ShaderVisibility = .PIXEL
    environment_param.DescriptorTable = {
        NumDescriptorRanges = 1,
        pDescriptorRanges = &environment_range,
    }

    irradiance_range := d3d12.DESCRIPTOR_RANGE{
        RangeType = .SRV,
        NumDescriptors = 1,
        BaseShaderRegister = 3,
        OffsetInDescriptorsFromTableStart = 0,
    }
    irradiance_param := d3d12.ROOT_PARAMETER{}
    irradiance_param.ParameterType = .DESCRIPTOR_TABLE
    irradiance_param.ShaderVisibility = .PIXEL
    irradiance_param.DescriptorTable = {
        NumDescriptorRanges = 1,
        pDescriptorRanges = &irradiance_range,
    }

    prefilter_range := d3d12.DESCRIPTOR_RANGE{
        RangeType = .SRV,
        NumDescriptors = 1,
        BaseShaderRegister = 4,
        OffsetInDescriptorsFromTableStart = 0,
    }
    prefilter_param := d3d12.ROOT_PARAMETER{}
    prefilter_param.ParameterType = .DESCRIPTOR_TABLE
    prefilter_param.ShaderVisibility = .PIXEL
    prefilter_param.DescriptorTable = {
        NumDescriptorRanges = 1,
        pDescriptorRanges = &prefilter_range,
    }

    normal_range := d3d12.DESCRIPTOR_RANGE{
        RangeType = .SRV,
        NumDescriptors = 1,
        BaseShaderRegister = 5,
        OffsetInDescriptorsFromTableStart = 0,
    }

    normal_param := d3d12.ROOT_PARAMETER{}
    normal_param.ParameterType = .DESCRIPTOR_TABLE
    normal_param.ShaderVisibility = .PIXEL
    normal_param.DescriptorTable = {
        NumDescriptorRanges = 1,
        pDescriptorRanges = &normal_range,
    }

    roughness_range := d3d12.DESCRIPTOR_RANGE{
        RangeType = .SRV,
        NumDescriptors = 1,
        BaseShaderRegister = 6,
        OffsetInDescriptorsFromTableStart = 0,
    }

    roughness_param := d3d12.ROOT_PARAMETER{}
    roughness_param.ParameterType = .DESCRIPTOR_TABLE
    roughness_param.ShaderVisibility = .PIXEL
    roughness_param.DescriptorTable = {
        NumDescriptorRanges = 1,
        pDescriptorRanges = &roughness_range,
    }

    prefilter_cbv_param := d3d12.ROOT_PARAMETER{}
    prefilter_cbv_param.ParameterType = .CBV
    prefilter_cbv_param.ShaderVisibility = .PIXEL
    prefilter_cbv_param.Descriptor = {ShaderRegister = 3}

    static_sampler := d3d12.STATIC_SAMPLER_DESC{
        Filter = .MIN_MAG_MIP_LINEAR,
        AddressU = .WRAP,
        AddressV = .WRAP,
        AddressW = .WRAP,
        ShaderRegister = 0,
        ShaderVisibility = .PIXEL,
        MaxLOD = 16.0,
    }

    shadow_sampler := d3d12.STATIC_SAMPLER_DESC{
        Filter = .COMPARISON_MIN_MAG_LINEAR_MIP_POINT,
        AddressU = .BORDER,
        AddressV = .BORDER,
        AddressW = .BORDER,
        ComparisonFunc = .LESS_EQUAL,
        BorderColor = .OPAQUE_WHITE,
        ShaderRegister = 1,
        ShaderVisibility = .PIXEL,
    }

    material_sampler := d3d12.STATIC_SAMPLER_DESC{
        Filter = .ANISOTROPIC,
        AddressU = .WRAP,
        AddressV = .WRAP,
        AddressW = .WRAP,
        MaxAnisotropy = 16,
        ComparisonFunc = .ALWAYS,
        MinLOD = 0,
        MaxLOD = 16.0,
        ShaderRegister = 2,
        ShaderVisibility = .PIXEL,
    }

    params := []d3d12.ROOT_PARAMETER{
        cbv_param,
        srv_param,
        shadow_param,
        post_cbv_param,
        sky_cbv_param,
        environment_param, // Root slot 5 -> t2
        irradiance_param,  // Root slot 6 -> t3
        prefilter_cbv_param, // Root slot 7 -> b3
        prefilter_param,     // Root slot 8 -> t4
        normal_param,    // Root slot 9 -> t5
        roughness_param, // Root slot 10 -> t6
    }
    samplers := []d3d12.STATIC_SAMPLER_DESC{
        static_sampler,
        shadow_sampler,
        material_sampler,
    }
    rs_desc := d3d12.ROOT_SIGNATURE_DESC{
        NumParameters = u32(len(params)),
        pParameters = raw_data(params),
        NumStaticSamplers = u32(len(samplers)),
        pStaticSamplers = raw_data(samplers),
        Flags = { .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT },
    }

    signature: ^d3d12.IBlob
    errors: ^d3d12.IBlob
    dx_check(d3d12.SerializeRootSignature(&rs_desc, ._1, &signature, &errors))
    defer signature->Release()

    dx_check(r.device->CreateRootSignature(
        0,
        signature->GetBufferPointer(),
        signature->GetBufferSize(),
        d3d12.IRootSignature_UUID,
        (^rawptr)(&r.root_signature),
    ))

    // SHADERS
    compile_flags: u32 = 0
    when ODIN_DEBUG{
        compile_flags = u32(d3dc.D3DCOMPILE_FLAG.DEBUG | d3dc.D3DCOMPILE_FLAG.SKIP_OPTIMIZATION)
    }

    vs, ps: ^d3d12.IBlob
    vs_errors, ps_errors: ^d3d12.IBlob

    shader_path := win32.utf8_to_wstring("shaders/scene.hlsl")

    hr := d3dc.CompileFromFile(
        shader_path, nil, nil,
        "VSMain", "vs_5_1",
        compile_flags, 0,
        &vs, &vs_errors,
    )
    if vs_errors != nil{
        fmt.println("VS errors:", cstring(vs_errors->GetBufferPointer()))
        vs_errors->Release()
    }
    dx_check(hr)
    defer vs->Release()

    hr = d3dc.CompileFromFile(
        shader_path, nil, nil,
        "PSMain", "ps_5_1",
        compile_flags, 0,
        &ps, &ps_errors,
    )
    if ps_errors != nil{
        fmt.println("PS errors:", cstring(ps_errors->GetBufferPointer()))
        ps_errors->Release()
    }
    dx_check(hr)
    defer ps->Release()

    // SHADOW 
    shadow_vs, shadow_errors: ^d3d12.IBlob

    hr = d3dc.CompileFromFile(
        shader_path, nil, nil,
        "VSShadow", "vs_5_1",
        compile_flags, 0,
        &shadow_vs, &shadow_errors,
    )
    if shadow_errors != nil {
        fmt.println("Shadow VS errors:", cstring(shadow_errors->GetBufferPointer()))
        shadow_errors->Release()
    }
    dx_check(hr)
    defer shadow_vs->Release()

    // POST PROCESS
    post_shader_path := win32.utf8_to_wstring("shaders/post_process.hlsl")

    post_vs, post_ps: ^d3d12.IBlob
    post_vs_errors, post_ps_errors: ^d3d12.IBlob

    hr = d3dc.CompileFromFile(
        post_shader_path, nil, nil,
        "VSMain", "vs_5_1",
        compile_flags, 0,
        &post_vs, &post_vs_errors,
    )
    if post_vs_errors != nil {
        fmt.println("Post VS compiler messages:",
            cstring(post_vs_errors->GetBufferPointer()))
        post_vs_errors->Release()
    }
    dx_check(hr)
    defer post_vs->Release()

    hr = d3dc.CompileFromFile(
        post_shader_path, nil, nil,
        "PSMain", "ps_5_1",
        compile_flags, 0,
        &post_ps, &post_ps_errors,
    )
    if post_ps_errors != nil {
        fmt.println("Post PS compiler messages:",
            cstring(post_ps_errors->GetBufferPointer()))
        post_ps_errors->Release()
    }
    dx_check(hr)
    defer post_ps->Release()

    sky_shader_path := win32.utf8_to_wstring("shaders/sky.hlsl")

    sky_ps, sky_errors: ^d3d12.IBlob
    hr = d3dc.CompileFromFile(
        sky_shader_path, nil, nil,
        "PSMain", "ps_5_1",
        compile_flags, 0,
        &sky_ps, &sky_errors,
    )
    if sky_errors != nil {
        fmt.println("Sky PS compiler messages:",
            cstring(sky_errors->GetBufferPointer()))
        sky_errors->Release()
    }
    dx_check(hr)
    defer sky_ps->Release()

    irradiance_path := win32.utf8_to_wstring("shaders/irradiance.hlsl")
    irradiance_ps, irradiance_errors: ^d3d12.IBlob

    hr = d3dc.CompileFromFile(
        irradiance_path, nil, nil,
        "PSMain", "ps_5_1",
        compile_flags, 0,
        &irradiance_ps, &irradiance_errors,
    )
    if irradiance_errors != nil {
        fmt.println("Irradiance PS compiler messages:",
            cstring(irradiance_errors->GetBufferPointer()))
        irradiance_errors->Release()
    }
    dx_check(hr)
    defer irradiance_ps->Release()

    prefilter_path := win32.utf8_to_wstring("shaders/environment_prefilter.hlsl")
    prefilter_ps, prefilter_errors: ^d3d12.IBlob

    hr = d3dc.CompileFromFile(
        prefilter_path, nil, nil,
        "PSMain", "ps_5_1",
        compile_flags, 0,
        &prefilter_ps, &prefilter_errors,
    )
    if prefilter_errors != nil {
        fmt.println("Prefilter PS compiler messages:",
            cstring(prefilter_errors->GetBufferPointer()))
        prefilter_errors->Release()
    }
    dx_check(hr)
    defer prefilter_ps->Release()

    // BLOOM
    bloom_entries := [3]cstring{
        "PSExtract",
        "PSBlurHorizontal",
        "PSBlurVertical",
    }
    bloom_ps: [3]^d3d12.IBlob

    for i in 0..<len(bloom_entries) {
        bloom_errors: ^d3d12.IBlob

        hr = d3dc.CompileFromFile(
            post_shader_path, nil, nil,
            bloom_entries[i], "ps_5_1",
            compile_flags, 0,
            &bloom_ps[i], &bloom_errors,
        )
        if bloom_errors != nil {
            fmt.println("Bloom shader compiler messages:",
                cstring(bloom_errors->GetBufferPointer()))
            bloom_errors->Release()
        }
        dx_check(hr)
    }

    defer {
        for shader in bloom_ps {
            shader->Release()
        }
    }

    // INPUT LAYOUT
    input_layout := []d3d12.INPUT_ELEMENT_DESC {
        {
            SemanticName         = "POSITION",
            SemanticIndex        = 0,
            Format               = .R32G32B32_FLOAT,
            InputSlot            = 0,
            AlignedByteOffset    = 0,
            InputSlotClass       = .PER_VERTEX_DATA,
            InstanceDataStepRate = 0,
        },
        {
            SemanticName      = "NORMAL",
            Format            = .R32G32B32_FLOAT,
            AlignedByteOffset = 12, 
            InputSlotClass    = .PER_VERTEX_DATA,
        },
        {
            SemanticName         = "TEXCOORD",
            SemanticIndex        = 0,
            Format               = .R32G32_FLOAT,
            InputSlot            = 0,
            AlignedByteOffset    = 24,
            InputSlotClass       = .PER_VERTEX_DATA,
            InstanceDataStepRate = 0,
        },
        {
            SemanticName = "TANGENT",
            SemanticIndex = 0,
            Format = .R32G32B32A32_FLOAT,
            InputSlot = 0,
            AlignedByteOffset = 32,
            InputSlotClass = .PER_VERTEX_DATA,
            InstanceDataStepRate = 0,
        },
    }

    // PSO
    pso_desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC{
        pRootSignature = r.root_signature,
        VS = { pShaderBytecode= vs->GetBufferPointer(), BytecodeLength = vs->GetBufferSize() },
        PS = { pShaderBytecode= ps->GetBufferPointer(), BytecodeLength = ps->GetBufferSize() },
        InputLayout = {
            pInputElementDescs = raw_data(input_layout),
            NumElements = u32(len(input_layout)),
        },
        RasterizerState = {
            FillMode              = .SOLID,
            CullMode              = .BACK,
            FrontCounterClockwise = false,
            DepthBias             = 0,
            DepthBiasClamp        = 0,
            SlopeScaledDepthBias  = 0,
            DepthClipEnable       = true,
            MultisampleEnable     = false,
            AntialiasedLineEnable = false,
            ForcedSampleCount     = 0,
            ConservativeRaster    = .OFF,
        },
        BlendState = {
            RenderTarget = { 0 = {
            BlendEnable           = false,
            LogicOpEnable         = false,
            SrcBlend              = .ONE,
            DestBlend             = .ZERO,
            BlendOp               = .ADD,
            SrcBlendAlpha         = .ONE,
            DestBlendAlpha        = .ZERO,
            BlendOpAlpha          = .ADD,
            LogicOp               = .NOOP,
            RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
        }},
        },
        DepthStencilState = {
            DepthEnable = true,
            DepthWriteMask = .ALL,
            DepthFunc = .LESS,
            StencilEnable = false,
        },
        DSVFormat = .D32_FLOAT,
        SampleMask = max(u32),
        PrimitiveTopologyType = .TRIANGLE,
        NumRenderTargets = 1,
        SampleDesc = { Count = 1 },
    }
    pso_desc.RTVFormats[0] = .R8G8B8A8_UNORM

    shadow_pso_desc := pso_desc
    shadow_pso_desc.VS = {
        pShaderBytecode = shadow_vs->GetBufferPointer(),
        BytecodeLength = shadow_vs->GetBufferSize(),
    }
    shadow_pso_desc.PS = {}
    shadow_pso_desc.NumRenderTargets = 0
    shadow_pso_desc.RTVFormats[0] = .UNKNOWN
    shadow_pso_desc.RasterizerState.DepthBias = 100
    shadow_pso_desc.RasterizerState.SlopeScaledDepthBias = 1.0

    dx_check(r.device->CreateGraphicsPipelineState(
        &shadow_pso_desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.shadow_pipeline_state),
    ))

    // Same scene shaders and depth test, but a floating-point color target.
    hdr_pso_desc := pso_desc
    hdr_pso_desc.RTVFormats[0] = .R16G16B16A16_FLOAT

    dx_check(r.device->CreateGraphicsPipelineState(
        &hdr_pso_desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.hdr_pipeline_state),
    ))

    // Full-screen triangle: no input layout or depth test.
    post_pso_desc := pso_desc
    post_pso_desc.VS = {
        pShaderBytecode = post_vs->GetBufferPointer(),
        BytecodeLength = post_vs->GetBufferSize(),
    }
    post_pso_desc.PS = {
        pShaderBytecode = post_ps->GetBufferPointer(),
        BytecodeLength = post_ps->GetBufferSize(),
    }
    post_pso_desc.InputLayout = {}
    post_pso_desc.DepthStencilState.DepthEnable = false
    post_pso_desc.DepthStencilState.DepthWriteMask = .ZERO
    post_pso_desc.DSVFormat = .UNKNOWN
    post_pso_desc.RasterizerState.CullMode = .NONE

    dx_check(r.device->CreateGraphicsPipelineState(
        &post_pso_desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.post_pipeline_state),
    ))

    sky_pso_desc := post_pso_desc
    sky_pso_desc.PS = {
        pShaderBytecode = sky_ps->GetBufferPointer(),
        BytecodeLength = sky_ps->GetBufferSize(),
    }
    sky_pso_desc.RTVFormats[0] = .R16G16B16A16_FLOAT

    dx_check(r.device->CreateGraphicsPipelineState(
        &sky_pso_desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.sky_pipeline_state),
    ))

    irradiance_pso_desc := post_pso_desc
    irradiance_pso_desc.PS = {
        pShaderBytecode = irradiance_ps->GetBufferPointer(),
        BytecodeLength = irradiance_ps->GetBufferSize(),
    }
    irradiance_pso_desc.RTVFormats[0] = .R16G16B16A16_FLOAT

    dx_check(r.device->CreateGraphicsPipelineState(
        &irradiance_pso_desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.irradiance_pipeline_state),
    ))

    prefilter_pso_desc := post_pso_desc
    prefilter_pso_desc.PS = {
        pShaderBytecode = prefilter_ps->GetBufferPointer(),
        BytecodeLength = prefilter_ps->GetBufferSize(),
    }
    prefilter_pso_desc.RTVFormats[0] = .R16G16B16A16_FLOAT

    dx_check(r.device->CreateGraphicsPipelineState(
        &prefilter_pso_desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.prefilter_pipeline_state),
    ))

    for i in 0..<len(bloom_ps) {
        bloom_pso_desc := post_pso_desc
        bloom_pso_desc.PS = {
            pShaderBytecode = bloom_ps[i]->GetBufferPointer(),
            BytecodeLength = bloom_ps[i]->GetBufferSize(),
        }
        bloom_pso_desc.RTVFormats[0] = .R16G16B16A16_FLOAT

        dx_check(r.device->CreateGraphicsPipelineState(
            &bloom_pso_desc,
            d3d12.IPipelineState_UUID,
            (^rawptr)(&r.bloom_pipeline_states[i]),
        ))
    }

    mesh_paths := [MESH_COUNT]string{
        "models/cube.obj",
        "models/pyramid.obj",
    }

    for i in 0..<MESH_COUNT {
        mesh, ok := mesh_load_obj(mesh_paths[i])
        if !ok {
            fmt.panicf("Failed to load mesh: %s", mesh_paths[i])
        }

        renderer_upload_mesh(&r.meshes[i], mesh)
    }

    // CONSTANT BUFFER
    cb_size := u64(size_of(SceneConstants)) * u64(MAX_ENTITIES)

    cb_heap_props := d3d12.HEAP_PROPERTIES{ Type = .UPLOAD }
    cb_desc := d3d12.RESOURCE_DESC{
        Dimension           = .BUFFER,
        Width               = cb_size,
        Height              = 1,
        DepthOrArraySize    = 1,
        MipLevels           = 1,
        SampleDesc          = { Count = 1},
        Layout              = .ROW_MAJOR,
    }

    dx_check(r.device->CreateCommittedResource(
        &cb_heap_props,
        {},
        &cb_desc,
        { .VERTEX_AND_CONSTANT_BUFFER },
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.constant_buffer),
    ))

    read_range := d3d12.RANGE {Begin = 0, End = 0}
    dx_check(r.constant_buffer->Map(0, &read_range, (^rawptr)(&r.cb_mapped_data)))

    post_cb_desc := cb_desc
    post_cb_desc.Width = u64(size_of(PostConstants))

    dx_check(r.device->CreateCommittedResource(
        &cb_heap_props,
        {},
        &post_cb_desc,
        {.VERTEX_AND_CONSTANT_BUFFER},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.post_constant_buffer),
    ))

    dx_check(r.post_constant_buffer->Map(
        0,
        &read_range,
        (^rawptr)(&r.post_cb_mapped_data),
    ))

    sky_cb_desc := post_cb_desc
    sky_cb_desc.Width = u64(size_of(SkyConstants))

    dx_check(r.device->CreateCommittedResource(
        &cb_heap_props,
        {},
        &sky_cb_desc,
        {.VERTEX_AND_CONSTANT_BUFFER},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.sky_constant_buffer),
    ))

    dx_check(r.sky_constant_buffer->Map(
        0,
        &read_range,
        (^rawptr)(&r.sky_cb_mapped_data),
    ))

    // ── 6. Viewport & Scissor ─────────────────────────────────────────────────
    r.viewport = d3d12.VIEWPORT {
        Width    = WINDOW_WIDTH,
        Height   = WINDOW_HEIGHT,
        MinDepth = 0,
        MaxDepth = 1,
    }
    r.scissor_rect = d3d12.RECT {
        right  = WINDOW_WIDTH,
        bottom = WINDOW_HEIGHT,
    }
}

renderer_upload_mesh :: proc(gpu: ^GpuMesh, mesh: MeshData) {
    r := &g_renderer

    vb_size := u64(len(mesh.vertices) * size_of(Vertex))

    heap_props := d3d12.HEAP_PROPERTIES{Type = .UPLOAD}
    vb_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = vb_size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &vb_desc,
        {.VERTEX_AND_CONSTANT_BUFFER, .INDEX_BUFFER},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&gpu.vertex_buffer),
    ))

    mapped: rawptr
    write_range := d3d12.RANGE{Begin = 0, End = 0}
    dx_check(gpu.vertex_buffer->Map(0, &write_range, &mapped))
    runtime.mem_copy(mapped, raw_data(mesh.vertices), int(vb_size))
    gpu.vertex_buffer->Unmap(0, nil)

    gpu.vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW{
        BufferLocation = gpu.vertex_buffer->GetGPUVirtualAddress(),
        StrideInBytes = size_of(Vertex),
        SizeInBytes = u32(vb_size),
    }

    ib_size := u64(len(mesh.indices) * size_of(u32))
    ib_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = ib_size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &ib_desc,
        {.VERTEX_AND_CONSTANT_BUFFER},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&gpu.index_buffer),
    ))

    dx_check(gpu.index_buffer->Map(0, &write_range, &mapped))
    runtime.mem_copy(mapped, raw_data(mesh.indices), int(ib_size))
    gpu.index_buffer->Unmap(0, nil)

    gpu.index_buffer_view = d3d12.INDEX_BUFFER_VIEW{
        BufferLocation = gpu.index_buffer->GetGPUVirtualAddress(),
        Format = .R32_UINT,
        SizeInBytes = u32(ib_size),
    }

    gpu.index_count = u32(len(mesh.indices))
}

renderer_create_depth_buffer :: proc(){
    r := &g_renderer

    if r.dsv_heap == nil {
        dsv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
            NumDescriptors = 1,
            Type = .DSV,
            Flags = {},
        }
        dx_check(r.device->CreateDescriptorHeap(
            &dsv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.dsv_heap),
        ))
    }

    depth_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.width),
        Height = r.height,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = .D32_FLOAT,
        SampleDesc = { Count = 1 },
        Flags = {.ALLOW_DEPTH_STENCIL},
    }

    clear_value := d3d12.CLEAR_VALUE{
        Format = .D32_FLOAT,
    }
    clear_value.DepthStencil = {Depth = 1.0, Stencil = 0}

    heap_props := d3d12.HEAP_PROPERTIES { Type = .DEFAULT }

    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &depth_desc,
        { .DEPTH_WRITE },
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.depth_buffer),
    ))

    dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC{
        Format = .D32_FLOAT,
        ViewDimension = .TEXTURE2D,
        Flags = {},
    }
    dsv_handle : d3d12.CPU_DESCRIPTOR_HANDLE
    r.dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)

    r.device->CreateDepthStencilView(
        r.depth_buffer,
        &dsv_desc,
        dsv_handle,
    )

}

renderer_resize:: proc(width, height: u32){
    r := &g_renderer

    if width == 0 || height == 0 || (width == r.width && height == r.height){
        return
    }

    renderer_wait_for_gpu()

    r.hdr_texture->Release()
    for target in r.bloom_targets {
        target->Release()
    }

    for i in 0..<FRAME_COUNT{
        r.render_targets[i]->Release()
    }
    r.depth_buffer->Release()

    dx_check(r.swap_chain->ResizeBuffers(
        FRAME_COUNT,
        width,
        height,
        .R8G8B8A8_UNORM,
        {},
    ))

    r.width = width
    r.height = height
    r.frame_index = r.swap_chain->GetCurrentBackBufferIndex()

    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

    for i in 0..<FRAME_COUNT{
        dx_check(r.swap_chain->GetBuffer(
            u32(i),
            d3d12.IResource_UUID,
            (^rawptr)(&r.render_targets[i]),
        ))
        r.device->CreateRenderTargetView(r.render_targets[i], nil, rtv_handle)
        rtv_handle.ptr += uint(r.rtv_descriptor_size)
    }

    renderer_create_depth_buffer()

    r.viewport.Width = f32(width)
    r.viewport.Height = f32(height)
    r.scissor_rect.right = i32(width)
    r.scissor_rect.bottom = i32(height)

    renderer_create_hdr_target()
    renderer_create_bloom_targets()
}

renderer_load_textures :: proc(){
    r := &g_renderer

    srv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = TEXTURE_COUNT + 7,
        Type = .CBV_SRV_UAV,
        Flags = {.SHADER_VISIBLE},
    }

    dx_check(r.device->CreateDescriptorHeap(
        &srv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.srv_heap),
    ))

    r.srv_descriptor_size = r.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV)

    renderer_load_texture(int(Texture_Asset.Portrait))
    renderer_load_texture(int(Texture_Asset.Checkerboard))
    renderer_load_texture(int(Texture_Asset.Stone_Albedo))
    renderer_load_texture(int(Texture_Asset.Stone_Normal))
    renderer_load_texture(int(Texture_Asset.Stone_Roughness))
}

renderer_load_texture :: proc(index: int){
    r := &g_renderer

    // LOADING PNG
    path := "textures/2.png"

    #partial switch Texture_Asset(index) {
        case .Stone_Albedo:
            path = "textures/stone/albedo.png"
        case .Stone_Normal:
            path = "textures/stone/normal.png"
        case .Stone_Roughness:
            path = "textures/stone/roughness.png"
    }

    is_normal_map := index == int(Texture_Asset.Stone_Normal)
    is_roughness_map := index == int(Texture_Asset.Stone_Roughness)

    img, err := image.load_from_file(path)

    if err != nil{
        fmt.panicf("Failed to load texture: %v", err)
    }
    defer image.destroy(img)

    if img.channels == 3{
        ok := image.alpha_add_if_missing(img)
        if !ok{
            panic("Failed to add alpha channel")
        }
    }

    width := u64(img.width)
    height := u64(img.height)
    pixels := img.pixels.buf[:]

    if img.depth == 16 {
        source16 := ([^]u16)(raw_data(pixels))
        converted := make(
            []u8,
            int(width * height * 4),
            context.temp_allocator,
        )

        for i in 0..<len(converted) {
            converted[i] = u8((u32(source16[i]) + 128) / 257)
        }

        pixels = converted
    }

    if index == int(Texture_Asset.Checkerboard) {
        for y in 0..<int(img.height) {
            for x in 0..<int(img.width) {
                pixel := (y * int(img.width) + x) * 4
                light_square := ((x / 32 + y / 32) % 2) == 0

                if light_square {
                    pixels[pixel + 0] = 240
                    pixels[pixel + 1] = 240
                    pixels[pixel + 2] = 240
                } else {
                    pixels[pixel + 0] = 35
                    pixels[pixel + 1] = 55
                    pixels[pixel + 2] = 100
                }
                pixels[pixel + 3] = 255
            }
        }
    }

    mips := make([dynamic][]u8, context.temp_allocator)
    append(&mips, pixels) // Level 0 belongs to img; do not free it here.

    mip_width := u32(width)
    mip_height := u32(height)

    for mip_width > 1 || mip_height > 1 {
        next, next_width, next_height := texture_next_mip(
            mips[len(mips) - 1],
            mip_width,
            mip_height,
            context.temp_allocator,
            normal_map = is_normal_map,
            linear_data = is_roughness_map,
        )
        append(&mips, next)

        mip_width = next_width
        mip_height = next_height
    }

    tex_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = width,
        Height = u32(height),
        DepthOrArraySize = 1,
        MipLevels = u16(len(mips)),
        Format = .R8G8B8A8_UNORM,
        SampleDesc = {Count = 1},
        Flags = {},
    }

    default_heap := d3d12.HEAP_PROPERTIES{ Type = .DEFAULT }
    dx_check(r.device->CreateCommittedResource(
        &default_heap,
        {},
        &tex_desc,
        { .COPY_DEST },
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.textures[index]),
    ))

    // UPLOAD BUFFER
    layouts := make(
        []d3d12.PLACED_SUBRESOURCE_FOOTPRINT,
        len(mips),
        context.temp_allocator,
    )
    row_counts := make([]u32, len(mips), context.temp_allocator)
    row_sizes := make([]u64, len(mips), context.temp_allocator)

    upload_size: u64
    r.device->GetCopyableFootprints(
        &tex_desc,
        0,
        u32(len(mips)),
        0,
        raw_data(layouts),
        raw_data(row_counts),
        raw_data(row_sizes),
        &upload_size,
    )

    upload_heap := d3d12.HEAP_PROPERTIES { Type = .UPLOAD }
    upload_desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = upload_size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = { Count = 1},
        Layout = .ROW_MAJOR,
    }

    upload_buffer: ^d3d12.IResource
    dx_check(r.device->CreateCommittedResource(
        &upload_heap,
        {},
        &upload_desc,
        { .VERTEX_AND_CONSTANT_BUFFER },
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&upload_buffer),
    ))
    defer upload_buffer->Release()

    mapped: rawptr
    dx_check(upload_buffer->Map(0, nil, &mapped))
    for mip in 0..<len(mips) {
        layout := layouts[mip]
        source_address := uintptr(raw_data(mips[mip]))

        for y in 0..<int(row_counts[mip]) {
            destination_row := uintptr(mapped) +
                uintptr(layout.Offset) +
                uintptr(u64(y) * u64(layout.Footprint.RowPitch))

            source_row := source_address +
                uintptr(u64(y) * row_sizes[mip])

            runtime.mem_copy(
                rawptr(destination_row),
                rawptr(source_row),
                int(row_sizes[mip]),
            )
        }
    }
    upload_buffer->Unmap(0, nil)

    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))

    for mip in 0..<len(mips) {
        src_location := d3d12.TEXTURE_COPY_LOCATION{
            pResource = upload_buffer,
            Type = .PLACED_FOOTPRINT,
        }
        src_location.PlacedFootprint = layouts[mip]

        dst_location := d3d12.TEXTURE_COPY_LOCATION{
            pResource = r.textures[index],
            Type = .SUBRESOURCE_INDEX,
            SubresourceIndex = u32(mip),
        }

        r.command_list->CopyTextureRegion(
            &dst_location, 0, 0, 0, &src_location, nil,
        )
    }

    // Transition: COPY_DEST → SHADER_RESOURCE
    copy_barrier := d3d12.RESOURCE_BARRIER { Type = .TRANSITION }
    copy_barrier.Transition = {
        pResource   = r.textures[index],
        StateBefore = { .COPY_DEST },
        StateAfter  = { .PIXEL_SHADER_RESOURCE },
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }

    r.command_list->ResourceBarrier(1, &copy_barrier)
    dx_check(r.command_list->Close())

    lists := []^d3d12.ICommandList{ r.command_list }
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))

    renderer_wait_for_gpu()

    // ── SRV ───────────────────────────────────────────────────────────────────
    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
        Format                  = .R8G8B8A8_UNORM,
        ViewDimension           = .TEXTURE2D,
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }
    srv_desc.Texture2D = { MipLevels = u32(len(mips)) }

    srv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv_handle)
    srv_handle.ptr += uint(index) * uint(r.srv_descriptor_size)

    r.device->CreateShaderResourceView(r.textures[index], &srv_desc, srv_handle)

}

renderer_render_frame :: proc(scene: ^Scene){
    r := &g_renderer

    allocator := r.command_allocators[r.frame_index]
    dx_check(allocator->Reset())
    dx_check(r.command_list->Reset(allocator, nil))

    frame := renderer_prepare_frame(scene)

    renderer_render_shadow_pass(frame.draw_meshes[:frame.draw_count])

    renderer_render_scene_pass(
        frame.draw_meshes[:frame.draw_count],
        frame.draw_textures[:frame.draw_count],
        frame.draw_normals[:frame.draw_count],
        frame.draw_roughness[:frame.draw_count],
    )

    renderer_render_bloom()

    renderer_render_post_process()

    r.command_list->ResolveQueryData(
        r.timestamp_heap,
        .TIMESTAMP,
        0,
        GPU_TIMESTAMP_COUNT,
        r.timestamp_readback,
        0,
    )

    dx_check(r.command_list->Close())

    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))

    dx_check(r.swap_chain->Present(1, {}))

    renderer_wait_for_gpu()

    renderer_read_gpu_timings()
}

renderer_begin_gpu_pass :: proc(pass: GPU_Pass) {
    r := &g_renderer
    r.command_list->EndQuery(
        r.timestamp_heap, .TIMESTAMP, u32(pass) * 2,
    )
}

renderer_end_gpu_pass :: proc(pass: GPU_Pass) {
    r := &g_renderer
    r.command_list->EndQuery(
        r.timestamp_heap, .TIMESTAMP, u32(pass) * 2 + 1,
    )
}

renderer_read_gpu_timings :: proc() {
    r := &g_renderer

    read_range := d3d12.RANGE{
        Begin = 0,
        End = GPU_TIMESTAMP_COUNT * size_of(u64),
    }
    mapped: rawptr
    dx_check(r.timestamp_readback->Map(0, &read_range, &mapped))

    ticks := ([^]u64)(mapped)
    for i in 0..<GPU_PASS_COUNT {
        start_tick := ticks[i * 2]
        end_tick := ticks[i * 2 + 1]

        r.gpu_pass_ms[i] = f32(
            f64(end_tick - start_tick) * 1000.0 /
            f64(r.timestamp_frequency)
        )
    }

    written_range := d3d12.RANGE{Begin = 0, End = 0}
    r.timestamp_readback->Unmap(0, &written_range)
}

renderer_wait_for_gpu :: proc(){
    r:= &g_renderer

    r.fence_value += 1
    dx_check(r.command_queue->Signal(r.fence, r.fence_value))

    if r.fence ->GetCompletedValue() < r.fence_value{
        dx_check(r.fence->SetEventOnCompletion(r.fence_value, r.fence_event))
        win32.WaitForSingleObject(r.fence_event, win32.INFINITE)
    }

    r.frame_index = r.swap_chain->GetCurrentBackBufferIndex()
}

renderer_destroy :: proc(){
    r:= &g_renderer
    renderer_wait_for_gpu()
    debug_ui_destroy()

    win32.CloseHandle(r.fence_event)
    r.fence->Release()
    r.command_list->Release()
    for i in 0..<FRAME_COUNT{
        r.command_allocators[i]->Release()
        r.render_targets[i]->Release()
    }
    r.rtv_heap->Release()
    r.swap_chain->Release()
    r.command_queue->Release()

    r.root_signature->Release()

    r.constant_buffer->Release()

    r.depth_buffer->Release()
    r.dsv_heap->Release()

    for mesh in r.meshes {
        mesh.vertex_buffer->Release()
        mesh.index_buffer->Release()
    }

    for texture in r.textures{
        texture->Release()
    }
    r.srv_heap->Release()

    r.shadow_pipeline_state->Release()
    r.shadow_map->Release()
    r.shadow_dsv_heap->Release()

    r.hdr_texture->Release()
    r.hdr_rtv_heap->Release()
    r.hdr_pipeline_state->Release()
    r.post_pipeline_state->Release()

    for target in r.bloom_targets {
        target->Release()
    }
    r.bloom_rtv_heap->Release()

    for pso in r.bloom_pipeline_states {
        pso->Release()
    }

    r.post_constant_buffer->Release()

    r.timestamp_readback->Release()
    r.timestamp_heap->Release()

    r.environment_texture->Release()
    r.sky_pipeline_state->Release()
    r.sky_constant_buffer->Release()

    r.irradiance_texture->Release()
    r.irradiance_rtv_heap->Release()
    r.irradiance_pipeline_state->Release()

    r.prefilter_texture->Release()
    r.prefilter_rtv_heap->Release()
    r.prefilter_pipeline_state->Release()
    r.prefilter_constant_buffer->Release()

    r.device->Release()
}

perspective_lh :: proc(fovy, aspect, near, far: f32) -> alg.Matrix4f32 {
    tan_half_fov := math.tan(fovy * 0.5)

    return {
        1 / (aspect * tan_half_fov), 0,                0,                          0,
        0,                           1 / tan_half_fov, 0,                          0,
        0,                           0,                far / (far - near),          1,
        0,                           0,                -(near * far) / (far - near), 0,
    }
}

look_at_lh :: proc(eye, centre, up: alg.Vector3f32) -> alg.Matrix4f32 {
    f := alg.normalize(centre - eye)
    r := alg.normalize(alg.cross(up, f))
    u := alg.cross(f, r)

    return {
        r.x, u.x, f.x, 0,
        r.y, u.y, f.y, 0,
        r.z, u.z, f.z, 0,
        -alg.dot(r, eye), -alg.dot(u, eye), -alg.dot(f, eye), 1,
    }
}

orthographic_lh :: proc(left, right, bottom, top, near, far: f32) -> alg.Matrix4f32 {
    return {
        2 / (right - left), 0, 0, 0,
        0, 2 / (top - bottom), 0, 0,
        0, 0, 1 / (far - near), 0,
        -(right + left) / (right - left),
        -(top + bottom) / (top - bottom),
        -near / (far - near),
        1,
    }
}
