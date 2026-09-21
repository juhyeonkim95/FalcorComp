import TransientShiftmapping;
import Scene.RaytracingInline;
import LoadShadingData;
import Utils.Sampling.SampleGenerator;

// Legacy constant-offset mapping. dt is held fixed when evaluating the Jacobian;
// source-path-length dependence is intentionally not differentiated on this branch.
HitInfo path_length_aware_shift_mapping(
    ShadingData x1, HitInfo x2, ShadingData x3, float dt,
    out float jacobian, inout ShiftMapDebugInfo debugInfo,
    float tol, inout SampleGenerator sg)
{
    return transient_shift_mapping(x1, x2, x3, dt, jacobian, debugInfo, tol, sg);
}
