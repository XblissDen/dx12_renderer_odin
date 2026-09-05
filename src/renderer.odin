package main

import "base:runtime"
import "core:fmt"
import win32 "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"
import "core:math"
import alg "core:math/linalg"

FRAME_COUNT :: 2

Vertex :: struct {
    position: [3]f32,
    color:    [4]f32,
}

SceneConstants :: struct #align(256){
    model: alg.Matrix4f32,
    view: alg.Matrix4f32,
    projection: alg.Matrix4f32
}

Renderer :: struct {
    device: ^d3d12.IDevice,
    swap_chain: ^dxgi.ISwapChain3,
    command_queue: ^d3d12.ICommandQueue,

    rtv_heap: ^d3d12.IDescriptorHeap,
    rtv_descriptor_size: u32,
    render_targets: [FRAME_COUNT]^d3d12.IResource,

    command_allocators: [FRAME_COUNT]^d3d12.ICommandAllocator,
    command_list: ^d3d12.IGraphicsCommandList,

    fence: ^d3d12.IFence,
    fence_values: [FRAME_COUNT]u64,
    fence_event: win32.HANDLE,

    root_signature: ^d3d12.IRootSignature,
    pipeline_state: ^d3d12.IPipelineState,

    vertex_buffer: ^d3d12.IResource,
    vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW,

    viewport: d3d12.VIEWPORT,
    scissor_rect: d3d12.RECT,

    constant_buffer: ^d3d12.IResource,
    cb_mapped_data: ^SceneConstants,

    rotation_angle: f32,

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
        Width = WINDOW_WIDTH,
        Height = WINDOW_HEIGHT,
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
    r.fence_values[r.frame_index] = 1

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
    rs_desc := d3d12.ROOT_SIGNATURE_DESC{
        NumParameters = 1,
        pParameters = &root_param,
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
            SemanticName         = "COLOR",
            SemanticIndex        = 0,
            Format               = .R32G32B32A32_FLOAT,
            InputSlot            = 0,
            AlignedByteOffset    = 12,
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
            FillMode = .SOLID,
            CullMode = .BACK,
            FrontCounterClockwise = false,
            DepthClipEnable = true,
        },
        BlendState = {
            RenderTarget = { 0 = {
                RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
            }},
        },
        DepthStencilState = {
            DepthEnable = false,
            StencilEnable = false,
        },
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

    // VERTEX BUFFER
    vertices := []Vertex {
        { position = { 0.0,  0.5, 0.0 }, color = { 1, 0, 0, 1 } }, // верх, красный
        { position = { 0.5, -0.5, 0.0 }, color = { 0, 1, 0, 1 } }, // право, зелёный
        { position = {-0.5, -0.5, 0.0 }, color = { 0, 0, 1, 1 } }, // лево, синий
    }

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

    // CONSTANT BUFFER
    cb_size := u64(size_of(SceneConstants))

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

renderer_render_frame :: proc(){
    r := &g_renderer

    allocator := r.command_allocators[r.frame_index]
    dx_check(allocator->Reset())
    dx_check(r.command_list->Reset(allocator, nil))

    r.rotation_angle += 0.01
    model := alg.matrix4_rotate_f32(r.rotation_angle, {0 , 1, 0})

    view := look_at_lh(
        eye    = { 0, 0, -2 },
        centre = { 0, 0,  0 },
        up     = { 0, 1,  0 },
    )

    proj := perspective_lh(
        alg.to_radians(f32(45)),
        f32(WINDOW_WIDTH) / f32(WINDOW_HEIGHT),
        0.1,
        100.0,
    )

    r.cb_mapped_data.model = model
    r.cb_mapped_data.view = view
    r.cb_mapped_data.projection = proj

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
    r.command_list->OMSetRenderTargets(1, &rtv_handle, false, nil)
    r.command_list->ClearRenderTargetView(rtv_handle, &clear_color, 0, nil)

    // Pipeline
    r.command_list->SetGraphicsRootSignature(r.root_signature)
    r.command_list->SetPipelineState(r.pipeline_state)

    r.command_list->SetGraphicsRootConstantBufferView(
        0,
        r.constant_buffer->GetGPUVirtualAddress(),
    )

    // Geometry
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)
    r.command_list->IASetVertexBuffers(0, 1, &r.vertex_buffer_view)

    // viewport, scissor
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)

    r.command_list->DrawInstanced(3, 1, 0, 0)

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

    dx_check(r.command_queue->Signal(r.fence, r.fence_values[r.frame_index]))

    if r.fence ->GetCompletedValue() < r.fence_values[r.frame_index]{
        dx_check(r.fence->SetEventOnCompletion(r.fence_values[r.frame_index], r.fence_event))
        win32.WaitForSingleObject(r.fence_event, win32.INFINITE)
    }

    r.frame_index = r.swap_chain->GetCurrentBackBufferIndex()
    r.fence_values[r.frame_index] += 1
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