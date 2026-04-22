add_plugin(SVGFEventPass)

target_sources(SVGFEventPass PRIVATE
    SVGFEventAtrous.ps.slang
    SVGFEventCommon.slang
    SVGFEventFilterMoments.ps.slang
    SVGFEventFinalModulate.ps.slang
    SVGFEventPackLinearZAndNormal.ps.slang
    SVGFEventPass.cpp
    SVGFEventPass.h
    SVGFEventReproject.ps.slang
)

target_copy_shaders(SVGFEventPass RenderPasses/SVGFEventPass)

target_source_group(SVGFEventPass "RenderPasses")
