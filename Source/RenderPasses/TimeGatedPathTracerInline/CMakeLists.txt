add_plugin(TimeGatedPathTracerInline)

target_sources(TimeGatedPathTracerInline PRIVATE
    TimeGatedPathTracerInline.cpp
    TimeGatedPathTracerInline.h
    TimeGatedPathTracerInline.cs.slang
)

target_copy_shaders(TimeGatedPathTracerInline RenderPasses/TimeGatedPathTracerInline)

target_source_group(TimeGatedPathTracerInline "RenderPasses")

add_dependencies(TimeGatedPathTracerInline RenderPassLightShaders)
