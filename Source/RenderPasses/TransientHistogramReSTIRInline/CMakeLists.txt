add_plugin(TransientHistogramReSTIRInline)

target_sources(TransientHistogramReSTIRInline PRIVATE
    TransientHistogramReSTIRInline.cpp
    TransientHistogramReSTIRInline.h
    InitialSampleGeneration.cs.slang
    ReflectTypes.cs.slang
    SpatialReuse.cs.slang
    EvaluateFinalSamples.cs.slang
)

target_copy_shaders(TransientHistogramReSTIRInline RenderPasses/TransientHistogramReSTIRInline)

target_source_group(TransientHistogramReSTIRInline "RenderPasses")

add_dependencies(TransientHistogramReSTIRInline RenderPassSharedShaders)
