set(shader_output "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Utils/LoadShadingData.slang")
add_custom_command(
    OUTPUT "${shader_output}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Utils"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/LoadShadingData.slang" "${shader_output}"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/LoadShadingData.slang"
    VERBATIM
)
add_custom_target(RenderPassUtilsShaders DEPENDS "${shader_output}")
set_target_properties(RenderPassUtilsShaders PROPERTIES FOLDER "RenderPasses/Shared")
