set(restir_shaders Reservoirs.slang PathReconstruction.slang ReservoirReuse.slang PathLengthAwareShiftmapping.slang
    InitialCandidates.slang SpatialReuse.slang)
set(restir_outputs)
foreach(shader IN LISTS restir_shaders)
    set(output "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/ReSTIR/${shader}")
    add_custom_command(
        OUTPUT "${output}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/ReSTIR"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/${shader}" "${output}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
        VERBATIM
    )
    list(APPEND restir_outputs "${output}")
endforeach()
add_custom_target(ReSTIRShaders DEPENDS ${restir_outputs})
set_target_properties(ReSTIRShaders PROPERTIES FOLDER "RenderPasses/Shared")

add_dependencies(ReSTIRShaders RenderPassLightShaders)
