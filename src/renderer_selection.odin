package main

import "core:fmt"
import alg "core:math/linalg"
import win32 "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import d3dc "vendor:directx/d3d_compiler"

SelectionConstants :: struct {
    model_view_projection: alg.Matrix4f32,
    bounds_min: alg.Vector3f32,
    _pad0: f32,
    bounds_max: alg.Vector3f32,
    _pad1: f32,
}

#assert(size_of(SelectionConstants) == 96)
SELECTION_ROOT_VALUE_COUNT :: u32(size_of(SelectionConstants) / size_of(f32))

renderer_create_selection_pipeline :: proc() {
    r := &g_renderer

    parameter := d3d12.ROOT_PARAMETER{
        ParameterType = ._32BIT_CONSTANTS,
        ShaderVisibility = .VERTEX,
    }
    parameter.Constants = {
        ShaderRegister = 0,
        Num32BitValues = SELECTION_ROOT_VALUE_COUNT,
    }

    root_desc := d3d12.ROOT_SIGNATURE_DESC{
        NumParameters = 1,
        pParameters = &parameter,
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

    path := win32.utf8_to_wstring("shaders/selection.hlsl")
    entries := [2]cstring{"VSMain", "PSMain"}
    targets := [2]cstring{"vs_5_1", "ps_5_1"}
    shaders: [2]^d3d12.IBlob

    flags: u32
    when ODIN_DEBUG {
        flags = u32(d3dc.D3DCOMPILE_FLAG.DEBUG | d3dc.D3DCOMPILE_FLAG.SKIP_OPTIMIZATION)
    }

    for i in 0..<2 {
        messages: ^d3d12.IBlob
        hr = d3dc.CompileFromFile(
            path, nil, nil, entries[i], targets[i],
            flags, 0, &shaders[i], &messages,
        )
        if messages != nil {
            fmt.println("Selection shader:", cstring(messages->GetBufferPointer()))
            messages->Release()
        }
        dx_check(hr)
    }

    defer {
        for shader in shaders {
            shader->Release()
        }
    }

    desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC{
        pRootSignature = r.selection_root_signature,
        VS = {
            pShaderBytecode = shaders[0]->GetBufferPointer(),
            BytecodeLength = shaders[0]->GetBufferSize(),
        },
        PS = {
            pShaderBytecode = shaders[1]->GetBufferPointer(),
            BytecodeLength = shaders[1]->GetBufferSize(),
        },
        RasterizerState = {
            FillMode = .SOLID,
            CullMode = .NONE,
            DepthClipEnable = true,
        },
        BlendState = {RenderTarget = {0 = {
            SrcBlend = .ONE,
            DestBlend = .ZERO,
            BlendOp = .ADD,
            SrcBlendAlpha = .ONE,
            DestBlendAlpha = .ZERO,
            BlendOpAlpha = .ADD,
            LogicOp = .NOOP,
            RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
        }}},
        DepthStencilState = {
            DepthEnable = true,
            DepthWriteMask = .ZERO,
            DepthFunc = .LESS_EQUAL,
        },
        DSVFormat = .D32_FLOAT,
        SampleMask = max(u32),
        PrimitiveTopologyType = .LINE,
        NumRenderTargets = 1,
        SampleDesc = {Count = 1},
    }
    desc.RTVFormats[0] = .R8G8B8A8_UNORM

    dx_check(r.device->CreateGraphicsPipelineState(
        &desc,
        d3d12.IPipelineState_UUID,
        (^rawptr)(&r.selection_pipeline_state),
    ))
}

renderer_render_selection :: proc(scene: ^Scene) {
    bounds, transform, ok := editor_selection_bounds(scene)
    camera_index := camera_find_active(scene)
    if !ok || camera_index < 0 {
        return
    }

    r := &g_renderer
    camera := &scene.cameras[camera_index]
    view := camera_view_matrix(camera, scene.transforms[camera_index].position)
    projection := camera_projection(camera, f32(r.width) / f32(r.height))

    model := transform_matrix(transform)

    // Slightly expand the box so its lines do not fight the mesh surface.
    padding := max(
        alg.length(bounds.maximum - bounds.minimum) * 0.005,
        f32(0.001),
    )
    expansion := alg.Vector3f32{padding, padding, padding}

    constants := SelectionConstants{
        model_view_projection = alg.transpose(model) * view * projection,
        bounds_min = bounds.minimum - expansion,
        bounds_max = bounds.maximum + expansion,
    }

    rtv: d3d12.CPU_DESCRIPTOR_HANDLE
    r.rtv_heap->GetCPUDescriptorHandleForHeapStart(&rtv)
    rtv.ptr += uint(r.frame_index * r.rtv_descriptor_size)

    dsv := renderer_depth_dsv(read_only = true)
    r.command_list->OMSetRenderTargets(1, &rtv, false, &dsv)

    r.command_list->SetGraphicsRootSignature(r.selection_root_signature)
    r.command_list->SetPipelineState(r.selection_pipeline_state)
    r.command_list->SetGraphicsRoot32BitConstants(
        0, SELECTION_ROOT_VALUE_COUNT, &constants, 0,
    )
    r.command_list->IASetPrimitiveTopology(.LINELIST)
    r.command_list->DrawInstanced(24, 1, 0, 0)
}