add_plugin(EventCamera)

target_sources(EventCamera PRIVATE
    EventCamera.cpp
    EventCamera.h
    EventDifference.cs.slang
    EventGenerator.cs.slang
)

target_copy_shaders(EventCamera RenderPasses/EventCamera)

target_source_group(EventCamera "RenderPasses")
