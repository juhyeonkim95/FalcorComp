add_plugin(DopplerToFPathTracerInline)

target_sources(DopplerToFPathTracerInline PRIVATE
    DopplerToFPathTracerInline.cpp
    DopplerToFPathTracerInline.h
    DopplerToFPathTracerInline.cs.slang
)

target_copy_shaders(DopplerToFPathTracerInline RenderPasses/DopplerToFPathTracerInline)

target_source_group(DopplerToFPathTracerInline "RenderPasses")

add_dependencies(DopplerToFPathTracerInline RenderPassSharedShaders)
