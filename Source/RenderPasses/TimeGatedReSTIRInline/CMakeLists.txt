add_plugin(TimeGatedReSTIRInline)

target_sources(TimeGatedReSTIRInline PRIVATE
    TimeGatedReSTIRInline.cpp
    TimeGatedReSTIRInline.h
    InitialSampleGeneration.cs.slang
    ReflectTypes.cs.slang
    Reservoirs.slang
    PathLengthAwareShiftmapping.slang
    TransientShiftmapping.slang
    LoadShadingData.slang
    NewtonSolver.slang
    SurfaceOps/LocalTangentSurface.slang
    SurfaceOps/SurfaceOpsInterface.slang
    SurfaceOps/BarycentricTriSurface.slang
    SurfaceOps/RayTraceHemisphere.slang
    SurfaceOps/CartesianRayChart.slang
    SpatialReuse.cs.slang
    EvaluateFinalSamples.cs.slang
    LaserLightSampler.slang
)

target_copy_shaders(TimeGatedReSTIRInline RenderPasses/TimeGatedReSTIRInline)

target_source_group(TimeGatedReSTIRInline "RenderPasses")
