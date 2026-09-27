add_plugin(LaserLight)

target_sources(LaserLight PRIVATE
    LaserLight.cpp
    LaserLight.h
)

target_source_group(LaserLight "RenderPasses")
