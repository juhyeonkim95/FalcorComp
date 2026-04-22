add_plugin(MinimalTransientReSTIRV2)

target_sources(MinimalTransientReSTIRV2 PRIVATE
    MinimalTransientReSTIRV2.cpp
    MinimalTransientReSTIRV2.h
    MinimalTransientReSTIRV2.cs.slang
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

target_copy_shaders(MinimalTransientReSTIRV2 RenderPasses/MinimalTransientReSTIRV2)

target_source_group(MinimalTransientReSTIRV2 "RenderPasses")
