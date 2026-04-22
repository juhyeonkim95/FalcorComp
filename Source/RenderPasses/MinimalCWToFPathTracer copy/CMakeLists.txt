add_plugin(MinimalCWToFPathTracer)

target_sources(MinimalCWToFPathTracer PRIVATE
    MinimalCWToFPathTracer.cpp
    MinimalCWToFPathTracer.h
    MinimalCWToFPathTracer.cs.slang
)

target_copy_shaders(MinimalCWToFPathTracer RenderPasses/MinimalCWToFPathTracer)

target_source_group(MinimalCWToFPathTracer "RenderPasses")
