add_plugin(ASVGFPass)

target_sources(ASVGFPass PRIVATE
    ASVGFAtrous.ps.slang
    ASVGFCommon.slang
    ASVGFFilterMoments.ps.slang
    ASVGFFinalModulate.ps.slang
    ASVGFPackLinearZAndNormal.ps.slang
    ASVGFCreateTemporalGradient.ps.slang
    ASVGFAtrousTemporalGradient.ps.slang
    ASVGFPass.cpp
    ASVGFPass.h
    ASVGFReproject.ps.slang
)

target_copy_shaders(ASVGFPass RenderPasses/ASVGFPass)

target_source_group(ASVGFPass "RenderPasses")
