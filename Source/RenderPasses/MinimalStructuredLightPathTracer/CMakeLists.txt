add_plugin(MinimalStructuredLightPathTracer)

target_sources(MinimalStructuredLightPathTracer PRIVATE
    MinimalStructuredLightPathTracer.cpp
    MinimalStructuredLightPathTracer.h
    MinimalStructuredLightPathTracer.cs.slang
    ProjectorLight.slang
    ProjectorPatterns/ProjectorPatternInterface.slang
    ProjectorPatterns/PeriodicPattern.slang
    ProjectorPatterns/XORPattern.slang
    ProjectorPatterns/GrayPattern.slang
    ProjectorPatterns/ArbitraryAntitheticPattern.slang
    ProjectorPatterns/CheckerboardPattern.slang
)

target_copy_shaders(MinimalStructuredLightPathTracer RenderPasses/MinimalStructuredLightPathTracer)
target_source_group(MinimalStructuredLightPathTracer "RenderPasses")
