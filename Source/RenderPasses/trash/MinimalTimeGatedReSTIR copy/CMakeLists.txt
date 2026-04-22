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
    LocalTangentSurface.slang
    SurfaceOpsInterface.slang
    PathTraceHemisphere.slang
    SpatialReuse.cs.slang
)

target_copy_shaders(MinimalTimeGatedReSTIR RenderPasses/MinimalTimeGatedReSTIR)

target_source_group(MinimalTimeGatedReSTIR "RenderPasses")
