# Slang modules shared by the render passes. They are imported as RenderPasses.Shared.Shaders.<Folder>.<Module>,
# so they are copied to the shader output directory with their folders kept.
set(shared_shaders
    Utils/InstanceVelocity.slang
    Utils/LoadShadingData.slang
    Utils/RayUtils.slang
    Utils/SingleChannel.slang
    Utils/TimeGate.slang
    Utils/TransientHistogram.slang
    Utils/Waveform.slang
    Utils/ContinuousWave.slang
    Lights/Laser.slang
    Lights/LaserLightSampler.slang
    Lights/LightConnection.slang
    Lights/EllipsoidalSampling.slang
    Lights/EllipsoidTriangleSampler.slang
    Lights/SceneTriangles.slang
    Geometry/Ellipsoid.slang
    Geometry/EllipsoidIntersection.slang
    ShiftMapping/ShiftMapping.slang
    ShiftMapping/NewtonSolver.slang
    ShiftMapping/Charts/ShiftChart.slang
    ShiftMapping/Charts/LocalPlaneChart.slang
    ShiftMapping/Charts/BarycentricChart.slang
    ShiftMapping/Charts/RayTraceHemisphereChart.slang
    ShiftMapping/Charts/CartesianRayChart.slang
    ReSTIR/Reservoirs.slang
    ReSTIR/InitialCandidates.slang
    ReSTIR/PathReconstruction.slang
    ReSTIR/ReflectTypes.cs.slang
    ReSTIR/ReservoirReuse.slang
    ReSTIR/SpatialReuse.slang
    ReSTIR/TemporalReuse.slang
    Antithetic/AntitheticMIS.slang
    Projector/ProjectorLight.slang
    Projector/ProjectorPatterns.slang
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
