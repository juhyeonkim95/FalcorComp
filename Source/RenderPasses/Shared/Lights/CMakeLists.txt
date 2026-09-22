set(shader_output "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Lights/LaserLightSampler.slang")
add_custom_command(
    OUTPUT "${shader_output}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Lights"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/LaserLightSampler.slang" "${shader_output}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/LaserLightSampler.slang"
    VERBATIM
)
add_custom_target(RenderPassLightShaders DEPENDS "${shader_output}")
set_target_properties(RenderPassLightShaders PROPERTIES FOLDER "RenderPasses/Shared")
add_dependencies(RenderPassLightShaders RenderPassUtilsShaders)
