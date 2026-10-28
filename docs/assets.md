# Assets

## The catalog

Every model, texture and environment the program can use is listed in
`assets.json`, the asset catalog (`src/assets.odin`). Scenes refer to assets by
catalog ID, never by file path.

- **Models** have an ID, a display name, a file path, import settings (Flip
  V), and default materials: one for OBJ files, one per material slot for
  glTF. New entities start with those materials.
- **Textures** have an ID, a path, and a **usage**: albedo, normal, roughness,
  metallic, emissive, occlusion, or data. The usage decides the color space
  (albedo and emissive are sRGB, the rest linear), how mips are filtered, and
  which material fields accept the texture. Options: invert a normal map's
  green channel, or take one channel of the image as gray (how glTF's packed
  textures are split). A few textures are generated instead of loaded: the
  checkerboard and solid colors such as the flat normal.
- **Environments** are HDR panoramas. `default_environment` picks the one used
  at startup.

At runtime each asset gets a **handle**, an index into the loaded catalog;
handle 0 is invalid. Handles are never reused during a session, so removing an
asset does not shift any others; the catalog is compacted at the next start.

If `assets.json` is missing, startup writes a base catalog with the starter
meshes, textures, and both bundled environments. If the default HDR file is
missing, startup falls back to ambient-color lighting and a solid background.

## Importing models

The **Assets...** panel imports OBJ, glTF 2.0 (`.gltf` with its `.bin` and
images beside it, or a single `.glb`), and PNG/JPEG textures. Imported files
are copied into `models/imported/` or `textures/imported/` and registered in the
catalog.

### OBJ

OBJ files are read as right-handed (+Y up), as Blender and most tools write
them. Z is negated and each face's winding reversed, which converts them to the
renderer's left-handed space without mirroring. **Flip V** (on by default)
matches their bottom-left UV origin. Faces with more than three corners are
split into a fan of triangles.

### glTF

A glTF import copies the model and every file it references into
`models/imported/<id>/`; images embedded in a GLB become files there. It
registers the model and one texture per (image, use) in a single catalog write.
If any step fails, nothing is registered and the folder is removed again.

- **Geometry**: the node hierarchy is flattened into one entity. Node
  transforms are baked into the vertices, and primitives sharing a material
  become one submesh. Positions and normals are converted from right-handed to
  left-handed by negating Z, and triangle winding is reversed, except under a
  mirroring node transform, which already reverses it. Missing normals and
  tangents are generated.
- **Not supported yet**: animation and skinning (the static pose loads), and
  compressed meshes (Draco, meshopt), which are rejected.

## Materials

Each glTF material becomes a **material slot** of the model, which the
Inspector edits one at a time; scenes save every slot.

- **Base color**: texture and factor. The factor's alpha is the opacity of
  blended materials.
- **Metallic-roughness**: glTF packs roughness in the green channel and
  metallic in the blue channel of one texture. It is registered twice, as a
  roughness texture (green) and a metallic texture (blue), each multiplied by
  its factor in the shader.
- **Normal map** with its scale as the normal strength.
- **Occlusion**: the red channel, often of that same packed texture, blended in
  by its strength. It darkens ambient light only, multiplied with SSAO.
- **Emission**: color, strength (`KHR_materials_emissive_strength`), and an
  optional sRGB map, added after lighting.
- **Alpha mode**: opaque, cutout (`MASK`, with its cutoff), or blend; and
  double-sidedness. See [Lighting](lighting.md#materials) for how each is
  drawn.

Models imported before a material feature existed keep the materials stored in
`assets.json`; import them again to pick it up.

## Textures

Textures load at startup and on import.

1. **Decoding**: PNG and JPEG files are decoded on worker threads, one texture
   per core at a time.
2. **Upload**: only the full-size image is uploaded, to a typeless
   `R8G8B8A8` texture; albedo and emissive are read through `_SRGB` views, so
   shaders get linear color.
3. **Mips on the GPU** (`shaders/texture_mips.hlsl`): each level is rendered
   from the one above with a 2 × 2 box filter, in a mode chosen by the usage.
   Color is averaged in linear space and re-encoded to sRGB, with linear alpha.
   Normal maps average directions and renormalize them. Data is averaged as
   is. The shader reads and writes plain UNORM views and does the sRGB
   conversion and rounding itself, since the hardware's are only specified to
   a tolerance and the error would grow level after level. This reproduces the
   CPU filter it replaced.
4. **Alpha for picking**: albedo textures with any transparency keep a
   full-size copy of their alpha channel on the CPU, so picking can see through
   cutout holes. Fully opaque images keep nothing.

With Sponza and the helmets in the catalog (129 textures), loading takes about
1.2 s.

## Environments

HDR panoramas (`.hdr`) are registered in the catalog and chosen in Renderer
controls. Two come with the project, in `textures/environments/`:
`autumn_field_puresky_4k.hdr` (the default) and
`kloofendal_43d_clear_puresky_4k.hdr`. Set `default_environment` in
`assets.json` to another environment ID to change the startup default. A
panorama is loaded only when lighting or the background uses it.
Loading decodes it, finds its sun, uploads it with a mip chain, and bakes the
image-based lighting maps; see [Lighting](lighting.md#image-based-lighting-and-the-sky).

## Removing assets

The Assets panel also removes a model or texture from the catalog, after a
confirmation step.

- **Refused while in use**: by an entity in the scene (for textures, in any
  material slot or map, including disabled maps) or by another model's default
  material. The panel names the user.
- **Dependent textures**: removing a model also removes the textures its import
  registered (`<model id>.…`) that nothing else uses.
- **Files**: `assets.json` is rewritten without them, and their GPU data is
  freed. Files the importer copied are deleted: a glTF model's
  `models/imported/<id>/` folder, or an imported OBJ or texture file. Files
  outside `models/imported/` and `textures/imported/` are the user's own and
  are only unlisted, never deleted.
- **History**: undo history is cleared, since old steps could bring back an
  entity using the asset, and the removal itself cannot be undone. Saved scenes
  that use a removed asset no longer load.
