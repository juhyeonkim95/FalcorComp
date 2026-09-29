// Standalone numerical regression tests; exercised by test_newton_solver.py.
import RenderPasses.Shared.Shaders.ShiftMapping.NewtonSolver;
import RenderPasses.Shared.Shaders.ShiftMapping.Charts.LocalPlaneChart;

RWStructuredBuffer<float4> results;

[numthreads(1, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    float2 u;
    // Previously accepted after two iterations despite a large gauge residual.
    LocalPlaneChart ops = LocalPlaneChart(float3(-.58626106f, .27115905f, .87781121f),
        float3(1.76098715f, -.28433909f, 1.32808099f), float3(0.f),
        float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
    u = float2(.08182081f, .28834974f);
    float L0; float2 g0; float3 H0;
    ops.eval(u, L0, g0, H0);
    NewtonResult result = solveShiftNewton(ops, ops, false, false, 0.f, u, .33747132f, GaugeMode::OrthoAvgGrad,
        float2(0.f, 1.f), 5, .003374713f);
    float L1; float2 g1; float3 H1;
    ops.eval(result.xi_prime, L1, g1, H1);
    float2 a = Rperp(.5f * (g0 + g1));
    results[0] = float4(abs(L1 - L0 - .33747132f), abs(dot(a, result.xi_prime - u)) / length(a),
        float(result.status), float(result.iters));

    LocalPlaneChart singular = LocalPlaneChart(float3(0.f, 0.f, 1.f), float3(0.f, 0.f, 2.f),
        float3(0.f), float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
    result = solveShiftNewton(singular, singular, false, false, 0.f, float2(0.f), .1f, GaugeMode::OrthoAvgGrad,
        float2(0.f, 1.f), 5, 1e-6f);
    results[1] = float4(float(result.status), result.detJ, 0.f, 0.f);

    // Exhausted iterations must not be reported as success.
    result = solveShiftNewton(ops, ops, false, false, 0.f, u, .33747132f, GaugeMode::OrthoAvgGrad,
        float2(0.f, 1.f), 1, 1e-6f);
    results[2] = float4(float(result.status), result.detJ, 0.f, 0.f);

    // Distinct source endpoints (reuse from another pixel/frame): the map is ell_t(xi') = ell_s(xi) + C. Rows 4..7:
    // (analytic detJ, finite-difference detJ of the solved map, |reverse(forward(xi)) - xi|, status).
    // Rows 8..11: the single-length Jacobian (target gradient on the source side) for the same map.
    for (uint k = 0; k < 4; ++k)
    {
        float3 p2 = float3(.3f - .2f * k, -.4f + .1f * k, 1.2f + .1f * k);
        float3 p1t = float3(-.5f + .1f * k, .2f, .15f + .1f * k);
        float3 p1s = p1t + float3(.04f, -.03f + .02f * k, .01f * k);
        LocalPlaneChart target = LocalPlaneChart(p1t, p2, float3(0.f), float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
        LocalPlaneChart source = LocalPlaneChart(p1s, p2, float3(0.f), float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
        float2 x0 = float2(.05f * k, -.03f);
        float Lt, Ls; float2 g; float3 H;
        target.eval(x0, Lt, g, H); source.eval(x0, Ls, g, H);
        float C = Lt - Ls + .01f; // a small shift, as in temporal/spatial reuse
        float tol = 1e-6f;
        // c(xi) = ell_s(xi) + C - ell_t(xi): the offset the reuse code computes at the source point.
        float2 xs[5] = { x0, x0 + float2(1e-3f, 0.f), x0 - float2(1e-3f, 0.f), x0 + float2(0.f, 1e-3f), x0 - float2(0.f, 1e-3f) };
        float2 xp[5]; float detJ = 0.f; uint status = 0;
        for (uint j = 0; j < 5; ++j)
        {
            target.eval(xs[j], Lt, g, H); source.eval(xs[j], Ls, g, H);
            LocalPlaneChart t = target;
            NewtonResult r = solveShiftNewton(t, source, true, false, 0.f, xs[j], Ls + C - Lt, GaugeMode::OrthoAvgGrad, float2(0.f, 1.f), 20, tol);
            xp[j] = r.xi_prime;
            if (j == 0) { detJ = r.detJ; status = uint(r.status); }
        }
        float2 cx = (xp[1] - xp[2]) / 2e-3f, cy = (xp[3] - xp[4]) / 2e-3f;
        float detFD = abs(cx.x * cy.y - cx.y * cy.x);
        // Reverse: from xi' on the target prefix back to the source prefix.
        target.eval(xp[0], Lt, g, H); source.eval(xp[0], Ls, g, H);
        LocalPlaneChart s2 = source;
        NewtonResult back = solveShiftNewton(s2, target, true, false, 0.f, xp[0], Lt - C - Ls, GaugeMode::OrthoAvgGrad, float2(0.f, 1.f), 20, tol);
        results[4 + k] = float4(detJ, detFD, length(back.xi_prime - x0), float(status));
        // Old Jacobian on the same map: source gradient replaced by the target's.
        LocalPlaneChart t2 = target;
        target.eval(x0, Lt, g, H); source.eval(x0, Ls, g, H);
        NewtonResult old = solveShiftNewton(t2, target, false, false, 0.f, x0, Ls + C - Lt, GaugeMode::OrthoAvgGrad, float2(0.f, 1.f), 20, tol);
        results[8 + k] = float4(old.detJ, detFD, length(old.xi_prime - xp[0]), float(old.status));
    }

    // Separate, non-conformal charts (traceStart): source chart orthonormal, target chart sheared/scaled/offset.
    // Rows 12..15: (analytic area Jacobian, finite-difference area Jacobian of x -> x', |reverse - xi|, status).
    for (uint k = 0; k < 4; ++k)
    {
        float3 p2 = float3(.3f - .2f * k, -.4f + .1f * k, 1.2f + .1f * k);
        float3 p1t = float3(-.5f + .1f * k, .2f, .15f + .1f * k);
        float3 p1s = p1t + float3(.04f, -.03f + .02f * k, .01f * k);
        float3 tt = float3(1.3f, .2f + .05f * k, 0.f), bt = float3(-.1f, .8f, 0.f);
        LocalPlaneChart source = LocalPlaneChart(p1s, p2, float3(0.f), float3(1.f, 0.f, 0.f), float3(0.f, 1.f, 0.f));
        LocalPlaneChart target = LocalPlaneChart(p1t, p2, float3(.1f, -.05f, 0.f), tt, bt);
        float rhoS = 1.f, rhoT = length(cross(tt, bt));
        float2 x0 = float2(.05f * k, -.03f);
        float Lt, Ls; float2 g; float3 H;
        target.eval(x0, Lt, g, H); // unused start value
        source.eval(x0, Ls, g, H);
        float3 X0 = source.X(x0);
        float C = length(p1t - X0) + length(p2 - X0) - Ls + .01f;
        float2 xs[5] = { x0, x0 + float2(1e-3f, 0.f), x0 - float2(1e-3f, 0.f), x0 + float2(0.f, 1e-3f), x0 - float2(0.f, 1e-3f) };
        float3 xw[5]; float detJ = 0.f; uint status = 0; float2 xp0 = float2(0.f);
        for (uint j = 0; j < 5; ++j)
        {
            source.eval(xs[j], Ls, g, H);
            LocalPlaneChart t = target;
            NewtonResult r = solveShiftNewton(t, source, true, true, Ls + C, xs[j], 0.f, GaugeMode::OrthoAvgGrad,
                float2(0.f, 1.f), 20, 1e-6f);
            xw[j] = target.X(r.xi_prime);
            if (j == 0) { detJ = r.detJ; status = uint(r.status); xp0 = r.xi_prime; }
        }
        float3 cx = (xw[1] - xw[2]) / 2e-3f, cy = (xw[3] - xw[4]) / 2e-3f;
        float areaFD = abs(cx.x * cy.y - cx.y * cy.x) / rhoS;
        // Reverse: from x' in the target chart back to the source chart.
        float Lt1; target.eval(xp0, Lt1, g, H);
        LocalPlaneChart s2 = source;
        NewtonResult back = solveShiftNewton(s2, target, true, true, Lt1 - C, xp0, 0.f, GaugeMode::OrthoAvgGrad,
            float2(0.f, 1.f), 20, 1e-6f);
        results[12 + k] = float4(detJ * rhoT / rhoS, areaFD, length(back.xi_prime - x0), float(status));
    }

    // Coincident focus: do not evaluate a fake smooth derivative using a clamped distance.
    ops.p1 = ops.X(u);
    bool valid = ops.eval(u, L0, g0, H0);
    results[3] = float4(float(valid), 0.f, 0.f, 0.f);

}
