package main

// Ray tracing with inline ray queries (DXR 1.1). Shaders trace rays against
// two levels of acceleration structures, trees of bounding boxes the GPU
// walks in hardware:
//   - a bottom-level structure (BLAS) per submesh, built once when its mesh
//     loads, from its vertex and index buffers, and compacted;
//   - a top-level structure (TLAS) over the frame's draws, rebuilt every
//     frame: one instance per draw, placing its submesh's BLAS by the draw's
//     world matrix.
// A ray query in a shader (RayQuery, TraceRayInline) walks them and reports
// hits; there are no ray-tracing pipelines or shader tables. The lit pass
// uses them for the sun's shadows (scene.hlsl, SunRayVisibility), and the
// reflection pass for reflections (PSRayReflections, renderer_ssr.odin).
//
// GPUs without DXR 1.1 keep the cascaded shadow maps: the shaders are then
// compiled without RAY_TRACING, since a pipeline using ray queries cannot be
// created there.

import "core:math"
import alg "core:math/linalg"
import d3d12 "vendor:directx/d3d12"

// Instance masks: which draws a ray query considers.
RAY_MASK_SHADOW_CASTER :: 0x1
RAY_MASK_OTHER :: 0x2

// Acceleration structures start on 256-byte boundaries
// (D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT).
RAY_STRUCTURE_ALIGNMENT :: u64(256)

// Cutout hits read texture coordinates from the vertex buffers (scene.hlsl).
#assert(size_of(Vertex) == 48 && offset_of(Vertex, texcoord) == 24)

// Per TLAS instance (draw), for cutout hits: the raw views of its mesh's
// buffers and its submesh's first index. Laid out like scene.hlsl's.
GpuRayInstance :: struct {
    vertex_buffer, index_buffer: u32,
    first_index: u32,
    _pad: u32,
}

// The sun's angular radius by default: the real sun's, about 0.27 degrees.
DEFAULT_SUN_ANGLE :: f32(0.27)
MAX_SUN_ANGLE :: f32(3)

RayTracing :: struct {
    // DXR 1.1 is available, and the setting to use it for the sun's shadows.
    supported: bool,
    shadows: bool,
    // The sun's angular radius in degrees: shadow rays spread over its disc,
    // and TAA averages them into soft edges (without TAA they stay hard).
    sun_angle: f32,
    // Ray-traced reflections in place of SSR (renderer_ssr.odin).
    reflections: bool,

    device: ^d3d12.IDevice5,
    command_list: ^d3d12.IGraphicsCommandList4,

    // The TLAS (sized for MAX_DRAWS instances) and its build scratch.
    tlas, tlas_scratch: ^d3d12.IResource,
    // Per frame slot: the instance descriptions the TLAS is built from, and
    // the GpuRayInstance table, both indexed like the frame's draws.
    instance_buffer: ^d3d12.IResource,
    instances: [^]d3d12.RAYTRACING_INSTANCE_DESC,
    info_buffer: ^d3d12.IResource,
    infos: [^]GpuRayInstance,
    // This frame's instances (its draw count), and whether the TLAS was built.
    instance_count: int,
    built: bool,
    // The meshes' compacted BLASes, in bytes (display only).
    blas_bytes: u64,
}

// Checks for DXR 1.1 and creates the TLAS and per-frame buffers. Runs right
// after the device, before any shader is compiled.
renderer_init_ray_tracing :: proc() {
    r := &g_renderer
    rt := &r.ray_tracing
    rt.sun_angle = DEFAULT_SUN_ANGLE

    options: d3d12.FEATURE_DATA_OPTIONS5
    if r.device->CheckFeatureSupport(.OPTIONS5, &options, size_of(options)) < 0 do return
    if options.RaytracingTier < ._1_1 do return
    if r.device->QueryInterface(d3d12.IDevice5_UUID, (^rawptr)(&rt.device)) < 0 do return
    if r.command_list->QueryInterface(d3d12.IGraphicsCommandList4_UUID, (^rawptr)(&rt.command_list)) < 0 {
        rt.device->Release()
        rt.device = nil
        return
    }
    rt.supported = true
    rt.shadows = true
    rt.reflections = true

    inputs := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS{
        Type = .TOP_LEVEL,
        Flags = {.PREFER_FAST_TRACE},
        NumDescs = MAX_DRAWS,
        DescsLayout = .ARRAY,
    }
    info: d3d12.RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO
    rt.device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &info)
    rt.tlas = create_buffer(info.ResultDataMaxSizeInBytes, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, {.RAYTRACING_ACCELERATION_STRUCTURE})
    rt.tlas_scratch = create_buffer(info.ScratchDataSizeInBytes, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)

    mapped: rawptr
    rt.instance_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_DRAWS * size_of(d3d12.RAYTRACING_INSTANCE_DESC)))
    rt.instances = ([^]d3d12.RAYTRACING_INSTANCE_DESC)(mapped)
    rt.info_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_DRAWS * size_of(GpuRayInstance)))
    rt.infos = ([^]GpuRayInstance)(mapped)
}

renderer_release_ray_tracing :: proc() {
    rt := &g_renderer.ray_tracing
    if !rt.supported do return
    rt.tlas->Release()
    rt.tlas_scratch->Release()
    rt.instance_buffer->Release()
    rt.info_buffer->Release()
    rt.command_list->Release()
    rt.device->Release()
}

// Whether this frame's sun shadows come from rays rather than the cascades.
renderer_ray_shadows_active :: proc() -> bool {
    rt := &g_renderer.ray_tracing
    return rt.supported && rt.shadows
}

// Whether this frame's reflections come from rays rather than SSR.
renderer_ray_reflections_active :: proc() -> bool {
    rt := &g_renderer.ray_tracing
    return rt.supported && rt.reflections
}

renderer_release_mesh_structures :: proc(mesh: ^GpuMesh) {
    if mesh.blas != nil do mesh.blas->Release()
    delete(mesh.blas_offsets)
    mesh.blas = nil
    mesh.blas_offsets = nil
}

// Builds the BLASes of every mesh that has none yet (one per submesh, in one
// buffer per mesh), and the raw vertex-buffer views cutout hits read. The
// builds are compacted: each is built with room for the worst case, its
// compacted size is read back, and it is copied into a buffer of that size.
// Runs with renderer_rebuild_meshlets, after loading or importing; waits for
// the GPU.
renderer_build_mesh_structures :: proc() {
    r := &g_renderer
    rt := &r.ray_tracing
    if !rt.supported do return

    Build :: struct {
        mesh: MeshHandle,
        geometry: d3d12.RAYTRACING_GEOMETRY_DESC,
        result_offset, scratch_offset: u64,
    }
    builds := make([dynamic]Build, context.temp_allocator)
    result_size, scratch_size: u64
    for &gpu, handle in r.meshes {
        if handle == 0 || gpu.index_buffer == nil || gpu.blas != nil do continue
        if gpu.vertex_srv_index == 0 {
            gpu.vertex_srv_index = renderer_alloc_srv()
            srv := d3d12.SHADER_RESOURCE_VIEW_DESC{
                Format = .R32_TYPELESS,
                ViewDimension = .BUFFER,
                Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
            }
            srv.Buffer = {NumElements = gpu.vertex_buffer_view.SizeInBytes / 4, Flags = {.RAW}}
            r.device->CreateShaderResourceView(gpu.vertex_buffer, &srv, renderer_srv_cpu(gpu.vertex_srv_index))
        }
        for submesh in g_assets.meshes[handle].data.submeshes {
            build := Build{mesh = MeshHandle(handle), geometry = {Type = .TRIANGLES, Flags = {.OPAQUE}}}
            build.geometry.Triangles = {
                IndexFormat = .R32_UINT,
                VertexFormat = .R32G32B32_FLOAT,
                IndexCount = submesh.index_count,
                VertexCount = gpu.vertex_buffer_view.SizeInBytes / size_of(Vertex),
                IndexBuffer = gpu.index_buffer->GetGPUVirtualAddress() + u64(submesh.first_index) * 4,
                VertexBuffer = {StartAddress = gpu.vertex_buffer->GetGPUVirtualAddress(), StrideInBytes = size_of(Vertex)},
            }
            inputs := renderer_blas_inputs(&build.geometry)
            info: d3d12.RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO
            rt.device->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &info)
            build.result_offset = result_size
            build.scratch_offset = scratch_size
            result_size += align_up(info.ResultDataMaxSizeInBytes, RAY_STRUCTURE_ALIGNMENT)
            scratch_size += align_up(info.ScratchDataSizeInBytes, RAY_STRUCTURE_ALIGNMENT)
            append(&builds, build)
        }
    }
    if len(builds) == 0 do return

    // Every build at once, each with its own scratch, writing its compacted
    // size into `sizes`.
    full := create_buffer(result_size, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, {.RAYTRACING_ACCELERATION_STRUCTURE})
    defer full->Release()
    scratch := create_buffer(scratch_size, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    defer scratch->Release()
    sizes_size := u64(len(builds) * 8)
    sizes := create_buffer(sizes_size, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON)
    defer sizes->Release()
    readback := create_buffer(sizes_size, .READBACK, {}, {.COPY_DEST})
    defer readback->Release()

    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))
    for &build, i in builds {
        desc := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC{
            DestAccelerationStructureData = full->GetGPUVirtualAddress() + build.result_offset,
            Inputs = renderer_blas_inputs(&build.geometry),
            ScratchAccelerationStructureData = scratch->GetGPUVirtualAddress() + build.scratch_offset,
        }
        postbuild := d3d12.RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC{
            DestBuffer = sizes->GetGPUVirtualAddress() + u64(i * 8),
            InfoType = .COMPACTED_SIZE,
        }
        rt.command_list->BuildRaytracingAccelerationStructure(&desc, 1, &postbuild)
    }
    barrier := resource_transition(sizes, {.UNORDERED_ACCESS}, {.COPY_SOURCE})
    r.command_list->ResourceBarrier(1, &barrier)
    r.command_list->CopyBufferRegion(readback, 0, sizes, 0, sizes_size)
    renderer_execute_and_wait()

    mapped: rawptr
    read_range := d3d12.RANGE{End = uint(sizes_size)}
    dx_check(readback->Map(0, &read_range, &mapped))
    compacted := ([^]u64)(mapped)[:len(builds)]

    // A buffer per mesh, its submeshes' structures one after another.
    dx_check(r.command_allocators[0]->Reset())
    dx_check(r.command_list->Reset(r.command_allocators[0], nil))
    for first := 0; first < len(builds); {
        mesh := builds[first].mesh
        last := first
        for last < len(builds) && builds[last].mesh == mesh do last += 1
        gpu := &r.meshes[mesh]
        gpu.blas_offsets = make([]u64, last - first)
        size: u64
        for i in first..<last {
            gpu.blas_offsets[i - first] = size
            size += align_up(compacted[i], RAY_STRUCTURE_ALIGNMENT)
        }
        gpu.blas = create_buffer(size, .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, {.RAYTRACING_ACCELERATION_STRUCTURE})
        rt.blas_bytes += size
        for i in first..<last {
            rt.command_list->CopyRaytracingAccelerationStructure(
                gpu.blas->GetGPUVirtualAddress() + gpu.blas_offsets[i - first],
                full->GetGPUVirtualAddress() + builds[i].result_offset,
                .COMPACT,
            )
        }
        first = last
    }
    written_range := d3d12.RANGE{}
    readback->Unmap(0, &written_range)
    renderer_execute_and_wait()
}

@(private="file")
renderer_blas_inputs :: proc(geometry: ^d3d12.RAYTRACING_GEOMETRY_DESC) -> d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS {
    inputs := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS{
        Type = .BOTTOM_LEVEL,
        Flags = {.PREFER_FAST_TRACE, .ALLOW_COMPACTION},
        NumDescs = 1,
        DescsLayout = .ARRAY,
    }
    inputs.pGeometryDescs = geometry
    return inputs
}

@(private="file")
align_up :: proc(value, alignment: u64) -> u64 {
    return (value + alignment - 1) / alignment * alignment
}

// Closes the command list, runs it, and waits for the GPU.
@(private="file")
renderer_execute_and_wait :: proc() {
    r := &g_renderer
    dx_check(r.command_list->Close())
    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(1, raw_data(lists))
    renderer_wait_for_gpu()
}

// Writes draw `index`'s TLAS instance: its submesh's BLAS placed by `model`.
// Shadow casters go under RAY_MASK_SHADOW_CASTER. Cutouts are non-opaque, so
// ray queries test their alpha; everything else is opaque. Facing: shadow
// rays test both sides (a shadow ray may meet a closed mesh's back faces
// first); reflection rays cull back faces, as the rasterizer does, except on
// double-sided surfaces.
renderer_write_ray_instance :: proc(index: int, model: alg.Matrix4f32, mesh: MeshHandle, submesh: int, first_index: u32, cutout, double_sided, casts_shadow: bool) {
    r := &g_renderer
    rt := &r.ray_tracing
    if !rt.supported do return
    gpu := &r.meshes[mesh]
    blas: d3d12.GPU_VIRTUAL_ADDRESS
    if gpu.blas != nil && submesh < len(gpu.blas_offsets) {
        blas = gpu.blas->GetGPUVirtualAddress() + gpu.blas_offsets[submesh]
    }
    flags := d3d12.RAYTRACING_INSTANCE_FLAGS{.FORCE_NON_OPAQUE} if cutout else {.FORCE_OPAQUE}
    if double_sided do flags += {.TRIANGLE_CULL_DISABLE}
    mask: u32 = RAY_MASK_SHADOW_CASTER if casts_shadow else RAY_MASK_OTHER
    slot := int(r.frame_slot) * MAX_DRAWS + index
    // The C struct's bit fields: ID (24 bits) and mask (8), then hit-group
    // offset (24) and flags (8). A null BLAS makes the instance inactive.
    rt.instances[slot] = d3d12.RAYTRACING_INSTANCE_DESC{
        Transform = {
            {model[0, 0], model[0, 1], model[0, 2], model[0, 3]},
            {model[1, 0], model[1, 1], model[1, 2], model[1, 3]},
            {model[2, 0], model[2, 1], model[2, 2], model[2, 3]},
        },
        InstanceID = u32(index) | mask << 24,
        InstanceContributionToHitGroupIndex = transmute(u32)flags << 24,
        AccelerationStructure = blas,
    }
    rt.infos[slot] = GpuRayInstance{
        vertex_buffer = gpu.vertex_srv_index,
        index_buffer = gpu.index_srv_index,
        first_index = first_index,
    }
}

// Builds this frame's TLAS from the instances renderer_prepare_frame wrote,
// when something will trace rays.
renderer_build_scene_tlas :: proc(instance_count: int) {
    r := &g_renderer
    rt := &r.ray_tracing
    rt.instance_count = instance_count
    rt.built = renderer_ray_shadows_active() || renderer_ray_reflections_active()
    // Timed every frame, like every pass (zero when nothing is built).
    renderer_begin_gpu_pass(.Ray_Structures)
    defer renderer_end_gpu_pass(.Ray_Structures)
    if !rt.built do return

    desc := d3d12.BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC{
        DestAccelerationStructureData = rt.tlas->GetGPUVirtualAddress(),
        Inputs = {
            Type = .TOP_LEVEL,
            Flags = {.PREFER_FAST_TRACE},
            NumDescs = u32(instance_count),
            DescsLayout = .ARRAY,
        },
        ScratchAccelerationStructureData = rt.tlas_scratch->GetGPUVirtualAddress(),
    }
    desc.Inputs.InstanceDescs = rt.instance_buffer->GetGPUVirtualAddress() + u64(int(r.frame_slot) * MAX_DRAWS * size_of(d3d12.RAYTRACING_INSTANCE_DESC))
    rt.command_list->BuildRaytracingAccelerationStructure(&desc, 0, nil)
    // Rays read it only after the build is complete.
    barrier := d3d12.RESOURCE_BARRIER{Type = .UAV}
    barrier.UAV = {pResource = rt.tlas}
    r.command_list->ResourceBarrier(1, &barrier)
}

// Binds the TLAS, the instance table and the raw mesh buffers for a pass
// that shades with scene.hlsl (the lit pass and captures). On GPUs without
// ray tracing the shaders do not declare them, so nothing is bound.
renderer_bind_ray_tracing :: proc() {
    r := &g_renderer
    rt := &r.ray_tracing
    if !rt.supported do return
    renderer_bind_buffer_srv(.Scene_BVH, rt.tlas->GetGPUVirtualAddress())
    renderer_bind_buffer_srv(.Ray_Instances, rt.info_buffer->GetGPUVirtualAddress() + u64(int(r.frame_slot) * MAX_DRAWS * size_of(GpuRayInstance)))
    renderer_bind_srv(.Mesh_Buffers, 0)
}

// The frame constants' ray-tracing fields: whether to trace the sun's
// shadows, and the tangent of the sun's angular radius to spread them over
// (none without TAA, which would leave the noise unaveraged).
renderer_ray_shadow_constants :: proc() -> (enabled: u32, sun_tan: f32) {
    r := &g_renderer
    if !renderer_ray_shadows_active() do return 0, 0
    if r.post_anti_aliasing != .TAA do return 1, 0
    return 1, math.tan(math.to_radians(r.ray_tracing.sun_angle))
}
