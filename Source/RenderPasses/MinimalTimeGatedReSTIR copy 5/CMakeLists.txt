add_plugin(MinimalTimeGatedReSTIR)

target_sources(MinimalTimeGatedReSTIR PRIVATE
    MinimalTimeGatedReSTIR.cpp
    MinimalTimeGatedReSTIR.h
    MinimalTimeGatedReSTIR.cs.slang
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

target_copy_shaders(MinimalTimeGatedReSTIR RenderPasses/MinimalTimeGatedReSTIR)

target_source_group(MinimalTimeGatedReSTIR "RenderPasses")
