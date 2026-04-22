add_plugin(TransientRenderPass)

target_sources(TransientRenderPass PRIVATE
    TransientRenderPass.cpp
    TransientRenderPass.h

    MinimalTransientPathTracer/MinimalTransientPathTracer.cpp
    MinimalTransientPathTracer/MinimalTransientPathTracer.h
    MinimalTransientPathTracer/MinimalTransientPathTracer.rt.slang
    MinimalTransientPathTracer/EllipsoidIntersection.slang
)

target_copy_shaders(TransientRenderPass RenderPasses/TransientRenderPass)

target_source_group(TransientRenderPass "RenderPasses")
