add_plugin(MinimalTransientReSTIRV3)

target_sources(MinimalTransientReSTIRV3 PRIVATE
    MinimalTransientReSTIRV3.cpp
    MinimalTransientReSTIRV3.h
    MinimalTransientReSTIRV3.cs.slang
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

target_copy_shaders(MinimalTransientReSTIRV3 RenderPasses/MinimalTransientReSTIRV3)

target_source_group(MinimalTransientReSTIRV3 "RenderPasses")
