add_plugin(MinimalFrequencyGatedPathTracer)

target_sources(MinimalFrequencyGatedPathTracer PRIVATE
    MinimalFrequencyGatedPathTracer.cpp
    MinimalFrequencyGatedPathTracer.h
    MinimalFrequencyGatedPathTracer.cs.slang
)

target_copy_shaders(MinimalFrequencyGatedPathTracer RenderPasses/MinimalFrequencyGatedPathTracer)

target_source_group(MinimalFrequencyGatedPathTracer "RenderPasses")
