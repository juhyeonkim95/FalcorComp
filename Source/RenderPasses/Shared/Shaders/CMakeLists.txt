# Slang modules shared by the render passes. They are imported as RenderPasses.Shared.Shaders.<Folder>.<Module>,
# so they are copied to the shader output directory with their folders kept.
set(shared_shaders
    Utils/LoadShadingData.slang
    Utils/SingleChannel.slang
    Lights/LaserLightSampler.slang
    Lights/LightConnection.slang
    Lights/EllipsoidalSampling.slang
    ReSTIR/Reservoirs.slang
    ReSTIR/InitialCandidates.slang
    ReSTIR/PathReconstruction.slang
    ReSTIR/PathLengthAwareShiftmapping.slang
    ReSTIR/ReservoirReuse.slang
    ReSTIR/SpatialReuse.slang
    PathLengthNewtonSolver/NewtonSolver.slang
    PathLengthNewtonSolver/SurfaceOps/BarycentricTriSurface.slang
    PathLengthNewtonSolver/SurfaceOps/CartesianRayChart.slang
    PathLengthNewtonSolver/SurfaceOps/LocalTangentSurface.slang
    PathLengthNewtonSolver/SurfaceOps/RayTraceHemisphere.slang
    PathLengthNewtonSolver/SurfaceOps/SurfaceOpsInterface.slang
)
set(shared_shader_outputs)
foreach(shader IN LISTS shared_shaders)
    set(output "${FALCOR_SHADER_OUTPUT_DIRECTORY}/RenderPasses/Shared/Shaders/${shader}")
    get_filename_component(output_directory "${output}" DIRECTORY)
    add_custom_command(
        OUTPUT "${output}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${output_directory}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/${shader}" "${output}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
        VERBATIM
    )
    list(APPEND shared_shader_outputs "${output}")
endforeach()
add_custom_target(RenderPassSharedShaders DEPENDS ${shared_shader_outputs})
set_target_properties(RenderPassSharedShaders PROPERTIES FOLDER "RenderPasses/Shared")
