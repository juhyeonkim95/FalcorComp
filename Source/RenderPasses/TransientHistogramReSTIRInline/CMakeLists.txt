add_plugin(TransientHistogramReSTIRInline)

target_sources(TransientHistogramReSTIRInline PRIVATE
    TransientHistogramReSTIRInline.cpp
    TransientHistogramReSTIRInline.h
    HistogramReSTIRCommon.slangh
    InitialSampleGeneration.cs.slang
    TemporalReuse.cs.slang
    TemporalReusePairs.cs.slang
    SpatialReuse.cs.slang
    SpatialReusePairs.cs.slang
)

target_copy_shaders(TransientHistogramReSTIRInline RenderPasses/TransientHistogramReSTIRInline)

target_source_group(TransientHistogramReSTIRInline "RenderPasses")

add_dependencies(TransientHistogramReSTIRInline RenderPassSharedShaders)
