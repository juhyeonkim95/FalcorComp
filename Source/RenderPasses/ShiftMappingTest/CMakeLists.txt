add_plugin(ShiftMappingTest)

target_sources(ShiftMappingTest PRIVATE
    ShiftMappingTest.cpp
    ShiftMappingTest.cs.slang
)

target_copy_shaders(ShiftMappingTest RenderPasses/ShiftMappingTest)

target_source_group(ShiftMappingTest "RenderPasses")

add_dependencies(ShiftMappingTest RenderPassSharedShaders)
