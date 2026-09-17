add_plugin(MinimalCWToFPathTracer)

target_sources(MinimalCWToFPathTracer PRIVATE
    MinimalCWToFPathTracer.cpp
    MinimalCWToFPathTracer.h
    MinimalCWToFPathTracer.cs.slang
    SurfaceOps/LocalTangentSurface.slang
    SurfaceOps/SurfaceOpsInterface.slang
    SurfaceOps/BarycentricTriSurface.slang
    SurfaceOps/RayTraceHemisphere.slang
    NewtonSolver.slang
    GeometricShiftmapping.slang
    LoadShadingData.slang
)

target_copy_shaders(MinimalCWToFPathTracer RenderPasses/MinimalCWToFPathTracer)

target_source_group(MinimalCWToFPathTracer "RenderPasses")
