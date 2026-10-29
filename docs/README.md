# How it works

These pages explain how each part of the renderer and editor works: what it
does, in what order, and why it is built that way. The [project
README](../README.md) covers building and running.

- [Frame structure](frame.md): the main loop, frames in flight, the order of
  GPU passes, per-frame data, culling, the depth prepass, the root signature,
  GPU timings, and shader hot-reload.
- [Lighting](lighting.md): surface shading, materials, the sun, point and spot
  lights, clustered lighting, shadows, image-based lighting and the sky,
  volumetric fog, SSAO, and screen-space reflections.
- [Post-processing](post_processing.md): TAA and sharpening, FXAA, auto
  exposure, bloom, and tone mapping.
- [Assets](assets.md): the asset catalog, OBJ and glTF import, materials,
  textures and their mips, environments, and removing assets.
- [Editor](editor.md): the UI, camera and shortcuts, picking and selection,
  gizmos, undo and redo, lights, and scene files.

## Conventions

- **Space**: left-handed, +Y up. glTF and OBJ files (right-handed) are converted on import by negating Z and
  reversing triangle winding, so models are not mirrored.
- **Matrices**: row vectors (`mul(v, M)` in HLSL), so transforms compose left
  to right: `model * view * projection`.
- **Winding**: front faces are clockwise, D3D's default; back faces are culled
  unless a material is double-sided.
- **Depth**: standard (not reversed), cleared to 1, tested `LESS`.
- **Units**: one unit is a metre, roughly. Light intensities and the HDR image
  are linear radiance; exposure and tone mapping happen only at the end.
- **Colors**: albedo and emissive textures are sRGB and read through `_SRGB`
  views, so shaders get linear values; normal, roughness, metallic and
  occlusion maps are linear data.

## Source map

| File | What it holds |
| --- | --- |
| `src/main.odin` | Startup order and the main loop |
| `src/window.odin` | Win32 window, input, cursor capture, file dialogs |
| `src/renderer.odin` | Device, swap chain, root signature, pipelines, hot-reload, frame pass order, resize, shutdown |
| `src/renderer_frames.odin` | Frames in flight, upload buffers, GPU timestamps |
| `src/renderer_frame_data.odin` | Per-frame draws, culling, constants, light buffer, TAA jitter |
| `src/renderer_scene_pass.odin` | Sky, lit opaque and blended passes; tone mapping, FXAA/sharpen, UI |
| `src/renderer_shadow.odin` | Sun cascades, spot and point light shadow maps |
| `src/renderer_ssao.odin` | Depth prepass and SSAO |
| `src/renderer_ssr.odin` | Screen-space reflections |
| `src/renderer_lights.odin` | Clustered lighting |
| `src/renderer_fog.odin` | Volumetric fog |
| `src/renderer_taa.odin` | TAA targets and resolve |
| `src/renderer_post.odin` | HDR/LDR targets, bloom, auto exposure |
| `src/renderer_environment.odin` | HDR panoramas, sun extraction, IBL baking |
| `src/renderer_selection.odin` | Selection box |
| `src/texture_mips.odin` | GPU mip generation |
| `src/assets.odin`, `src/gltf.odin`, `src/mesh.odin` | Asset catalog, glTF and OBJ loading |
| `src/scene.odin`, `src/scene_file.odin` | Entities and components; saving and loading scenes |
| `src/camera.odin`, `src/frustum.odin` | Fly camera; frustum culling |
| `src/editor*.odin`, `src/debug_ui.odin` | Panels, picking, gizmos, undo history |
| `shaders/scene.hlsl` | Mesh shading, prepass, shadows, SSAO, SSR, light clusters, fog |
| `shaders/post_process.hlsl` | Full-screen triangle, bloom, TAA, tone mapping, FXAA, sharpening |
| `shaders/auto_exposure.hlsl` | Luminance histogram and exposure adaptation |
| `shaders/sky.hlsl`, `irradiance.hlsl`, `environment_prefilter.hlsl` | Sky and IBL baking |
| `shaders/texture_mips.hlsl`, `selection.hlsl` | Mip generation; selection box |
