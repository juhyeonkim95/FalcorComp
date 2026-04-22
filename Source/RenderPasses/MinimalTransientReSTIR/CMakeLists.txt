add_plugin(MinimalTransientReSTIR)

target_sources(MinimalTransientReSTIR PRIVATE
    MinimalTransientReSTIR.cpp
    MinimalTransientReSTIR.h
    MinimalTransientReSTIR.cs.slang
    ReflectTypes.cs.slang
    Reservoirs.slang
    LoadShadingData.slang
    SpatialReuse.cs.slang
    LaserLightSampler.slang
)

target_copy_shaders(MinimalTransientReSTIR RenderPasses/MinimalTransientReSTIR)

target_source_group(MinimalTransientReSTIR "RenderPasses")
