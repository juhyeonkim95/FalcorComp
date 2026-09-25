add_plugin(TransientHistogramAccumulatePass)

target_sources(TransientHistogramAccumulatePass PRIVATE
    TransientHistogramAccumulatePass.cpp
    TransientHistogramAccumulatePass.h
    TransientHistogramAccumulatePass.cs.slang
)

target_copy_shaders(TransientHistogramAccumulatePass RenderPasses/TransientHistogramAccumulatePass)

target_source_group(TransientHistogramAccumulatePass "RenderPasses")
