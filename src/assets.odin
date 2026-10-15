package main

BARREL_TEXTURE_DIR :: "models/barrel_01_2k/textures/"

MESH_PATHS := [MESH_COUNT]string{
    "models/cube.obj",
    "models/pyramid.obj",
    "models/barrel_01_2k/Barrel_01_2k.obj",
}

TEXTURE_PATHS := [TEXTURE_COUNT]string{
    "textures/2.png", // Portrait
    "textures/2.png", // Checkerboard uses this image's dimensions.
    "textures/stone/albedo.png",
    "textures/stone/normal.png",
    "textures/stone/roughness.png",

    BARREL_TEXTURE_DIR + "Barrel_01_explosive_diff_2k.png",
    BARREL_TEXTURE_DIR + "Barrel_01_explosive_nor_gl_2k.png",
    BARREL_TEXTURE_DIR + "Barrel_01_explosive_roughness_2k.png",
    BARREL_TEXTURE_DIR + "Barrel_01_explosive_metallic_2k.png",
}