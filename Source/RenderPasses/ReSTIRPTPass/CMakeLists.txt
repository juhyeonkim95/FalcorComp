add_plugin(ReSTIRPTPass)

target_sources(ReSTIRPTPass PRIVATE
    ComputePathReuseMISWeights.cs.slang
    GeneratePaths.cs.slang
    LoadShadingData.slang
    Params.slang
    PathBuilder.slang
    PathReservoir.slang
    PathState.slang
    PathTracer.slang
    ReflectTypes.cs.slang
    ReSTIRPTPass.cpp
    ReSTIRPTPass.h
    Shift.slang
    SpatialPathRetrace.cs.slang
    SpatialReuse.cs.slang
    StaticParams.slang
    TemporalPathRetrace.cs.slang
    TemporalReuse.cs.slang
    TracePass.cs.slang
)

target_copy_shaders(ReSTIRPTPass RenderPasses/ReSTIRPTPass)

target_source_group(ReSTIRPTPass "RenderPasses")
