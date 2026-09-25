add_plugin(LaserPositionViewer)

target_sources(LaserPositionViewer PRIVATE
    LaserPositionViewer.cpp
    LaserPositionViewer.h
    LaserPositionViewer.cs.slang
)

target_copy_shaders(LaserPositionViewer RenderPasses/LaserPositionViewer)

add_dependencies(LaserPositionViewer RenderPassSharedShaders)

target_source_group(LaserPositionViewer "RenderPasses")
