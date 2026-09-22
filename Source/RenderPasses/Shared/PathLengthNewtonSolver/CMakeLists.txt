# One deployed shader implementation, shared by both ReSTIR plugins.
set(path_length_newton_shaders
    NewtonSolver.slang
    SurfaceOps/BarycentricTriSurface.slang
    SurfaceOps/CartesianRayChart.slang
    SurfaceOps/LocalTangentSurface.slang
    SurfaceOps/RayTraceHemisphere.slang
    SurfaceOps/SurfaceOpsInterface.slang
)
set(path_length_newton_outputs)
foreach(shader IN LISTS path_length_newton_shaders)
    set(output "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/PathLengthNewtonSolver/${shader}")
    get_filename_component(output_directory "${output}" DIRECTORY)
    add_custom_command(
        OUTPUT "${output}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${output_directory}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/${shader}" "${output}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
        VERBATIM
    )
    list(APPEND path_length_newton_outputs "${output}")
endforeach()
add_custom_target(PathLengthNewtonSolverShaders DEPENDS ${path_length_newton_outputs})
set_target_properties(PathLengthNewtonSolverShaders PROPERTIES FOLDER "RenderPasses/Shared")
