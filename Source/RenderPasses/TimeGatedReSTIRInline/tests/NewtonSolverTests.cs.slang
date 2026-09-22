// Standalone numerical regression tests; exercised by test_newton_solver.py.
import RenderPasses.Shared.PathLengthNewtonSolver.NewtonSolver;
import RenderPasses.Shared.PathLengthNewtonSolver.SurfaceOps.LocalTangentSurface;

RWStructuredBuffer<float4> results;

[numthreads(1, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    float2 u;
    // Previously accepted after two iterations despite a large gauge residual.
    LocalPlaneOps ops = LocalPlaneOps(float3(-.58626106f, .27115905f, .87781121f),
        float3(1.76098715f, -.28433909f, 1.32808099f), float3(0.f),
        float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
    u = float2(.08182081f, .28834974f);
    float L0; float2 g0; float3 H0;
    ops.eval(u, L0, g0, H0);
    NewtonResult result = solve_xi_prime_newton_det(ops, u, .33747132f, GaugeMode::ORTHO_AVG_GRAD,
        float2(0.f, 1.f), 5, .003374713f);
    float L1; float2 g1; float3 H1;
    ops.eval(result.xi_prime, L1, g1, H1);
    float2 a = Rperp(.5f * (g0 + g1));
    results[0] = float4(abs(L1 - L0 - .33747132f), abs(dot(a, result.xi_prime - u)) / length(a),
        float(result.status), float(result.iters));

    LocalPlaneOps singular = LocalPlaneOps(float3(0.f, 0.f, 1.f), float3(0.f, 0.f, 2.f),
        float3(0.f), float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
    result = solve_xi_prime_newton_det(singular, float2(0.f), .1f, GaugeMode::ORTHO_AVG_GRAD,
        float2(0.f, 1.f), 5, 1e-6f);
    results[1] = float4(float(result.status), result.detJ, 0.f, 0.f);

    // Exhausted iterations must not be reported as success.
    result = solve_xi_prime_newton_det(ops, u, .33747132f, GaugeMode::ORTHO_AVG_GRAD,
        float2(0.f, 1.f), 1, 1e-6f);
    results[2] = float4(float(result.status), result.detJ, 0.f, 0.f);

    // Coincident focus: do not evaluate a fake smooth derivative using a clamped distance.
    ops.p1 = ops.X(u);
    bool valid = ops.eval(u, L0, g0, H0);
    results[3] = float4(float(valid), 0.f, 0.f, 0.f);

}
