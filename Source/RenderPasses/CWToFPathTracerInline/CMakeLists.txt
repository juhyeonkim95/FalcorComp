add_plugin(CWToFPathTracerInline)

target_sources(CWToFPathTracerInline PRIVATE
    CWToFPathTracerInline.cpp
    CWToFPathTracerInline.h
    CWToFPathTracerInline.cs.slang
)

target_copy_shaders(CWToFPathTracerInline RenderPasses/CWToFPathTracerInline)

target_source_group(CWToFPathTracerInline "RenderPasses")

add_dependencies(CWToFPathTracerInline RenderPassSharedShaders)
