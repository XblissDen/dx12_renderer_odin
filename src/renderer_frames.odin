package main

import win32 "core:sys/windows"
import d3d12 "vendor:directx/d3d12"

renderer_create_mapped_upload_buffer :: proc(size: u64) -> (
    buffer: ^d3d12.IResource,
    mapped: rawptr,
) {
    heap := d3d12.HEAP_PROPERTIES{Type = .UPLOAD}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = size,
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }

    dx_check(g_renderer.device->CreateCommittedResource(
        &heap, {}, &desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil,
        d3d12.IResource_UUID, (^rawptr)(&buffer),
    ))

    read_range := d3d12.RANGE{Begin = 0, End = 0}
    dx_check(buffer->Map(0, &read_range, &mapped))
    return
}

renderer_create_frame_constant_buffers :: proc() {
    r := &g_renderer
    mapped: rawptr

    r.object_buffer, mapped = renderer_create_mapped_upload_buffer(
        u64(FRAME_COUNT * MAX_DRAWS * size_of(ObjectData)),
    )
    r.object_mapped = ([^]ObjectData)(mapped)

    r.instance_buffer, mapped = renderer_create_mapped_upload_buffer(
        u64(FRAME_COUNT * MAX_INSTANCES * size_of(u32)),
    )
    r.instance_mapped = ([^]u32)(mapped)

    r.frame_constant_buffer, mapped = renderer_create_mapped_upload_buffer(
        u64(FRAME_COUNT * size_of(FrameConstants)),
    )
    r.frame_cb_mapped_data = ([^]FrameConstants)(mapped)

    r.post_constant_buffer, mapped = renderer_create_mapped_upload_buffer(
        u64(FRAME_COUNT * size_of(PostConstants)),
    )
    r.post_cb_mapped_data = ([^]PostConstants)(mapped)

    r.sky_constant_buffer, mapped = renderer_create_mapped_upload_buffer(
        u64(FRAME_COUNT * size_of(SkyConstants)),
    )
    r.sky_cb_mapped_data = ([^]SkyConstants)(mapped)
}

renderer_create_timestamp_resources :: proc() {
    r := &g_renderer

    query_desc := d3d12.QUERY_HEAP_DESC{
        Type = .TIMESTAMP,
        Count = FRAME_COUNT * GPU_TIMESTAMP_COUNT,
    }
    dx_check(r.device->CreateQueryHeap(
        &query_desc,
        d3d12.IQueryHeap_UUID,
        (^rawptr)(&r.timestamp_heap),
    ))

    heap := d3d12.HEAP_PROPERTIES{Type = .READBACK}
    desc := d3d12.RESOURCE_DESC{
        Dimension = .BUFFER,
        Width = u64(FRAME_COUNT * GPU_TIMESTAMP_COUNT * size_of(u64)),
        Height = 1,
        DepthOrArraySize = 1,
        MipLevels = 1,
        SampleDesc = {Count = 1},
        Layout = .ROW_MAJOR,
    }
    dx_check(r.device->CreateCommittedResource(
        &heap, {}, &desc, {.COPY_DEST}, nil,
        d3d12.IResource_UUID, (^rawptr)(&r.timestamp_readback),
    ))
}

renderer_object_buffer_address :: proc() -> u64 {
    r := &g_renderer
    return r.object_buffer->GetGPUVirtualAddress() +
           u64(int(r.frame_slot) * MAX_DRAWS * size_of(ObjectData))
}

renderer_instance_buffer_address :: proc() -> u64 {
    r := &g_renderer
    return r.instance_buffer->GetGPUVirtualAddress() +
           u64(int(r.frame_slot) * MAX_INSTANCES * size_of(u32))
}

renderer_frame_cb_address :: proc() -> u64 {
    r := &g_renderer
    return r.frame_constant_buffer->GetGPUVirtualAddress() +
           u64(r.frame_slot) * u64(size_of(FrameConstants))
}

renderer_post_cb_address :: proc() -> u64 {
    r := &g_renderer
    return r.post_constant_buffer->GetGPUVirtualAddress() +
           u64(r.frame_slot) * u64(size_of(PostConstants))
}

renderer_sky_cb_address :: proc() -> u64 {
    r := &g_renderer
    return r.sky_constant_buffer->GetGPUVirtualAddress() +
           u64(r.frame_slot) * u64(size_of(SkyConstants))
}

renderer_wait_for_fence :: proc(value: u64) {
    r := &g_renderer
    if value == 0 || r.fence->GetCompletedValue() >= value {
        return
    }

    dx_check(r.fence->SetEventOnCompletion(value, r.fence_event))
    assert(
        win32.WaitForSingleObject(r.fence_event, win32.INFINITE) ==
        win32.WAIT_OBJECT_0,
    )
}

renderer_begin_frame :: proc() {
    r := &g_renderer
    completed_frame := r.frame_fence_values[r.frame_slot]
    renderer_wait_for_fence(completed_frame)

    if completed_frame != 0 {
        renderer_read_gpu_timings(r.frame_slot)
        renderer_read_auto_exposure(r.frame_slot)
    }

    allocator := r.command_allocators[r.frame_slot]
    dx_check(allocator->Reset())
    dx_check(r.command_list->Reset(allocator, nil))
}

renderer_submit_frame :: proc() {
    r := &g_renderer
    slot := r.frame_slot
    first_query := slot * GPU_TIMESTAMP_COUNT

    r.command_list->ResolveQueryData(
        r.timestamp_heap,
        .TIMESTAMP,
        first_query,
        GPU_TIMESTAMP_COUNT,
        r.timestamp_readback,
        u64(first_query) * u64(size_of(u64)),
    )
    dx_check(r.command_list->Close())

    lists := []^d3d12.ICommandList{r.command_list}
    r.command_queue->ExecuteCommandLists(u32(len(lists)), raw_data(lists))

    r.fence_value += 1
    dx_check(r.command_queue->Signal(r.fence, r.fence_value))
    r.frame_fence_values[slot] = r.fence_value

    r.frame_slot = (slot + 1) % FRAME_COUNT
}