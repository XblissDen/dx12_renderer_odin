// Project-local C API: keep ImGui's C++ types out of the Odin ABI.
#include "imgui.h"
#include "imgui_impl_dx12.h"
#include "imgui_impl_win32.h"

#include <array>
#include <cstdint>
#include <windows.h>

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

namespace {
constexpr unsigned descriptor_count = 64;
struct UiState {
    ID3D12DescriptorHeap* srv_heap = nullptr;
    unsigned descriptor_size = 0;
    std::array<bool, descriptor_count> allocated{};
    bool initialized = false;
    bool frame_started = false;
};
UiState state;

void allocate_descriptor(ImGui_ImplDX12_InitInfo*,
                         D3D12_CPU_DESCRIPTOR_HANDLE* cpu,
                         D3D12_GPU_DESCRIPTOR_HANDLE* gpu) {
    for (unsigned i = 0; i < descriptor_count; ++i) {
        if (state.allocated[i])
            continue;
        state.allocated[i] = true;
        *cpu = state.srv_heap->GetCPUDescriptorHandleForHeapStart();
        *gpu = state.srv_heap->GetGPUDescriptorHandleForHeapStart();
        cpu->ptr += SIZE_T(i) * state.descriptor_size;
        gpu->ptr += UINT64(i) * state.descriptor_size;
        return;
    }
    IM_ASSERT(false && "ImGui SRV heap exhausted");
    *cpu = {};
    *gpu = {};
}

void free_descriptor(ImGui_ImplDX12_InitInfo*,
                     D3D12_CPU_DESCRIPTOR_HANDLE cpu,
                     D3D12_GPU_DESCRIPTOR_HANDLE) {
    const auto start = state.srv_heap->GetCPUDescriptorHandleForHeapStart();
    const auto index = (cpu.ptr - start.ptr) / state.descriptor_size;
    IM_ASSERT(index < descriptor_count && state.allocated[index]);
    state.allocated[index] = false;
}
} // namespace

extern "C" {
std::int32_t dx12_ui_init(void* hwnd, void* device_ptr, void* queue_ptr,
                          std::int32_t frames_in_flight) {
    auto* device = static_cast<ID3D12Device*>(device_ptr);
    auto* queue = static_cast<ID3D12CommandQueue*>(queue_ptr);
    if (!hwnd || !device || !queue || state.initialized)
        return E_INVALIDARG;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    auto& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_DockingEnable;
    // Cursor visibility and confinement remain controlled by the L key.
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    ImGui::StyleColorsDark();

    D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {};
    heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    heap_desc.NumDescriptors = descriptor_count;
    heap_desc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    HRESULT hr = device->CreateDescriptorHeap(&heap_desc, IID_PPV_ARGS(&state.srv_heap));
    if (FAILED(hr)) {
        ImGui::DestroyContext();
        return hr;
    }
    state.descriptor_size = device->GetDescriptorHandleIncrementSize(heap_desc.Type);
    if (!ImGui_ImplWin32_Init(static_cast<HWND>(hwnd))) {
        state.srv_heap->Release();
        state = {};
        ImGui::DestroyContext();
        return E_FAIL;
    }

    ImGui_ImplDX12_InitInfo info = {};
    info.Device = device;
    info.CommandQueue = queue;
    info.NumFramesInFlight = frames_in_flight;
    info.RTVFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
    info.DSVFormat = DXGI_FORMAT_UNKNOWN;
    info.SrvDescriptorHeap = state.srv_heap;
    info.SrvDescriptorAllocFn = allocate_descriptor;
    info.SrvDescriptorFreeFn = free_descriptor;
    if (!ImGui_ImplDX12_Init(&info)) {
        ImGui_ImplWin32_Shutdown();
        state.srv_heap->Release();
        state = {};
        ImGui::DestroyContext();
        return E_FAIL;
    }
    state.initialized = true;
    return S_OK;
}

void dx12_ui_shutdown() {
    if (!state.initialized)
        return;
    if (state.frame_started)
        ImGui::EndFrame();
    ImGui_ImplDX12_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    state.srv_heap->Release();
    state = {};
}

bool dx12_ui_handle_message(void* hwnd, std::uint32_t message,
                            std::uintptr_t wparam, std::intptr_t lparam) {
    if (!state.initialized)
        return false;
    return ImGui_ImplWin32_WndProcHandler(static_cast<HWND>(hwnd), message,
                                         WPARAM(wparam), LPARAM(lparam)) != 0;
}

bool dx12_ui_wants_keyboard() {
    return state.initialized && ImGui::GetIO().WantCaptureKeyboard;
}

void dx12_ui_begin_frame(bool cursor_locked) {
    if (!state.initialized)
        return;
    auto& io = ImGui::GetIO();
    const auto camera_input_flags = ImGuiConfigFlags_NoMouse | ImGuiConfigFlags_NoKeyboard;
    if (cursor_locked)
        io.ConfigFlags |= camera_input_flags;
    else
        io.ConfigFlags &= ~camera_input_flags;
    ImGui_ImplDX12_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    state.frame_started = true;
}

void dx12_ui_next_window(float x, float y, float width, float height) {
    ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(width, height), ImGuiCond_FirstUseEver);
}

bool dx12_ui_begin_panel(const char* title) { return ImGui::Begin(title); }
void dx12_ui_end_panel() { ImGui::End(); }
void dx12_ui_text(const char* text, std::size_t length) {
    if (length != 0)
        ImGui::TextUnformatted(text, text + length);
}
void dx12_ui_text_wrapped(const char* text, std::size_t length) {
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(text, text + length);
    ImGui::PopTextWrapPos();
}
void dx12_ui_separator() { ImGui::Separator(); }
bool dx12_ui_slider_float(const char* label, float* value, float minimum, float maximum) {
    return ImGui::SliderFloat(label, value, minimum, maximum, "%.2f");
}
bool dx12_ui_selectable(const char* label, bool selected) {
    return ImGui::Selectable(label, selected);
}

bool dx12_ui_drag_float3(const char* label, float* values, float speed) {
    return ImGui::DragFloat3(label, values, speed);
}

bool dx12_ui_drag_float(
    const char* label,
    float* value,
    float speed,
    float minimum,
    float maximum
) {
    ImGuiSliderFlags flags = minimum < maximum
        ? ImGuiSliderFlags_AlwaysClamp
        : ImGuiSliderFlags_None;

    return ImGui::DragFloat(
        label, value, speed, minimum, maximum, "%.2f", flags
    );
}

void dx12_ui_push_id(std::int32_t id) {
    ImGui::PushID(id);
}

void dx12_ui_pop_id() {
    ImGui::PopID();
}
bool dx12_ui_checkbox(const char* label, bool* value) {
    return ImGui::Checkbox(label, value);
}
bool dx12_ui_begin_table(const char* label) {
    return ImGui::BeginTable(label, 2, ImGuiTableFlags_RowBg);
}
bool dx12_ui_color_edit3(const char* label, float* values) {
    return ImGui::ColorEdit3(label, values, ImGuiColorEditFlags_Float);
}
void dx12_ui_table_column(const char* label) { ImGui::TableSetupColumn(label); }
void dx12_ui_table_headers() { ImGui::TableHeadersRow(); }
void dx12_ui_table_row() { ImGui::TableNextRow(); }
void dx12_ui_table_next_column() { ImGui::TableNextColumn(); }
void dx12_ui_end_table() { ImGui::EndTable(); }
void dx12_ui_show_demo(bool* open) { ImGui::ShowDemoWindow(open); }

void dx12_ui_render(void* command_list_ptr) {
    if (!state.initialized || !state.frame_started)
        return;
    ImGui::Render();
    state.frame_started = false;
    auto* command_list = static_cast<ID3D12GraphicsCommandList*>(command_list_ptr);
    command_list->SetDescriptorHeaps(1, &state.srv_heap);
    ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(), command_list);
}

void dx12_ui_begin_disabled(bool disabled) {
    ImGui::BeginDisabled(disabled);
}

void dx12_ui_end_disabled() {
    ImGui::EndDisabled();
}

bool dx12_ui_button(const char* label) {
    return ImGui::Button(label);
}

bool dx12_ui_item_activated() {
    return ImGui::IsItemActivated();
}

bool dx12_ui_item_deactivated() {
    return ImGui::IsItemDeactivated();
}

bool dx12_ui_any_item_active() {
    return ImGui::IsAnyItemActive();
}

bool dx12_ui_scene_left_click(float* x, float* y) {
    if (!state.initialized || !state.frame_started)
        return false;

    const auto& io = ImGui::GetIO();
    if (io.WantCaptureMouse || !ImGui::IsMouseClicked(ImGuiMouseButton_Left))
        return false;

    *x = io.MousePos.x;
    *y = io.MousePos.y;
    return true;
}

// Mirrors SceneMouse in debug_ui.odin.
struct SceneMouse {
    float x, y;
    bool over_ui;  // ImGui wants the mouse (hovering or using a window)
    bool down;     // left button held
    bool clicked;  // left button pressed this frame
    bool released; // left button released this frame
    bool cancel;   // right button pressed this frame
};

void dx12_ui_scene_mouse(SceneMouse* out) {
    *out = {};
    if (!state.initialized || !state.frame_started)
        return;
    const auto& io = ImGui::GetIO();
    out->x = io.MousePos.x;
    out->y = io.MousePos.y;
    out->over_ui = io.WantCaptureMouse;
    out->down = ImGui::IsMouseDown(ImGuiMouseButton_Left);
    out->clicked = ImGui::IsMouseClicked(ImGuiMouseButton_Left);
    out->released = ImGui::IsMouseReleased(ImGuiMouseButton_Left);
    out->cancel = ImGui::IsMouseClicked(ImGuiMouseButton_Right);
}

// Viewport overlays use the background list: above the 3D scene, below panels.
void dx12_ui_draw_line(float x0, float y0, float x1, float y1,
                       std::uint32_t color, float thickness) {
    ImGui::GetBackgroundDrawList()->AddLine(ImVec2(x0, y0), ImVec2(x1, y1), color, thickness);
}

void dx12_ui_draw_triangle(float x0, float y0, float x1, float y1,
                           float x2, float y2, std::uint32_t color) {
    ImGui::GetBackgroundDrawList()->AddTriangleFilled(
        ImVec2(x0, y0), ImVec2(x1, y1), ImVec2(x2, y2), color);
}

void dx12_ui_draw_rect(float x0, float y0, float x1, float y1, std::uint32_t color) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), color);
}

bool dx12_ui_radio_button(const char* label, bool active) {
    return ImGui::RadioButton(label, active);
}

void dx12_ui_same_line() { ImGui::SameLine(); }

bool dx12_ui_combo(const char* label, std::int32_t* selected,
                   const char* const* items, std::int32_t count) {
    return ImGui::Combo(label, selected, items, count);
}

bool dx12_ui_begin_combo(const char* label, const char* preview) {
    return ImGui::BeginCombo(label, preview);
}
void dx12_ui_end_combo() { ImGui::EndCombo(); }

bool dx12_ui_input_text(const char* label, char* buffer, std::size_t capacity) {
    return ImGui::InputText(label, buffer, capacity);
}

// A row of the entity tree: indented by depth, with an arrow that toggles
// *open when the row has children, then a selectable label. Returns whether
// the label was clicked.
bool dx12_ui_tree_row(const char* label, bool selected, std::int32_t depth, bool has_children, bool* open) {
    float indent = float(depth) * ImGui::GetStyle().IndentSpacing;
    if (indent > 0)
        ImGui::Indent(indent);
    if (has_children) {
        ImGui::PushID(label);
        if (ImGui::ArrowButton("##open", *open ? ImGuiDir_Down : ImGuiDir_Right))
            *open = !*open;
        ImGui::PopID();
    } else {
        ImGui::Dummy(ImVec2(ImGui::GetFrameHeight(), ImGui::GetFrameHeight()));
    }
    ImGui::SameLine();
    bool pressed = ImGui::Selectable(label, selected);
    if (indent > 0)
        ImGui::Unindent(indent);
    return pressed;
}

// Lets the last item be dragged, carrying an entity index.
void dx12_ui_drag_entity(std::int32_t entity, const char* label) {
    if (ImGui::BeginDragDropSource()) {
        ImGui::SetDragDropPayload("ENTITY", &entity, sizeof(entity));
        ImGui::TextUnformatted(label);
        ImGui::EndDragDropSource();
    }
}

// Whether an entity was dropped on the last item, and which.
bool dx12_ui_drop_entity(std::int32_t* entity) {
    bool dropped = false;
    if (ImGui::BeginDragDropTarget()) {
        if (const ImGuiPayload* payload = ImGui::AcceptDragDropPayload("ENTITY")) {
            *entity = *static_cast<const std::int32_t*>(payload->Data);
            dropped = true;
        }
        ImGui::EndDragDropTarget();
    }
    return dropped;
}

} // extern "C"
