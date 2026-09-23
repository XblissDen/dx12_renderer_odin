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

Vertex :: struct {
    position:   [3]f32,
    normal:     [3]f32,
    texcoord:   [2]f32,
}

SceneConstants :: struct #align(256){
    model:          alg.Matrix4f32,
    view:           alg.Matrix4f32,
    projection:     alg.Matrix4f32,

    light_position: [3]f32,
    _pad0:          f32,
    view_position:  [3]f32,
    _pad1:          f32,
    light_color:    [3]f32,
    _pad2:          f32,
    material_tint: [3]f32,
    _pad3: f32,
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
    pipeline_state: ^d3d12.IPipelineState,

    vertex_buffer: ^d3d12.IResource,
    vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW,

    viewport: d3d12.VIEWPORT,
    scissor_rect: d3d12.RECT,

    constant_buffer: ^d3d12.IResource,
    cb_mapped_data: [^]SceneConstants,

    depth_buffer: ^d3d12.IResource,
    dsv_heap: ^d3d12.IDescriptorHeap,

    index_buffer: ^d3d12.IResource,
    index_buffer_view: d3d12.INDEX_BUFFER_VIEW,
    index_count: u32,

    texture: ^d3d12.IResource,
    srv_heap: ^d3d12.IDescriptorHeap,

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

    static_sampler := d3d12.STATIC_SAMPLER_DESC{
        Filter = .MIN_MAG_MIP_LINEAR,
        AddressU = .WRAP,
        AddressV = .WRAP,
        AddressW = .WRAP,
        ShaderRegister = 0,
        ShaderVisibility = .PIXEL,
    }

    params := []d3d12.ROOT_PARAMETER{cbv_param, srv_param}

    rs_desc := d3d12.ROOT_SIGNATURE_DESC{
        NumParameters = u32(len(params)),
        pParameters = raw_data(params),
        NumStaticSamplers = 1,
        pStaticSamplers = &static_sampler,
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

    shader_path := win32.utf8_to_wstring("shaders/triangle.hlsl")

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

    dx_check(r.device->CreateGraphicsPipelineState(
        &pso_desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.pipeline_state),
    ))

    // Geometry
    /*vertices := []Vertex {
        // Front (normal: 0, 0, -1)
        { position = {-0.5,  0.5, -0.5}, normal = {0, 0, -1}, texcoord = {0, 0} },
        { position = { 0.5,  0.5, -0.5}, normal = {0, 0, -1}, texcoord = {1, 0} },
        { position = { 0.5, -0.5, -0.5}, normal = {0, 0, -1}, texcoord = {1, 1} },
        { position = {-0.5, -0.5, -0.5}, normal = {0, 0, -1}, texcoord = {0, 1} },
        // Back (normal: 0, 0, 1)
        { position = { 0.5,  0.5,  0.5}, normal = {0, 0, 1}, texcoord = {0, 0} },
        { position = {-0.5,  0.5,  0.5}, normal = {0, 0, 1}, texcoord = {1, 0} },
        { position = {-0.5, -0.5,  0.5}, normal = {0, 0, 1}, texcoord = {1, 1} },
        { position = { 0.5, -0.5,  0.5}, normal = {0, 0, 1}, texcoord = {0, 1} },
        // Left (normal: -1, 0, 0)
        { position = {-0.5,  0.5,  0.5}, normal = {-1, 0, 0}, texcoord = {0, 0} },
        { position = {-0.5,  0.5, -0.5}, normal = {-1, 0, 0}, texcoord = {1, 0} },
        { position = {-0.5, -0.5, -0.5}, normal = {-1, 0, 0}, texcoord = {1, 1} },
        { position = {-0.5, -0.5,  0.5}, normal = {-1, 0, 0}, texcoord = {0, 1} },
        // Right (normal: 1, 0, 0)
        { position = { 0.5,  0.5, -0.5}, normal = {1, 0, 0}, texcoord = {0, 0} },
        { position = { 0.5,  0.5,  0.5}, normal = {1, 0, 0}, texcoord = {1, 0} },
        { position = { 0.5, -0.5,  0.5}, normal = {1, 0, 0}, texcoord = {1, 1} },
        { position = { 0.5, -0.5, -0.5}, normal = {1, 0, 0}, texcoord = {0, 1} },
        // Top (normal: 0, 1, 0)
        { position = {-0.5,  0.5,  0.5}, normal = {0, 1, 0}, texcoord = {0, 0} },
        { position = { 0.5,  0.5,  0.5}, normal = {0, 1, 0}, texcoord = {1, 0} },
        { position = { 0.5,  0.5, -0.5}, normal = {0, 1, 0}, texcoord = {1, 1} },
        { position = {-0.5,  0.5, -0.5}, normal = {0, 1, 0}, texcoord = {0, 1} },
        // Bottom (normal: 0, -1, 0)
        { position = {-0.5, -0.5, -0.5}, normal = {0, -1, 0}, texcoord = {0, 0} },
        { position = { 0.5, -0.5, -0.5}, normal = {0, -1, 0}, texcoord = {1, 0} },
        { position = { 0.5, -0.5,  0.5}, normal = {0, -1, 0}, texcoord = {1, 1} },
        { position = {-0.5, -0.5,  0.5}, normal = {0, -1, 0}, texcoord = {0, 1} },
    }

    indices := []u32 {
        0,  1,  2,   0,  2,  3, // front
        4,  5,  6,   4,  6,  7, // back
        8,  9, 10,   8, 10, 11, // left
        12, 13, 14,  12, 14, 15, // right
        16, 17, 18,  16, 18, 19, // top
        20, 21, 22,  20, 22, 23, // bottom
    }*/

    mesh, mesh_ok := mesh_load_obj("models/cube.obj")
    if !mesh_ok{
        panic("Failed to load mesh")
    }

    vertices := mesh.vertices
    indices := mesh.indices
    r.index_count = u32(len(indices))

    vb_size := u64(len(vertices) * size_of(Vertex))

    heap_props := d3d12.HEAP_PROPERTIES { Type = .UPLOAD}
    buf_desc := d3d12.RESOURCE_DESC{
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
        &buf_desc,
        { .VERTEX_AND_CONSTANT_BUFFER, .INDEX_BUFFER },
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.vertex_buffer),
    ))

    mapped: rawptr
    read_range := d3d12.RANGE {Begin = 0, End = 0}
    dx_check(r.vertex_buffer->Map(0, &read_range, &mapped))
    runtime.mem_copy(mapped, raw_data(vertices), int(vb_size))
    r.vertex_buffer->Unmap(0, nil)

    r.vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW {
        BufferLocation = r.vertex_buffer->GetGPUVirtualAddress(),
        StrideInBytes  = size_of(Vertex),
        SizeInBytes    = u32(vb_size),
    }

    // INDEX BUFFER
    ib_size := u64(len(indices) * size_of(u32))

    ib_heap_props := d3d12.HEAP_PROPERTIES { Type = .UPLOAD }
    ib_desc := d3d12.RESOURCE_DESC {
        Dimension        = .BUFFER,
        Width            = ib_size,
        Height           = 1,
        DepthOrArraySize = 1,
        MipLevels        = 1,
        SampleDesc       = { Count = 1 },
        Layout           = .ROW_MAJOR,
    }

    dx_check(r.device->CreateCommittedResource(
        &ib_heap_props,
        {},
        &ib_desc,
        { .VERTEX_AND_CONSTANT_BUFFER },
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&r.index_buffer),
    ))

    ib_mapped: rawptr
    dx_check(r.index_buffer->Map(0, nil, &ib_mapped))
    runtime.mem_copy(ib_mapped, raw_data(indices), int(ib_size))
    r.index_buffer->Unmap(0, nil)

    r.index_buffer_view = d3d12.INDEX_BUFFER_VIEW {
        BufferLocation = r.index_buffer->GetGPUVirtualAddress(),
        Format         = .R32_UINT,
        SizeInBytes    = u32(ib_size),
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

    read_range = d3d12.RANGE {Begin = 0, End = 0}
    dx_check(r.constant_buffer->Map(0, &read_range, (^rawptr)(&r.cb_mapped_data)))

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
}

renderer_load_texture :: proc(){
    r := &g_renderer

    // LOADING PNG
    img, err := image.load_from_file("textures/2.png")
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

    srv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{
        NumDescriptors = 1,
        Type = .CBV_SRV_UAV,
        Flags = {.SHADER_VISIBLE}
    }

    dx_check(r.device->CreateDescriptorHeap(
        &srv_heap_desc,
        d3d12.IDescriptorHeap_UUID,
        (^rawptr)(&r.srv_heap),
    ))

    tex_desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = width,
        Height = u32(height),
        DepthOrArraySize = 1,
        MipLevels = 1,
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
        (^rawptr)(&r.texture),
    ))

    // UPLOAD BUFFER
    row_pitch := (width * 4 + 255) & ~u64(255)
    upload_size := row_pitch * height

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
    src := raw_data(pixels)
    dst := uintptr(mapped)
    for y in 0..<height {
        dst_row := dst + uintptr(y * row_pitch)
        src_row := uintptr(src) + uintptr(y * width * 4)
        runtime.mem_copy(rawptr(dst_row), rawptr(src_row), int(width * 4))
    }
    upload_buffer->Unmap(0, nil)

    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))

    src_location := d3d12.TEXTURE_COPY_LOCATION{
        pResource = upload_buffer,
        Type = .PLACED_FOOTPRINT,
    }
    src_location.PlacedFootprint = {
        Footprint = {
            Format = .R8G8B8A8_UNORM,
            Width = u32(width),
            Height = u32(height),
            Depth = 1,
            RowPitch = u32(row_pitch),
        },
    }

    dst_location := d3d12.TEXTURE_COPY_LOCATION{
        pResource = r.texture,
        Type = .SUBRESOURCE_INDEX,
        SubresourceIndex = 0,
    }

    // Transition: COPY_DEST → SHADER_RESOURCE
    copy_barrier := d3d12.RESOURCE_BARRIER { Type = .TRANSITION }
    copy_barrier.Transition = {
        pResource   = r.texture,
        StateBefore = { .COPY_DEST },
        StateAfter  = { .PIXEL_SHADER_RESOURCE },
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }

    r.command_list->CopyTextureRegion(&dst_location, 0, 0, 0, &src_location, nil)
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
    srv_desc.Texture2D = { MipLevels = 1 }

    srv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetCPUDescriptorHandleForHeapStart(&srv_handle)
    r.device->CreateShaderResourceView(r.texture, &srv_desc, srv_handle)

}

renderer_render_frame :: proc(scene: ^Scene){
    r := &g_renderer

    allocator := r.command_allocators[r.frame_index]
    dx_check(allocator->Reset())
    dx_check(r.command_list->Reset(allocator, nil))

    camera_index := -1

    for i in 0..<scene.entity_count{
        if scene.has_transform[i] && scene.has_camera[i]{
            camera_index = i
            break
        }
    }

    assert(camera_index >= 0)

    camera := &scene.cameras[camera_index]
    camera_position := scene.transforms[camera_index].position
    view := camera_view_matrix(camera, camera_position)

    proj := perspective_lh(
        alg.to_radians(f32(45)),
        f32(r.width) / f32(r.height),
        0.1,
        100.0,
    )

    light_position: alg.Vector3f32
    light_color: [3]f32
    light_found := false

    for i in 0..<scene.entity_count{
        if scene.has_transform[i] && scene.has_point_light[i]{
            light_position = scene.transforms[i].position
            light_color = scene.point_lights[i].color
            light_found = true
            break
        }
    }

    assert(light_found)

    draw_count := 0

    for i in 0..<scene.entity_count{
        if !scene.has_transform[i] || !scene.has_mesh_renderer[i] || !scene.has_material[i]{
            continue
        }

        transform := scene.transforms[i]
        rotation := alg.matrix4_rotate_f32(transform.rotation, {0, 1, 0})

        r.cb_mapped_data[draw_count] = SceneConstants{
            model = alg.transpose(alg.matrix4_translate_f32(transform.position) * rotation),
            view = view,
            projection = proj,
            light_position = light_position,
            view_position = camera_position,
            light_color = light_color,
            material_tint = scene.materials[i].tint,
        }

        draw_count += 1
    }

    //r.cb_mapped_data.model      = alg.MATRIX4F32_IDENTITY
    //r.cb_mapped_data.view       = alg.MATRIX4F32_IDENTITY
    //r.cb_mapped_data.projection = alg.MATRIX4F32_IDENTITY

    barrier := d3d12.RESOURCE_BARRIER{
        Type = .TRANSITION,
        Flags = {},
    }

    barrier.Transition = {
        pResource = r.render_targets[r.frame_index],
        StateBefore = d3d12.RESOURCE_STATE_PRESENT,
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &barrier)

    rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    r.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)
    rtv_handle.ptr += uint(r.frame_index * r.rtv_descriptor_size)

    clear_color := [4]f32{0.1, 0.1, 0.2, 1.0}

    dsv_handle : d3d12.CPU_DESCRIPTOR_HANDLE
    r.dsv_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)

    r.command_list->OMSetRenderTargets(1, &rtv_handle, false, &dsv_handle)
    r.command_list->ClearRenderTargetView(rtv_handle, &clear_color, 0, nil)
    r.command_list->ClearDepthStencilView(dsv_handle, { .DEPTH }, 1.0, 0, 0, nil)

    // Pipeline
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.pipeline_state)

    // Привязываем heap с текстурой — обязательно до draw call
    heaps := []^d3d12.IDescriptorHeap{ r.srv_heap }
    r.command_list->SetDescriptorHeaps(u32(len(heaps)), raw_data(heaps))

    // SRV slot 1
    srv_gpu_handle: d3d12.GPU_DESCRIPTOR_HANDLE
    r.srv_heap->GetGPUDescriptorHandleForHeapStart(&srv_gpu_handle)
    r.command_list->SetGraphicsRootDescriptorTable(1, srv_gpu_handle)

    // viewport, scissor
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)

    // Geometry
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->IASetVertexBuffers(0, 1, &r.vertex_buffer_view)
    r.command_list->IASetIndexBuffer(&r.index_buffer_view)
    
    //r.command_list->DrawInstanced(3, 1, 0, 0)
    for i in 0..<draw_count{
        cb_offset := u64(i) * u64(size_of(SceneConstants))

        r.command_list->SetGraphicsRootConstantBufferView(
            0,
            r.constant_buffer->GetGPUVirtualAddress() + cb_offset,
        )

        r.command_list->DrawIndexedInstanced(r.index_count, 1, 0, 0, 0)
    }


    barrier.Transition.StateBefore = {.RENDER_TARGET}
    barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT
    r.command_list->ResourceBarrier(1, &barrier)

    dx_check(r.command_list->Close())

    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))

    dx_check(r.swap_chain->Present(1, {}))

    renderer_wait_for_gpu()
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

    r.vertex_buffer->Release()
    r.pipeline_state->Release()
    r.root_signature->Release()

    r.constant_buffer->Release()

    r.index_buffer->Release()
    r.depth_buffer->Release()
    r.dsv_heap->Release()

    r.texture->Release()
    r.srv_heap->Release()

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