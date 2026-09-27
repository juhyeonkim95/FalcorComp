add_plugin(TimeGatedReSTIRInline)

target_sources(TimeGatedReSTIRInline PRIVATE
    TimeGatedReSTIRInline.cpp
    TimeGatedReSTIRInline.h
    InitialSampleGeneration.cs.slang
    SpatialReuse.cs.slang
    AddDirect.cs.slang
)

target_copy_shaders(TimeGatedReSTIRInline RenderPasses/TimeGatedReSTIRInline)

target_source_group(TimeGatedReSTIRInline "RenderPasses")

add_dependencies(TimeGatedReSTIRInline RenderPassSharedShaders)
