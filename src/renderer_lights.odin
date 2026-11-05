package main

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:thread"
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
// signature. The pipeline is built with the others (renderer_build_pipelines).
renderer_create_light_clusters :: proc() {
    r := &g_renderer

    mapped: rawptr
    r.light_buffer, mapped = renderer_create_mapped_upload_buffer(u64(FRAME_COUNT * MAX_LIGHTS * size_of(GpuLight)))
    r.light_mapped_data = ([^]GpuLight)(mapped)

    // Buffers decay to the common state after each frame's command list, so
    // every frame starts from there.
    r.cluster_buffer = create_buffer(
        u64(LIGHT_CLUSTER_COUNT * LIGHT_CLUSTER_STRIDE * size_of(u32)),
        .DEFAULT, {.ALLOW_UNORDERED_ACCESS}, d3d12.RESOURCE_STATE_COMMON,
    )

    params: [Light_Cluster_Root_Slot]d3d12.ROOT_PARAMETER
    params[.Frame_Constants].ParameterType = .CBV
    params[.Frame_Constants].Descriptor = {ShaderRegister = 4}
    params[.Lights].ParameterType = .SRV
    params[.Lights].Descriptor = {ShaderRegister = 18}
    params[.Clusters].ParameterType = .UAV
    params[.Clusters].Descriptor = {ShaderRegister = 0}
    rs_desc := d3d12.ROOT_SIGNATURE_DESC{NumParameters = len(params), pParameters = &params[Light_Cluster_Root_Slot(0)]}
    r.cluster_root_signature = create_root_signature(&rs_desc, "Light cluster")
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
    cs := renderer_compile_shader("shaders/scene.hlsl", "CSBuildLightClusters", "cs")
    defer cs->Release()
    if renderer_skip_pipeline() do return
    desc := d3d12.COMPUTE_PIPELINE_STATE_DESC{pRootSignature = r.cluster_root_signature, CS = shader_bytecode(cs)}
    renderer_check_pipeline(r.device->CreateComputePipelineState(&desc, d3d12.IPipelineState_UUID, (^rawptr)(&r.cluster_pipeline_state)))
}

// ---------------------------------------------------------------------------
// Area lights' shading uses linearly transformed cosines (Heitz, Dupuy, Hill
// and Neubelt, "Real-Time Polygonal-Light Shading with Linearly Transformed
// Cosines", 2016). For each roughness and view angle, a 3x3 matrix M turns a
// clamped cosine into a lobe close to GGX's (times the cosine). Its inverse
// turns a light's polygon back into cosine space, where the integral over the
// polygon has a closed form (scene.hlsl, LtcIntegrate). The table holds those
// inverses, fitted here once (a port of Heitz's fitLTC) and cached on disk:
//   texel (roughness, sqrt(1 - cos view angle)) of LTC_SIZE x LTC_SIZE;
//   table 0: the inverse matrix's four varying entries, normalized so the
//     middle one is 1;
//   table 1: the lobe's magnitude (GGX's directional albedo) and its
//     Schlick-weighted part, for Fresnel: F0 * x + (1 - F0) * y.
LTC_SIZE :: 64
// Samples per axis for each error and average (32 x 32, by Heitz's code).
LTC_SAMPLES :: 32
LTC_MIN_ALPHA :: f32(0.00001)
LTC_CACHE_PATH :: "cache/ltc_ggx.bin"
LTC_CACHE_MAGIC :: u32(0x4C544331) // "LTC1"

@(private="file")
Ltc :: struct {
    magnitude, fresnel: f32,
    m11, m22, m13: f32,
    x, y, z: [3]f32,
    m, inverse_m: matrix[3, 3]f32,
    determinant: f32,
}

// M = [x y z] * [[m11 0 m13] [0 m22 0] [0 0 1]]: the lobe's frame, then its
// stretch and skew.
@(private="file")
ltc_update :: proc(l: ^Ltc) {
    basis := matrix[3, 3]f32{
        l.x.x, l.y.x, l.z.x,
        l.x.y, l.y.y, l.z.y,
        l.x.z, l.y.z, l.z.z,
    }
    stretch := matrix[3, 3]f32{
        l.m11, 0, l.m13,
        0, l.m22, 0,
        0, 0, 1,
    }
    l.m = basis * stretch
    l.inverse_m = linalg.inverse(l.m)
    l.determinant = abs(linalg.determinant(l.m))
}

// The lobe's value toward L: the cosine distribution brought through M^-1,
// times the change of solid angle.
@(private="file")
ltc_eval :: proc(l: ^Ltc, L: [3]f32) -> f32 {
    original := linalg.normalize(l.inverse_m * L)
    transformed := l.m * original
    length := linalg.length(transformed)
    jacobian := l.determinant / (length * length * length)
    d := max(original.z, 0) / math.PI
    return l.magnitude * d / jacobian
}

@(private="file")
ltc_sample :: proc(l: ^Ltc, u1, u2: f32) -> [3]f32 {
    theta := math.acos(math.sqrt(u1))
    phi := 2 * math.PI * u2
    return linalg.normalize(l.m * [3]f32{math.sin(theta) * math.cos(phi), math.sin(theta) * math.sin(phi), math.cos(theta)})
}

// Smith's Lambda for GGX.
@(private="file")
ggx_lambda :: proc(alpha, cos_theta: f32) -> f32 {
    if cos_theta >= 1 do return 0
    tan_theta := math.sqrt(max(1 - cos_theta * cos_theta, 0)) / cos_theta
    a := 1 / (alpha * tan_theta)
    return 0.5 * (-1 + math.sqrt(1 + 1 / (a * a)))
}

// GGX times the cosine toward L (with V and L in the frame where the normal
// is +Z), and the pdf of ggx_sample choosing L.
@(private="file")
ggx_eval :: proc(V, L: [3]f32, alpha: f32) -> (value, pdf: f32) {
    if V.z <= 0 do return 0, 0
    H := linalg.normalize(V + L)
    if H.z <= 1e-7 do return 0, 0
    g2: f32 = 0
    if L.z > 0 do g2 = 1 / (1 + ggx_lambda(alpha, V.z) + ggx_lambda(alpha, L.z))
    slope_x, slope_y := H.x / H.z, H.y / H.z
    d := 1 / (1 + (slope_x * slope_x + slope_y * slope_y) / (alpha * alpha))
    d = d * d / (math.PI * alpha * alpha * H.z * H.z * H.z * H.z)
    pdf = abs(d * H.z / 4 / linalg.dot(V, H))
    value = d * g2 / 4 / V.z
    return
}

@(private="file")
ggx_sample :: proc(V: [3]f32, alpha, u1, u2: f32) -> [3]f32 {
    phi := 2 * math.PI * u1
    r := alpha * math.sqrt(u2 / (1 - u2))
    N := linalg.normalize([3]f32{r * math.cos(phi), r * math.sin(phi), 1})
    return -V + 2 * N * linalg.dot(N, V)
}

// GGX's directional albedo, its Schlick-weighted part, and its average
// direction (in the plane of V and the normal).
@(private="file")
ltc_average_terms :: proc(V: [3]f32, alpha: f32) -> (norm, fresnel: f32, direction: [3]f32) {
    for j in 0..<LTC_SAMPLES {
        for i in 0..<LTC_SAMPLES {
            u1 := (f32(i) + 0.5) / LTC_SAMPLES
            u2 := (f32(j) + 0.5) / LTC_SAMPLES
            L := ggx_sample(V, alpha, u1, u2)
            value, pdf := ggx_eval(V, L, alpha)
            if pdf <= 0 do continue
            weight := value / pdf
            H := linalg.normalize(V + L)
            norm += weight
            fresnel += weight * math.pow(1 - max(linalg.dot(V, H), 0), 5)
            direction += weight * L
        }
    }
    norm /= LTC_SAMPLES * LTC_SAMPLES
    fresnel /= LTC_SAMPLES * LTC_SAMPLES
    direction.y = 0
    direction = linalg.normalize(direction)
    return
}

// The difference between GGX and the lobe: |a - b|^3, sampled from both and
// weighted by multiple importance sampling.
@(private="file")
ltc_error :: proc(l: ^Ltc, V: [3]f32, alpha: f32) -> f32 {
    error: f64
    for j in 0..<LTC_SAMPLES {
        for i in 0..<LTC_SAMPLES {
            u1 := (f32(i) + 0.5) / LTC_SAMPLES
            u2 := (f32(j) + 0.5) / LTC_SAMPLES
            for from_ltc in ([2]bool{true, false}) {
                L := ltc_sample(l, u1, u2) if from_ltc else ggx_sample(V, alpha, u1, u2)
                value, pdf_ggx := ggx_eval(V, L, alpha)
                value_ltc := ltc_eval(l, L)
                pdf_ltc := value_ltc / l.magnitude
                difference := f64(abs(value - value_ltc))
                pdfs := f64(pdf_ltc + pdf_ggx)
                if pdfs > 0 do error += difference * difference * difference / pdfs
            }
        }
    }
    return f32(error / (LTC_SAMPLES * LTC_SAMPLES))
}

// Sets the lobe's parameters (isotropic: one stretch, no skew).
@(private="file")
ltc_set :: proc(l: ^Ltc, params: [3]f32, isotropic: bool) {
    m11 := max(params[0], 1e-7)
    m22 := max(params[1], 1e-7)
    if isotropic {
        l.m11, l.m22, l.m13 = m11, m11, 0
    } else {
        l.m11, l.m22, l.m13 = m11, m22, params[2]
    }
    ltc_update(l)
}

// Nelder-Mead over (m11, m22, m13), from the lobe's current parameters, as
// Heitz's fit: a simplex of size 0.05, tolerance 1e-5, at most 100 steps.
@(private="file")
ltc_fit :: proc(l: ^Ltc, V: [3]f32, alpha: f32, isotropic: bool) {
    DELTA :: f32(0.05)
    TOLERANCE :: f32(1e-5)
    ITERATIONS :: 100
    objective :: proc(l: ^Ltc, params: [3]f32, V: [3]f32, alpha: f32, isotropic: bool) -> f32 {
        ltc_set(l, params, isotropic)
        return ltc_error(l, V, alpha)
    }
    points: [4][3]f32
    values: [4]f32
    points[0] = {l.m11, l.m22, l.m13}
    for i in 1..<4 {
        points[i] = points[0]
        points[i][i - 1] += DELTA
    }
    for i in 0..<4 do values[i] = objective(l, points[i], V, alpha, isotropic)
    lo := 0
    for _ in 0..<ITERATIONS {
        lo = 0
        hi, nh := 0, 0
        for i in 1..<4 {
            if values[i] < values[lo] do lo = i
            if values[i] > values[hi] {
                nh = hi
                hi = i
            } else if values[i] > values[nh] {
                nh = i
            }
        }
        a, b := abs(values[lo]), abs(values[hi])
        if 2 * abs(a - b) < (a + b) * TOLERANCE do break
        // The centroid of all but the worst point.
        o: [3]f32
        for i in 0..<4 do if i != hi do o += points[i]
        o /= 3
        reflected := o + (o - points[hi])
        reflected_value := objective(l, reflected, V, alpha, isotropic)
        if reflected_value < values[nh] {
            if reflected_value < values[lo] {
                expanded := o + 2 * (o - points[hi])
                expanded_value := objective(l, expanded, V, alpha, isotropic)
                if expanded_value < reflected_value {
                    points[hi], values[hi] = expanded, expanded_value
                    continue
                }
            }
            points[hi], values[hi] = reflected, reflected_value
            continue
        }
        contracted := o - 0.5 * (o - points[hi])
        contracted_value := objective(l, contracted, V, alpha, isotropic)
        if contracted_value < values[hi] {
            points[hi], values[hi] = contracted, contracted_value
            continue
        }
        for k in 0..<4 {
            if k == lo do continue
            points[k] = points[lo] + 0.5 * (points[k] - points[lo])
            values[k] = objective(l, points[k], V, alpha, isotropic)
        }
    }
    ltc_set(l, points[lo], isotropic)
}

// The view direction and alpha for table entry (roughness a, angle t), with
// the angle parameterized by sqrt(1 - cos), as the shader looks it up.
@(private="file")
ltc_entry_inputs :: proc(a, t: int) -> (V: [3]f32, alpha: f32) {
    x := f32(t) / (LTC_SIZE - 1)
    theta := min(f32(1.57), math.acos(1 - x * x))
    roughness := f32(a) / (LTC_SIZE - 1)
    return {math.sin(theta), 0, math.cos(theta)}, max(roughness * roughness, LTC_MIN_ALPHA)
}

LtcFit :: struct {
    matrices: []matrix[3, 3]f32,
    magnitude_fresnel: [][2]f32,
}

// Fits row a (one roughness) from its first entry, already fitted: each next
// view angle starts from the previous one's lobe, turned to GGX's average
// direction.
@(private="file")
ltc_fit_row :: proc(fit: ^LtcFit, a: int) {
    l: Ltc
    first := fit.matrices[a]
    l.m11, l.m22, l.m13 = first[0, 0], first[1, 1], 0
    for t in 1..<LTC_SIZE {
        V, alpha := ltc_entry_inputs(a, t)
        average: [3]f32
        l.magnitude, l.fresnel, average = ltc_average_terms(V, alpha)
        l.x, l.y, l.z = {average.z, 0, -average.x}, {0, 1, 0}, average
        ltc_update(&l)
        ltc_fit(&l, V, alpha, isotropic = false)
        ltc_store(fit, a, t, &l)
    }
}

@(private="file")
ltc_store :: proc(fit: ^LtcFit, a, t: int, l: ^Ltc) {
    m := l.m
    // Terms an isotropic lobe in this frame never has.
    m[0, 1], m[1, 0], m[1, 2], m[2, 1] = 0, 0, 0, 0
    fit.matrices[a + t * LTC_SIZE] = m
    fit.magnitude_fresnel[a + t * LTC_SIZE] = {l.magnitude, l.fresnel}
}

// The whole fit: the first entry of every row in turn (looking straight
// down, the lobe is round, each seeded by the next rougher row), then the
// rows on worker threads.
ltc_fit_table :: proc() -> (fit: LtcFit) {
    fit.matrices = make([]matrix[3, 3]f32, LTC_SIZE * LTC_SIZE)
    fit.magnitude_fresnel = make([][2]f32, LTC_SIZE * LTC_SIZE)
    for a := LTC_SIZE - 1; a >= 0; a -= 1 {
        l: Ltc
        V, alpha := ltc_entry_inputs(a, 0)
        average: [3]f32
        l.magnitude, l.fresnel, average = ltc_average_terms(V, alpha)
        l.x, l.y, l.z = {1, 0, 0}, {0, 1, 0}, {0, 0, 1}
        if a == LTC_SIZE - 1 {
            l.m11, l.m22 = 1, 1
        } else {
            previous := fit.matrices[a + 1]
            l.m11, l.m22 = previous[0, 0], previous[1, 1]
        }
        l.m13 = 0
        ltc_update(&l)
        ltc_fit(&l, V, alpha, isotropic = true)
        ltc_store(&fit, a, 0, &l)
    }
    Job :: struct {fit: ^LtcFit, first, step: int}
    worker :: proc(job: Job) {
        for a := job.first; a < LTC_SIZE; a += job.step do ltc_fit_row(job.fit, a)
    }
    count := clamp(os.get_processor_core_count(), 1, LTC_SIZE)
    threads := make([]^thread.Thread, count, context.temp_allocator)
    for &t, i in threads do t = thread.create_and_start_with_poly_data(Job{&fit, i, count}, worker)
    thread.join_multiple(..threads)
    for t in threads do thread.destroy(t)
    return
}

// The two tables as RGBA floats, from the cache when it holds them, otherwise
// fitted (a few seconds on the first start) and cached.
ltc_tables :: proc() -> (tables: [2][]f32) {
    texels := LTC_SIZE * LTC_SIZE
    tables = {make([]f32, texels * 4), make([]f32, texels * 4)}
    if data, error := os.read_entire_file(LTC_CACHE_PATH, context.temp_allocator); error == nil &&
       len(data) == 4 + 2 * texels * 4 * size_of(f32) && (^u32)(raw_data(data))^ == LTC_CACHE_MAGIC {
        floats := ([^]f32)(raw_data(data)[4:])
        copy(tables[0], floats[:texels * 4])
        copy(tables[1], floats[texels * 4:texels * 8])
        return
    }
    fit := ltc_fit_table()
    defer delete(fit.matrices)
    defer delete(fit.magnitude_fresnel)
    for i in 0..<texels {
        inverse := linalg.inverse(fit.matrices[i])
        // Normalized so the middle entry is 1.
        scale := 1 / inverse[1, 1]
        tables[0][i * 4 + 0] = inverse[0, 0] * scale
        tables[0][i * 4 + 1] = inverse[2, 0] * scale
        tables[0][i * 4 + 2] = inverse[0, 2] * scale
        tables[0][i * 4 + 3] = inverse[2, 2] * scale
        tables[1][i * 4 + 0] = fit.magnitude_fresnel[i][0]
        tables[1][i * 4 + 1] = fit.magnitude_fresnel[i][1]
    }
    os.make_directory_all("cache")
    out := make([dynamic]u8, context.temp_allocator)
    magic := LTC_CACHE_MAGIC
    append(&out, ..mem.ptr_to_bytes(&magic))
    append(&out, ..slice.to_bytes(tables[0]))
    append(&out, ..slice.to_bytes(tables[1]))
    _ = os.write_entire_file(LTC_CACHE_PATH, out[:])
    return
}

// Uploads the two tables into consecutive SRVs (r.ltc_srv_start), which the
// shaders reach through the bindless texture array.
renderer_create_ltc_tables :: proc() {
    r := &g_renderer
    tables := ltc_tables()
    defer for table in tables do delete(table)
    r.ltc_srv_start = renderer_alloc_srv(2)
    for table, i in tables {
        data := environment_encode(table, LTC_SIZE, LTC_SIZE, .R32G32B32A32_FLOAT)
        defer texture_data_destroy(&data)
        gpu := GpuTexture{srv_index = r.ltc_srv_start + u32(i)}
        if renderer_upload_texture(&gpu, data) < 0 do panic("Could not upload the LTC tables.")
        r.ltc_textures[i] = gpu.resource
    }
}
