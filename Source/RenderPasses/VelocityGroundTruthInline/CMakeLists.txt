add_plugin(VelocityGroundTruthInline)

target_sources(VelocityGroundTruthInline PRIVATE
    VelocityGroundTruthInline.cpp
    VelocityGroundTruthInline.h
    VelocityGroundTruthInline.cs.slang
)

target_copy_shaders(VelocityGroundTruthInline RenderPasses/VelocityGroundTruthInline)

target_source_group(VelocityGroundTruthInline "RenderPasses")

add_dependencies(VelocityGroundTruthInline RenderPassSharedShaders)
