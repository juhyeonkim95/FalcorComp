add_plugin(MinimalTransientPathTracer)

target_sources(MinimalTransientPathTracer PRIVATE
    MinimalTransientPathTracer.cpp
    MinimalTransientPathTracer.h
    MinimalTransientPathTracer.cs.slang
)

target_copy_shaders(MinimalTransientPathTracer RenderPasses/MinimalTransientPathTracer)

target_source_group(MinimalTransientPathTracer "RenderPasses")
