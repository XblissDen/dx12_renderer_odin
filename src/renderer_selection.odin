package main

import "core:fmt"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// The selection outline and debug lines (shaders/selection.hlsl), drawn on
// the back buffer after anti-aliasing. For the outline, a mask pass draws
// each selected group (a selected entity with its descendants) into an
// integer target as the group's id, without depth testing; an outline pass
// then colors the pixels just outside each group's silhouette.
SelectionConstants :: struct {
    model_view_projection: alg.Matrix4f32,
    // 1 for the primary selection's group. Debug lines: 1 for the hidden pass.
    group: u32,
    camera_position: [3]f32, // Debug lines only.
}

// Odin aligns matrices to 32 bytes, so the struct (and the root constants)
// end with 16 bytes past the shader's 80.
#assert(size_of(SelectionConstants) == 96)
SELECTION_ROOT_VALUE_COUNT :: u32(size_of(SelectionConstants) / size_of(f32))
SELECTION_MASK_FORMAT :: dxgi.FORMAT.R16_UINT

// Vertices of the debug lines one frame can draw, two per line.
MAX_DEBUG_LINE_VERTICES :: 1 << 17

DebugLineVertex :: struct {
    position: [3]f32,
    color: u32, // R8G8B8A8, as gizmo_color packs it.
}

renderer_create_selection_root_signature :: proc() {
    r := &g_renderer

    mask_range := d3d12.DESCRIPTOR_RANGE{RangeType = .SRV, NumDescriptors = 1}
    parameters := [2]d3d12.ROOT_PARAMETER{
        {ParameterType = ._32BIT_CONSTANTS, ShaderVisibility = .ALL},
        {ParameterType = .DESCRIPTOR_TABLE, ShaderVisibility = .PIXEL},
    }
    parameters[0].Constants = {ShaderRegister = 0, Num32BitValues = SELECTION_ROOT_VALUE_COUNT}
    parameters[1].DescriptorTable = {NumDescriptorRanges = 1, pDescriptorRanges = &mask_range}

    root_desc := d3d12.ROOT_SIGNATURE_DESC{
        NumParameters = len(parameters),
        pParameters = &parameters[0],
        // The mask pass reads mesh positions.
        Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT},
    }

    signature, errors: ^d3d12.IBlob
    hr := d3d12.SerializeRootSignature(&root_desc, ._1, &signature, &errors)
    if errors != nil {
        fmt.println("Selection root signature:", cstring(errors->GetBufferPointer()))
        errors->Release()
    }
    dx_check(hr)
    defer signature->Release()

    dx_check(r.device->CreateRootSignature(
        0,
        signature->GetBufferPointer(),
        signature->GetBufferSize(),
        d3d12.IRootSignature_UUID,
        (^rawptr)(&r.selection_root_signature),
    ))
}

// The mask and outline pipelines; rebuilt by shader hot-reload.
renderer_create_selection_pso :: proc() {
    r := &g_renderer

    mask_vs := renderer_compile_shader("shaders/selection.hlsl", "VSMask", "vs_5_1")
    defer mask_vs->Release()
    mask_ps := renderer_compile_shader("shaders/selection.hlsl", "PSMask", "ps_5_1")
    defer mask_ps->Release()
    outline_vs := renderer_compile_shader("shaders/selection.hlsl", "VSOutline", "vs_5_1")
    defer outline_vs->Release()
    outline_ps := renderer_compile_shader("shaders/selection.hlsl", "PSOutline", "ps_5_1")
    defer outline_ps->Release()
    line_vs := renderer_compile_shader("shaders/selection.hlsl", "VSLine", "vs_5_1")
    defer line_vs->Release()
    line_ps := renderer_compile_shader("shaders/selection.hlsl", "PSLine", "ps_5_1")
    defer line_ps->Release()

    // Only the position of Vertex.
    input_layout := [1]d3d12.INPUT_ELEMENT_DESC{
        {SemanticName = "POSITION", Format = .R32G32B32_FLOAT, AlignedByteOffset = 0, InputSlotClass = .PER_VERTEX_DATA},
    }
    // Both sides and no depth: the whole silhouette, hidden parts included.
    desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC{
        pRootSignature = r.selection_root_signature,
        VS = shader_bytecode(mask_vs),
        PS = shader_bytecode(mask_ps),
        InputLayout = {pInputElementDescs = &input_layout[0], NumElements = len(input_layout)},
        RasterizerState = {FillMode = .SOLID, CullMode = .NONE, DepthClipEnable = true},
        BlendState = {RenderTarget = {0 = {
            LogicOp = .NOOP,
            RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
        }}},
        SampleMask = max(u32),
        PrimitiveTopologyType = .TRIANGLE,
        NumRenderTargets = 1,
        SampleDesc = {Count = 1},
    }
    desc.RTVFormats[0] = SELECTION_MASK_FORMAT
    renderer_create_pso(&desc, &r.selection_pipeline_state)

    desc.VS = shader_bytecode(outline_vs)
    desc.PS = shader_bytecode(outline_ps)
    desc.InputLayout = {}
    desc.RTVFormats[0] = .R8G8B8A8_UNORM
    renderer_create_pso(&desc, &r.selection_outline_pipeline_state)

    // Debug lines, blended over the image and tested against the scene's
    // depth without writing it: one pipeline for the parts in front of the
    // scene, one for the parts behind it.
    line_layout := [2]d3d12.INPUT_ELEMENT_DESC{
        {SemanticName = "POSITION", Format = .R32G32B32_FLOAT, AlignedByteOffset = 0, InputSlotClass = .PER_VERTEX_DATA},
        {SemanticName = "COLOR", Format = .R8G8B8A8_UNORM, AlignedByteOffset = 12, InputSlotClass = .PER_VERTEX_DATA},
    }
    desc.VS = shader_bytecode(line_vs)
    desc.PS = shader_bytecode(line_ps)
    desc.InputLayout = {pInputElementDescs = &line_layout[0], NumElements = len(line_layout)}
    desc.RasterizerState.AntialiasedLineEnable = true
    desc.BlendState.RenderTarget[0] = {
        BlendEnable = true,
        SrcBlend = .SRC_ALPHA,
        DestBlend = .INV_SRC_ALPHA,
        BlendOp = .ADD,
        SrcBlendAlpha = .ONE,
        DestBlendAlpha = .INV_SRC_ALPHA,
        BlendOpAlpha = .ADD,
        LogicOp = .NOOP,
        RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
    }
    desc.DepthStencilState = {DepthEnable = true, DepthWriteMask = .ZERO, DepthFunc = .LESS_EQUAL}
    desc.DSVFormat = .D32_FLOAT
    desc.PrimitiveTopologyType = .LINE
    renderer_create_pso(&desc, &r.debug_line_pipeline_states[0])
    desc.DepthStencilState.DepthFunc = .GREATER
    renderer_create_pso(&desc, &r.debug_line_pipeline_states[1])
}

// Each frame slot's share of the debug line vertices; once at startup.
renderer_create_debug_lines :: proc() {
    r := &g_renderer
    mapped: rawptr
    r.debug_line_buffer, mapped = renderer_create_mapped_upload_buffer(
        u64(FRAME_COUNT * MAX_DEBUG_LINE_VERTICES * size_of(DebugLineVertex)),
    )
    r.debug_line_mapped = ([^]DebugLineVertex)(mapped)
}

// Draws the editor's debug lines (editor_debug_lines) on the back buffer:
// faintly where the scene hides them, then fully where it does not.
renderer_render_debug_lines :: proc(scene: ^Scene, back_buffer: d3d12.CPU_DESCRIPTOR_HANDLE) {
    camera_index := camera_find_active(scene)
    if camera_index < 0 do return
    lines := editor_debug_lines(scene)
    // Whole lines only.
    count := min(len(lines), MAX_DEBUG_LINE_VERTICES) &~ 1
    if count == 0 do return

    r := &g_renderer
    first := int(r.frame_slot) * MAX_DEBUG_LINE_VERTICES
    copy(r.debug_line_mapped[first:first + count], lines[:count])
    vertex_view := d3d12.VERTEX_BUFFER_VIEW{
        BufferLocation = r.debug_line_buffer->GetGPUVirtualAddress() + u64(first * size_of(DebugLineVertex)),
        SizeInBytes = u32(count * size_of(DebugLineVertex)),
        StrideInBytes = size_of(DebugLineVertex),
    }

    camera := &scene.cameras[camera_index]
    camera_position := scene.transforms[camera_index].position
    constants := SelectionConstants{
        model_view_projection = camera_view_matrix(camera, camera_position) *
                                camera_projection(camera, f32(r.width) / f32(r.height)),
        camera_position = camera_position,
    }

    back_buffer := back_buffer
    depth := renderer_depth_dsv(read_only = true)
    r.command_list->OMSetRenderTargets(1, &back_buffer, false, &depth)
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)
    r.command_list->SetGraphicsRootSignature(r.selection_root_signature)
    r.command_list->IASetPrimitiveTopology(.LINELIST)
    r.command_list->IASetVertexBuffers(0, 1, &vertex_view)
    // The hidden parts first, so the visible ones draw over them.
    for hidden in ([2]u32{1, 0}) {
        constants.group = hidden
        r.command_list->SetPipelineState(r.debug_line_pipeline_states[hidden])
        r.command_list->SetGraphicsRoot32BitConstants(0, SELECTION_ROOT_VALUE_COUNT, &constants, 0)
        r.command_list->DrawInstanced(u32(count), 1, 0, 0)
    }
}

// (Re)creates the mask target at the window size; at startup and on resize.
renderer_create_selection_mask :: proc() {
    r := &g_renderer

    if r.selection_rtv_heap == nil {
        rtv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC{NumDescriptors = 1, Type = .RTV}
        dx_check(r.device->CreateDescriptorHeap(
            &rtv_heap_desc,
            d3d12.IDescriptorHeap_UUID,
            (^rawptr)(&r.selection_rtv_heap),
        ))
        r.selection_srv_index = renderer_alloc_srv()
    }

    heap_props := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .TEXTURE2D,
        Width = u64(r.width),
        Height = r.height,
        DepthOrArraySize = 1,
        MipLevels = 1,
        Format = SELECTION_MASK_FORMAT,
        SampleDesc = {Count = 1},
        Flags = {.ALLOW_RENDER_TARGET},
    }
    clear_value := d3d12.CLEAR_VALUE{Format = SELECTION_MASK_FORMAT}
    dx_check(r.device->CreateCommittedResource(
        &heap_props,
        {},
        &desc,
        {.PIXEL_SHADER_RESOURCE},
        &clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&r.selection_mask),
    ))

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.selection_rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    r.device->CreateRenderTargetView(r.selection_mask, nil, rtv)
    renderer_write_srv(r.selection_mask, SELECTION_MASK_FORMAT, r.selection_srv_index)
}

// Outlines the selection on the back buffer (bound as `back_buffer`). Each
// selected entity with no selected ancestor makes a group with all its
// descendants, outlined as one shape; the primary selection's group is
// orange, the others darker.
renderer_render_selection :: proc(scene: ^Scene, back_buffer: d3d12.CPU_DESCRIPTOR_HANDLE) {
    camera_index := camera_find_active(scene)
    if camera_index < 0 || editor_selection_count() == 0 {
        return
    }

    r := &g_renderer
    camera := &scene.cameras[camera_index]
    view := camera_view_matrix(camera, scene.transforms[camera_index].position)
    projection := camera_projection(camera, f32(r.width) / f32(r.height))

    // Each entity's group: its highest selected ancestor (or itself). Group
    // ids follow the tops in index order, after the primary's, which is 1.
    top_of := make([]int, scene.entity_count, context.temp_allocator)
    primary_top := -1
    for i in 0..<scene.entity_count {
        top_of[i] = -1
        if !scene.alive[i] do continue
        if editor_is_selected(Entity(i)) do top_of[i] = i
        current := i
        for _ in 0..<MAX_ENTITIES {
            parent := scene_parent(scene, current) or_break
            if editor_is_selected(Entity(parent)) do top_of[i] = parent
            current = parent
        }
        if Entity(i) == g_editor_selected do primary_top = top_of[i]
    }
    group_of_top := make(map[int]u32, context.temp_allocator)
    if primary_top >= 0 do group_of_top[primary_top] = 1
    next_group := u32(2)
    for top, i in top_of {
        if top != i || top == primary_top do continue
        group_of_top[top] = min(next_group, u32(max(u16)))
        next_group += 1
    }

    mask_barrier := d3d12.RESOURCE_BARRIER{Type = .TRANSITION}
    mask_barrier.Transition = {
        pResource = r.selection_mask,
        StateBefore = {.PIXEL_SHADER_RESOURCE},
        StateAfter = {.RENDER_TARGET},
        Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
    }
    r.command_list->ResourceBarrier(1, &mask_barrier)

    mask_rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.selection_rtv_heap->GetCPUDescriptorHandleForHeapStart(&mask_rtv)
    r.command_list->OMSetRenderTargets(1, &mask_rtv, false, nil)
    none := [4]f32{}
    r.command_list->ClearRenderTargetView(mask_rtv, &none, 0, nil)
    r.command_list->RSSetViewports(1, &r.viewport)
    r.command_list->RSSetScissorRects(1, &r.scissor_rect)

    r.command_list->SetGraphicsRootSignature(r.selection_root_signature)
    r.command_list->SetPipelineState(r.selection_pipeline_state)
    r.command_list->IASetPrimitiveTopology(.TRIANGLELIST)

    for top, index in top_of {
        if top < 0 do continue
        // Drawable meshes only, as the renderer draws them.
        _, world := editor_entity_bounds(scene, Entity(index)) or_continue
        constants := SelectionConstants{
            model_view_projection = alg.transpose(world) * view * projection,
            group = group_of_top[top],
        }
        r.command_list->SetGraphicsRoot32BitConstants(0, SELECTION_ROOT_VALUE_COUNT, &constants, 0)
        gpu_mesh := &r.meshes[scene.mesh_renderers[index].mesh]
        r.command_list->IASetVertexBuffers(0, 1, &gpu_mesh.vertex_buffer_view)
        r.command_list->IASetIndexBuffer(&gpu_mesh.index_buffer_view)
        r.command_list->DrawIndexedInstanced(gpu_mesh.index_count, 1, 0, 0, 0)
    }

    mask_barrier.Transition.StateBefore = {.RENDER_TARGET}
    mask_barrier.Transition.StateAfter = {.PIXEL_SHADER_RESOURCE}
    r.command_list->ResourceBarrier(1, &mask_barrier)

    back_buffer := back_buffer
    r.command_list->OMSetRenderTargets(1, &back_buffer, false, nil)
    heaps := []^d3d12.IDescriptorHeap{r.srv_heap}
    r.command_list->SetDescriptorHeaps(1, raw_data(heaps))
    r.command_list->SetPipelineState(r.selection_outline_pipeline_state)
    r.command_list->SetGraphicsRootDescriptorTable(1, renderer_srv_gpu(r.selection_srv_index))
    r.command_list->DrawInstanced(3, 1, 0, 0)
}
