
import Charts.ShiftChart;

// =============================================================
// Gauge mode
// =============================================================
enum GaugeMode : uint
{
    Constant       = 0,
    OrthoGradStart = 1,
    OrthoAvgGrad   = 2,
};

enum NewtonResultStatus : uint
{
    Success      = 0,
    NoConverge   = 1,
    Singular     = 2,
    InvalidPoint = 3,
};


// =============================================================
// Result struct
// =============================================================
struct NewtonResult
{
    float2 xi_prime;
    float  detJ;
    int    iters;
    NewtonResultStatus    status;   // 0 OK, 1 no converge, 2 singular Jacobian
};

// =================== Helpers ===================
float2 Rperp(float2 v) { return float2(-v.y, v.x); }

// y = H * v  for symmetric H = [H.x H.y; H.y H.z]
float2 Hmul(float3 H, float2 v)
{
    return float2(H.x * v.x + H.y * v.y,
                  H.y * v.x + H.z * v.y);
}

void inv2(float a,float b,float c,float d,
                 out float m00,out float m01,out float m10,out float m11,out float det)
{
    det = a * d - b * c;
    float inv = 1.0 / det;
    m00 =  d * inv; m01 = -b * inv;
    m10 = -c * inv; m11 =  a * inv;
}

// ----------------- gaugeTerms (packed Hessians) -----------------
// Builds: a(η',η),   JpΔ = (∂a/∂xi')^T Δ,   J0Δ = (∂a/∂xi )^T Δ
void gaugeTerms(
    GaugeMode mode,
    float2 a_const,
    float2 g0, float2 g1,
    float3 H0, float3 H1,
    float2 Delta,
    out float2 a,
    out float2 JpDelta,
    out float2 J0Delta)
{
    float2 RDel = Rperp(Delta);

    if (mode == GaugeMode::Constant)
    {
        a = a_const;
        JpDelta = float2(0.0, 0.0);
        J0Delta = float2(0.0, 0.0);
        return;
    }
    if (mode == GaugeMode::OrthoGradStart)
    {
        a = Rperp(g0);
        JpDelta = float2(0.0, 0.0);
        // (∂a/∂xi)^T Δ = (R H0)^T Δ = - H0 (R Δ)
        J0Delta = float2(0.0, 0.0) - Hmul(H0, RDel);
        return;
    }

    // ORTHO_AVG_GRAD
    a = Rperp(0.5 * (g0 + g1));
    // (∂a/∂xi')^T Δ = -0.5 * H1 (R Δ)
    JpDelta = float2(0.0, 0.0) - 0.5 * Hmul(H1, RDel);
    // (∂a/∂xi )^T Δ = -0.5 * H0 (R Δ)
    J0Delta = float2(0.0, 0.0) - 0.5 * Hmul(H0, RDel);
}

// Solves ell_t(xi') = K ell_s(xi) + C with the gauge a . (xi' - xi) = 0. xi is the source vertex in sourceOps's
// coordinates (sourceOps evaluates the source path's length ell_s and its state represents the source vertex); xi' is
// in ops's coordinates (the target length ell_t). The gauge compares the raw coordinates, and the avg_grad gauge
// a = R (g_s(xi) + g_t(xi')) / 2 is symmetric under swapping the roles, so the reverse shift (charts and lengths
// swapped) has the same solutions: it returns to xi for any pair of charts. The source rows of the Jacobian (d/dxi)
// use ell_s's gradient g_s and Hessian H_s at xi.
//   - traceStart = false: ops's state at xi already represents the source vertex (both charts are the same function),
//     so ell_t(xi) is the target length there and the equation is ell_t(xi') = ell_t(xi) + c.
//   - traceStart = true: the charts differ; ops's start point X_t(xi) is another surface point, traced here, and the
//     equation is ell_t(xi') = targetValue (= ell_t at the source vertex + c).
// Without a distinct source (distinctSource = false), g_s = g_t: the single-length solve.
NewtonResult solveShiftNewton<Chart : IShiftChart>(
    inout Chart ops,
    Chart sourceOps,
    bool distinctSource,
    bool traceStart,
    float targetValue,
    float2 xi, float c,
    GaugeMode mode,
    float2 a_const,          // used iff CONSTANT_A
    int maxIters,            // e.g., 15
    float tol                // e.g., 1e-6
)
{
    NewtonResult R;
    R.xi_prime = xi;
    R.detJ = 1.0;
    R.iters = 0;
    R.status = NewtonResultStatus::Success;

    const float epsDet = 1e-18;
    const float epsDir = 1e-12;
    const float ctol   = 1e-9;

    // Start eval (fixed during solve)
    float  L0; float2 g0; float3 H0;
    if (traceStart) ops.update(xi);
    if(!ops.eval(xi, L0, g0, H0)){
        R.status = NewtonResultStatus::InvalidPoint; return R;
    }
    // Source length at the start: g0/H0 below are the source's gradient and Hessian.
    float2 gt0 = g0; float3 Ht0 = H0;
    if (distinctSource)
    {
        float Ls;
        if (!sourceOps.eval(xi, Ls, g0, H0)) { R.status = NewtonResultStatus::InvalidPoint; return R; }
    }

    // no need to search (a distinct source needs the Jacobian of its map even where xi' = xi)
    if (abs(c) <= tol && !distinctSource)
    {
        R.xi_prime = xi;
        R.detJ = 1.0;
        return R;
    }

    // Predictor: move orthogonal to starting gauge
    float2 a0 = (mode == GaugeMode::Constant) ? a_const : Rperp(g0);
    float2 dir = Rperp(a0);
    float n2 = max(dot(dir, dir), 1e-20);
    dir *= rsqrt(n2); // normalize

    float2 e = xi; //ops.project(xi + s0 * dir);

    float  L1 = L0; float2 g1 = gt0; float3 H1 = Ht0;
    float2 a, JpDelta, J0Delta;
    float2 Delta;
    float inv00, inv01, inv10, inv11, detJp;
    // With a distinct source and c ~ 0, xi' = xi already solves both equations; only the Jacobian is needed.
    bool success = abs(traceStart ? L0 - targetValue : c) <= tol;
    float beta = 1.0f;

    // --- Newton iterations using only Jp = ∂F/∂η' ---
    for (int it = 0; it < maxIters && !success; ++it)
    {
        R.iters = it + 1;

        Delta = e - xi;
        gaugeTerms(mode, a_const, g0, g1, H0, H1, Delta, a, JpDelta, J0Delta);

        // Current Residuals
        float F1 = traceStart ? L1 - targetValue : L1 - L0 - c;
        float F2 = dot(a, Delta);

        // Jp rows: [ g1^T ; (a + JpDelta)^T ]
        float a11 = g1.x, a12 = g1.y;
        float b11 = a.x + JpDelta.x, b12 = a.y + JpDelta.y;

        inv2(a11, a12, b11, b12, inv00, inv01, inv10, inv11, detJp);
        if (abs(detJp) < epsDet) { R.status = NewtonResultStatus::Singular; R.detJ = 0.0; return R; }

        // Δη' = - Jp^{-1} F
        float rhs1 = -F1, rhs2 = -F2;
        float dx = inv00 * rhs1 + inv01 * rhs2;
        float dy = inv10 * rhs1 + inv11 * rhs2;

        // Trial update with current β
        float  L_try; float2 g_try; float3 H_try;
        const float2 e_try = ops.project(float2(e.x + beta*dx, e.y + beta*dy) );
        ops.update(e_try);
        bool update_eta = ops.eval(e_try, L_try, g_try, H_try);
        float F1_try = traceStart ? L_try - targetValue : L_try - L0 - c;

        if(!update_eta || (abs(F1_try) > abs(F1))){
            beta *= 0.5f;
        } else {
            e = e_try;
            L1 = L_try;
            g1 = g_try;
            H1 = H_try;
            beta = min(1.0, beta * 2.0f);
            if(abs(F1_try) < tol){
                success = true;
                break;
            }
        }


    }
    // Final point
    R.xi_prime = e;

    Delta = e - xi;
    gaugeTerms(mode, a_const, g0, g1, H0, H1, Delta, a, JpDelta, J0Delta);
    // Jp rows: [ g1^T ; (a + JpDelta)^T ]
    float a11 = g1.x, a12 = g1.y;
    float b11 = a.x + JpDelta.x, b12 = a.y + JpDelta.y;
    inv2(a11, a12, b11, b12, inv00, inv01, inv10, inv11, detJp);

    // J0: row1 = -g0^T; row2 = (∂a/∂η)^T Δ - a
    float n11 = -g0.x, n12 = -g0.y;
    float n21 =  J0Delta.x - a.x;
    float n22 =  J0Delta.y - a.y;
    float detJ0 = n11 * n22 - n12 * n21;

    if (abs(detJp) < 1e-20) { R.status = (R.status != 0 ? R.status : NewtonResultStatus::Singular); R.detJ = 0.0; }
    else                    { R.detJ = abs(detJ0 / detJp); }

    if (R.iters >= maxIters) R.status = (success ? NewtonResultStatus::Success : NewtonResultStatus::NoConverge);
    // Reject too large a Jacobian change (after the iteration check, which must not restore Success).
    if (R.detJ >= 10.0 || R.detJ < 0.1) R.status = (NewtonResultStatus::NoConverge);
    return R;
}
