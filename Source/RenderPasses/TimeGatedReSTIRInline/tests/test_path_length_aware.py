"""GPU checks for source/target analytic surface mapping.

Uses the production solver directly: finite differences, zero displacement,
and forward/reverse consistency for avg_grad. Source bin/setpath.sh first.
"""
from pathlib import Path
import tempfile
import falcor
import numpy as np


def main():
    shader = """
import RenderPasses.TimeGatedReSTIRInline.NewtonSolver;
import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.SurfaceOpsInterface;
import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.LocalTangentSurface;
import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.BarycentricTriSurface;
RWStructuredBuffer<float4> results;
struct LinearOps : ISurfaceOps
{
    float sourceScale;
    [mutating] void initializeSource(float2 xi) {}
    bool evalTarget(float2 xi_prime, out float L, out float2 g, out float3 H)
    { L = xi_prime.x; g = float2(1.f, 0.f); H = float3(0.f); return true; }
    bool evalSource(float2 xi, out float L, out float2 g, out float3 H)
    { L = sourceScale*xi.x; g = float2(sourceScale, 0.f); H = float3(0.f); return true; }
    float2 project(float2 xi_prime) { return xi_prime; }
    [mutating] void update(float2 xi_prime) {}
};

NewtonResult evaluate(float2 u, uint mode, bool triangle, float K, float offset = .01f)
{
    float3 a = float3(-.5f, 0.f, 1.f), b = float3(-.45f, .02f, 1.f), y = float3(0.f, 2.f, 1.f);
    if (triangle)
    {
        BarycentricTriOps ops = BarycentricTriOps(a, b, y, float3(0.f), float3(2.f,0.f,0.f), float3(0.f,2.f,0.f));
        float Ls; float2 gs; float3 Hs; ops.evalSource(u,Ls,gs,Hs);
        NewtonResult result = solve_xi_prime_newton_det(ops, u, (K-1.f)*Ls+offset, GaugeMode(mode), float2(0.f,1.f), 30, 1e-6f);
        result.detJ *= K;
        return result;
    }
    LocalPlaneOps ops = LocalPlaneOps(a,b,y,float3(0.f),float3(1.f,0.f,0.f),float3(0.f,1.f,0.f));
    float Ls; float2 gs; float3 Hs; ops.evalSource(u,Ls,gs,Hs);
    NewtonResult result = solve_xi_prime_newton_det(ops, u, (K-1.f)*Ls+offset, GaugeMode(mode), float2(0.f,1.f), 30, 1e-6f);
    result.detJ *= K;
    return result;
}
[numthreads(1,1,1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    for (uint i=0; i<12; ++i)
    {
        uint mode = i % 3;
        bool triangle = (i / 3) % 2 != 0;
        float K = i < 6 ? 1.f : 1.01f;
        float2 u = triangle ? float2(.3f,.2f) : float2(.8f,.4f);
        float h = .001f;
        NewtonResult c = evaluate(u,mode,triangle,K);
        NewtonResult xp = evaluate(u+float2(h,0.f),mode,triangle,K);
        NewtonResult xm = evaluate(u-float2(h,0.f),mode,triangle,K);
        NewtonResult yp = evaluate(u+float2(0.f,h),mode,triangle,K);
        NewtonResult ym = evaluate(u-float2(0.f,h),mode,triangle,K);
        float2 dx = (xp.xi_prime-xm.xi_prime)/(2.f*h);
        float2 dy = (yp.xi_prime-ym.xi_prime)/(2.f*h);
        uint failures = uint(c.status)+uint(xp.status)+uint(xm.status)+uint(yp.status)+uint(ym.status);
        results[i] = float4(c.detJ,abs(dx.x*dy.y-dx.y*dy.x),float(failures),float(c.iters));
    }
    // c(xi)=xi.x at xi=0: zero displacement, but mapping is (2*xi.x,xi.y).
    LinearOps linear; linear.sourceScale = 2.f;
    NewtonResult corrected = solve_xi_prime_newton_det(linear, float2(0.f), 0.f,
        GaugeMode::CONSTANT_A, float2(0.f,1.f), 5, 1e-6f);
    linear.sourceScale = 1.f;
    NewtonResult constant = solve_xi_prime_newton_det(linear, float2(0.f), 0.f,
        GaugeMode::CONSTANT_A, float2(0.f,1.f), 5, 1e-6f);
    results[12] = float4(corrected.detJ, 2.f, float(corrected.status), float(corrected.iters));
    results[13] = float4(constant.detJ, 1.f, float(constant.status), float(constant.iters));
    // Equal prefixes/gates: offset=0. Unequal prefixes: retain their difference.
    for (uint j=0; j<2; ++j)
    {
        float offset = j == 0 ? 0.f : .02f;
        float2 xi = float2(.8f,.4f);
        NewtonResult mapped = evaluate(xi,2,false,1.f,offset);
        float3 sourcePoint = float3(xi,0.f), targetPoint = float3(mapped.xi_prime,0.f);
        float Lsource = length(float3(-.5f,0.f,1.f)-sourcePoint) + length(float3(0.f,2.f,1.f)-sourcePoint);
        float Ltarget = length(float3(-.45f,.02f,1.f)-targetPoint) + length(float3(0.f,2.f,1.f)-targetPoint);
        results[16+j] = float4(abs(Ltarget-Lsource-offset), Ltarget-Lsource,
            float(mapped.status),length(mapped.xi_prime-xi));
    }
    for (uint j=0; j<2; ++j)
    {
        float K = 1.f; // Reverse symmetry test is for the unscaled gauge (K=1).
        float2 xi = float2(.8f + .1f * j,.4f);
        NewtonResult forward = evaluate(xi, 2, false, K);
        LocalPlaneOps reverseOps = LocalPlaneOps(float3(-.45f,.02f,1.f),float3(-.5f,0.f,1.f),
            float3(0.f,2.f,1.f),float3(0.f),float3(1.f,0.f,0.f),float3(0.f,1.f,0.f));
        NewtonResult reverse = solve_xi_prime_newton_det(reverseOps, forward.xi_prime, -.01f,
            GaugeMode::ORTHO_AVG_GRAD, float2(0.f,1.f), 30, 1e-6f);
        results[14+j] = float4(length(reverse.xi_prime-xi), forward.detJ*reverse.detJ,
            float(uint(forward.status)+uint(reverse.status)),0.f);
    }
}
"""
    testbed = falcor.Testbed(create_window=False)
    device = testbed.device
    output = device.create_structured_buffer(struct_size=16, element_count=18,
        bind_flags=falcor.ResourceBindFlags.ShaderResource | falcor.ResourceBindFlags.UnorderedAccess)
    with tempfile.TemporaryDirectory(prefix="path-length-jacobian-") as directory:
        path = Path(directory) / "test.cs.slang"
        path.write_text(shader)
        compute = falcor.ComputePass(device, file=path, cs_entry="main")
        compute.globals.results = output
        compute.execute(threads_x=1)
        device.wait()
        rows = output.to_numpy().view(np.float32).reshape(18, 4)
    print(rows)
    assert np.isfinite(rows).all(), rows
    assert np.all(rows[:, 2] == 0), rows
    np.testing.assert_allclose(rows[:14, 0], rows[:14, 1], rtol=3e-3, atol=2e-4)
    assert np.all(rows[12:14, 3] == 0), rows[12:14]
    assert np.all(rows[14:16, 0] < 1e-5), rows[14:]
    np.testing.assert_allclose(rows[14:16, 1], 1., rtol=1e-4)
    assert np.all(rows[16:, 0] < 2e-6), rows[16:]
    assert rows[16, 3] > 1e-4, rows[16]  # Zero offset is not an identity mapping.
    np.testing.assert_allclose(rows[16:, 1], [0., .02], atol=2e-6)
    print("Implicit Jacobian matches finite differences: all 3 gauges, plane/triangle, K=1/1.01.")


if __name__ == "__main__":
    main()
