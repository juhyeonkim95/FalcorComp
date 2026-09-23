set(light_shaders LaserLightSampler.slang LightConnection.slang EllipsoidalSampling.slang)
set(light_outputs)
foreach(shader IN LISTS light_shaders)
    set(output "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Lights/${shader}")
    add_custom_command(
        OUTPUT "${output}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Lights"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/${shader}" "${output}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
        VERBATIM
    )
    list(APPEND light_outputs "${output}")
endforeach()
add_custom_target(RenderPassLightShaders DEPENDS ${light_outputs})
set_target_properties(RenderPassLightShaders PROPERTIES FOLDER "RenderPasses/Shared")
add_dependencies(RenderPassLightShaders RenderPassUtilsShaders)
