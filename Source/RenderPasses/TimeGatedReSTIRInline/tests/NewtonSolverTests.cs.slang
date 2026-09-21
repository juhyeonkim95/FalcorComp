// Standalone numerical regression tests; exercised by test_newton_solver.py.
import RenderPasses.TimeGatedReSTIRInline.NewtonSolver;
import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.LocalTangentSurface;
import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.BarycentricTriSurface;

RWStructuredBuffer<float4> results;

NewtonResult solveExample(float2 u, GaugeMode mode)
{
    LocalPlaneOps source = LocalPlaneOps(float3(-.5f, 0.f, 1.f), float3(0.f, 2.f, 1.f),
        float3(0.f), float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
    LocalPlaneOps target = source;
    target.p1 = float3(.2f, 0.f, 1.f);
    return solve_paired_shift(source, target, u, .1f, 1.f, mode, float2(0.f, 1.f), 20, 1e-6f, 1e-6f);
}

[numthreads(1, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    float2 u = float2(.8f, .4f);
    float h = .002f;
    for (uint mode = 0; mode < 2; ++mode)
    {
        GaugeMode gauge = mode == 0 ? GaugeMode::CONSTANT_A : GaugeMode::ORTHO_AVG_GRAD;
        NewtonResult center = solveExample(u, gauge);
        NewtonResult xp = solveExample(u + float2(h, 0.f), gauge);
        NewtonResult xm = solveExample(u - float2(h, 0.f), gauge);
        NewtonResult yp = solveExample(u + float2(0.f, h), gauge);
        NewtonResult ym = solveExample(u - float2(0.f, h), gauge);
        float2 dx = (xp.xi_prime - xm.xi_prime) / (2.f * h);
        float2 dy = (yp.xi_prime - ym.xi_prime) / (2.f * h);
        uint failures = uint(center.status) + uint(xp.status) + uint(xm.status) + uint(yp.status) + uint(ym.status);
        results[mode] = float4(center.detJ, abs(dx.x * dy.y - dx.y * dy.x), float(failures), float(center.iters));
    }

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
    results[2] = float4(abs(L1 - L0 - .33747132f), abs(dot(a, result.xi_prime - u)) / length(a),
        float(result.status), float(result.iters));

    LocalPlaneOps singular = LocalPlaneOps(float3(0.f, 0.f, 1.f), float3(0.f, 0.f, 2.f),
        float3(0.f), float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
    result = solve_xi_prime_newton_det(singular, float2(0.f), .1f, GaugeMode::ORTHO_AVG_GRAD,
        float2(0.f, 1.f), 5, 1e-6f);
    results[3] = float4(float(result.status), result.detJ, 0.f, 0.f);

    // Exhausted iterations must not be reported as success.
    result = solve_xi_prime_newton_det(ops, u, .33747132f, GaugeMode::ORTHO_AVG_GRAD,
        float2(0.f, 1.f), 1, 1e-6f);
    results[4] = float4(float(result.status), result.detJ, 0.f, 0.f);

    // Coincident focus: do not evaluate a fake smooth derivative using a clamped distance.
    ops.p1 = ops.X(u);
    bool valid = ops.eval(u, L0, g0, H0);
    results[5] = float4(float(valid), 0.f, 0.f, 0.f);

    // Nonorthonormal barycentric chart must give the same finite-difference Jacobian.
    BarycentricTriOps bs = BarycentricTriOps(float3(-.5f, 0.f, 1.f), float3(0.f, 2.f, 1.f),
        float3(0.f), float3(2.f, .2f, .1f), float3(.3f, 1.5f, .4f));
    BarycentricTriOps bt = bs; bt.p1 = float3(.2f, 0.f, 1.f);
    u = float2(.2f, .3f);
    NewtonResult r0 = solve_paired_shift(bs, bt, u, .1f, 1.f, GaugeMode::ORTHO_AVG_GRAD, float2(0.f, 1.f), 20, 1e-6f, 1e-6f);
    NewtonResult rxp = solve_paired_shift(bs, bt, u + float2(h, 0.f), .1f, 1.f, GaugeMode::ORTHO_AVG_GRAD, float2(0.f, 1.f), 20, 1e-6f, 1e-6f);
    NewtonResult rxm = solve_paired_shift(bs, bt, u - float2(h, 0.f), .1f, 1.f, GaugeMode::ORTHO_AVG_GRAD, float2(0.f, 1.f), 20, 1e-6f, 1e-6f);
    NewtonResult ryp = solve_paired_shift(bs, bt, u + float2(0.f, h), .1f, 1.f, GaugeMode::ORTHO_AVG_GRAD, float2(0.f, 1.f), 20, 1e-6f, 1e-6f);
    NewtonResult rym = solve_paired_shift(bs, bt, u - float2(0.f, h), .1f, 1.f, GaugeMode::ORTHO_AVG_GRAD, float2(0.f, 1.f), 20, 1e-6f, 1e-6f);
    float2 dx = (rxp.xi_prime - rxm.xi_prime) / (2.f * h);
    float2 dy = (ryp.xi_prime - rym.xi_prime) / (2.f * h);
    results[6] = float4(r0.detJ, abs(dx.x * dy.y - dx.y * dy.x),
        float(uint(r0.status) + uint(rxp.status) + uint(rxm.status) + uint(ryp.status) + uint(rym.status)), 0.f);
    NewtonResult back = solve_paired_shift(bt, bs, r0.xi_prime, -.1f, 1.f, GaugeMode::ORTHO_AVG_GRAD,
        float2(0.f, 1.f), 20, 1e-6f, 1e-6f);
    results[7] = float4(length(back.xi_prime - u), r0.detJ * back.detJ, float(back.status), 0.f);
}
