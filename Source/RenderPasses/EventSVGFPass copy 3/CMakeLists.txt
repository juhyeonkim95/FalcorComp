add_plugin(EventSVGFPass)

target_sources(EventSVGFPass PRIVATE
    EventSVGFAtrous.ps.slang
    EventSVGFCommon.slang
    EventSVGFFilterMoments.ps.slang
    EventSVGFFinalModulate.ps.slang
    EventSVGFPackLinearZAndNormal.ps.slang
    EventSVGFPass.cpp
    EventSVGFPass.h
    EventSVGFReproject.ps.slang
)

target_copy_shaders(EventSVGFPass RenderPasses/EventSVGFPass)

target_source_group(EventSVGFPass "RenderPasses")
