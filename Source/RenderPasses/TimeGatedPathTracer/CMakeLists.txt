add_plugin(TimeGatedPathTracer)

target_sources(TimeGatedPathTracer PRIVATE
    ColorType.slang
    GeneratePaths.cs.slang
    GuideData.slang
    LoadShadingData.slang
    NRDHelpers.slang
    Params.slang
    PathState.slang
    TimeGatedPathTracer.slang
    TimeGatedPathTracer.cpp
    TimeGatedPathTracer.h
    TimeGatedPathTracerNRD.slang
    ReflectTypes.cs.slang
    ResolvePass.cs.slang
    StaticParams.slang
    TracePass.rt.slang
)

target_copy_shaders(TimeGatedPathTracer RenderPasses/TimeGatedPathTracer)

target_source_group(TimeGatedPathTracer "RenderPasses")
