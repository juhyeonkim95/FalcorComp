set(shader_files LoadShadingData.slang SingleChannel.slang)
set(shader_outputs)
foreach(shader_file ${shader_files})
    set(shader_output "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Utils/${shader_file}")
    add_custom_command(
        OUTPUT "${shader_output}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Utils"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/${shader_file}" "${shader_output}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${shader_file}"
        VERBATIM
    )
    list(APPEND shader_outputs "${shader_output}")
endforeach()
add_custom_target(RenderPassUtilsShaders DEPENDS ${shader_outputs})
set_target_properties(RenderPassUtilsShaders PROPERTIES FOLDER "RenderPasses/Shared")
