add_plugin(MinimalTimeGatedPathTracer)

target_sources(MinimalTimeGatedPathTracer PRIVATE
    MinimalTimeGatedPathTracer.cpp
    MinimalTimeGatedPathTracer.h
    MinimalTimeGatedPathTracer.cs.slang
)

target_copy_shaders(MinimalTimeGatedPathTracer RenderPasses/MinimalTimeGatedPathTracer)

target_source_group(MinimalTimeGatedPathTracer "RenderPasses")
