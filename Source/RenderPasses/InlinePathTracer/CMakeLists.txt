add_plugin(InlinePathTracer)

target_sources(InlinePathTracer PRIVATE
    InlinePathTracer.cpp
    InlinePathTracer.h
    InlinePathTracer.cs.slang
)

target_copy_shaders(InlinePathTracer RenderPasses/InlinePathTracer)

target_source_group(InlinePathTracer "RenderPasses")

add_dependencies(InlinePathTracer RenderPassSharedShaders)
