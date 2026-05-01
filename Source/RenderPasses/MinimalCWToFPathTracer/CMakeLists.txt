add_plugin(MinimalCWToFPathTracer)

target_sources(MinimalCWToFPathTracer PRIVATE
    MinimalCWToFPathTracer.cpp
    MinimalCWToFPathTracer.h
    MinimalCWToFPathTracer.cs.slang
    SurfaceOps/LocalTangentSurface.slang
    SurfaceOps/SurfaceOpsInterface.slang
    SurfaceOps/BarycentricTriSurface.slang
    NewtonSolver.slang
    GeometricShiftmapping.slang
    ProjectorLight.slang
    ProjectorPatterns/ProjectorPatternInterface.slang
    ProjectorPatterns/PeriodicPattern.slang
    ProjectorPatterns/XORPattern.slang
    ProjectorPatterns/GrayPattern.slang
    ProjectorPatterns/ArbitraryAntitheticPattern.slang
)

target_copy_shaders(MinimalCWToFPathTracer RenderPasses/MinimalCWToFPathTracer)

target_source_group(MinimalCWToFPathTracer "RenderPasses")
