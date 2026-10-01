add_plugin(DopplerGatedPathTracerInline)

target_sources(DopplerGatedPathTracerInline PRIVATE
    DopplerGatedPathTracerInline.cpp
    DopplerGatedPathTracerInline.h
    DopplerGatedPathTracerInline.cs.slang
)

target_copy_shaders(DopplerGatedPathTracerInline RenderPasses/DopplerGatedPathTracerInline)

target_source_group(DopplerGatedPathTracerInline "RenderPasses")

add_dependencies(DopplerGatedPathTracerInline RenderPassSharedShaders)
