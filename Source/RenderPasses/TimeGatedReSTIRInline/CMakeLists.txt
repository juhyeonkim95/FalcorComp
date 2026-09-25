add_plugin(TimeGatedReSTIRInline)

target_sources(TimeGatedReSTIRInline PRIVATE
    TimeGatedReSTIRInline.cpp
    TimeGatedReSTIRInline.h
    InitialSampleGeneration.cs.slang
    ReflectTypes.cs.slang
    SpatialReuse.cs.slang
)

target_copy_shaders(TimeGatedReSTIRInline RenderPasses/TimeGatedReSTIRInline)

target_source_group(TimeGatedReSTIRInline "RenderPasses")

add_dependencies(TimeGatedReSTIRInline RenderPassSharedShaders)
