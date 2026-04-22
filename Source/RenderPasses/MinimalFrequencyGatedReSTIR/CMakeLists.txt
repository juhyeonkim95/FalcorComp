add_plugin(MinimalFrequencyGatedReSTIR)

target_sources(MinimalFrequencyGatedReSTIR PRIVATE
    MinimalFrequencyGatedReSTIR.cpp
    MinimalFrequencyGatedReSTIR.h
    MinimalFrequencyGatedReSTIR.cs.slang
    ReflectTypes.cs.slang
    Reservoirs.slang
    TransientShiftmapping.slang
    LoadShadingData.slang
    NewtonSolver.slang
    SurfaceOps/LocalTangentSurface.slang
    SurfaceOps/SurfaceOpsInterface.slang
    SurfaceOps/BarycentricTriSurface.slang
    SurfaceOps/RayTraceHemisphere.slang
    SpatialReuse.cs.slang
    EvaluateFinalSamples.cs.slang
    LaserLightSampler.slang
)

target_copy_shaders(MinimalFrequencyGatedReSTIR RenderPasses/MinimalFrequencyGatedReSTIR)

target_source_group(MinimalFrequencyGatedReSTIR "RenderPasses")
