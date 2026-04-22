add_plugin(WLRPass)

target_sources(WLRPass PRIVATE
    WLRCommon.slang
    WLRDenoiseSimple.ps.slang
    WLRPackLinearZAndNormal.ps.slang
    WLRPass.cpp
    WLRPass.h
)

target_copy_shaders(WLRPass RenderPasses/WLRPass)

target_source_group(WLRPass "RenderPasses")
