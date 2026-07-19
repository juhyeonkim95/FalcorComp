add_plugin(EventSVGFAreaPass)

target_sources(EventSVGFAreaPass PRIVATE
    EventSVGFAreaAtrous.ps.slang
    EventSVGFAreaCommon.slang
    EventSVGFAreaFilterMoments.ps.slang
    EventSVGFAreaFinalModulate.ps.slang
    EventSVGFAreaPackLinearZAndNormal.ps.slang
    EventSVGFAreaPass.cpp
    EventSVGFAreaPass.h
    EventSVGFAreaReproject.ps.slang
)

target_copy_shaders(EventSVGFAreaPass RenderPasses/EventSVGFAreaPass)

target_source_group(EventSVGFAreaPass "RenderPasses")
