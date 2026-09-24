add_plugin(TransientHistogramViewer)

target_sources(TransientHistogramViewer PRIVATE
    TransientHistogramViewer.cpp
    TransientHistogramViewer.h
    TransientHistogramViewer.cs.slang
)

target_copy_shaders(TransientHistogramViewer RenderPasses/TransientHistogramViewer)

target_source_group(TransientHistogramViewer "RenderPasses")
