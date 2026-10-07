
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
    BranchRejected = 4, // A root on another branch than the start's (see solveShiftNewton).
    Unreachable    = 5, // The target length is below the shortest path over the chart: no solution.
};


// =============================================================
// Result struct
// =============================================================
struct NewtonResult
{
    float2 xi_prime;
    float  detJ;       // |det d xi' / d xi|
    float  signedDetJ; // det d xi' / d xi
    int    iters;
    NewtonResultStatus    status;   // 0 OK, 1 no converge, 2 singular Jacobian
};

// The path-length condition of a shift. A full path length is L = ell(x) + rest: ell(x) = |a - x| + |y - x| is the two
// segments at the moved vertex x, rest is the remainder (the prefix up to a plus the suffix from y). The target path
// through x' is as far from its gate center g_t as the source path through x is from g_s, scaled by K:
//     L_t(x') - g_t = K (L_s(x) - g_s)   <=>   ell_t(x') = K (ell_s(x) + rest_s - g_s) + g_t - rest_t.
struct ShiftLengthCondition
{
    float K;          // Gate-width ratio (target / source); 1 for gates of equal width.
    float sourceGate; // g_s
    float targetGate; // g_t
    float sourceRest; // rest_s: the source path's prefix up to a_s plus its suffix from y_s.
    float targetRest; // rest_t: the target path's prefix up to a_t plus its suffix from y_t.

    // ell_t(x') required by the source path's ell_s(x).
    float targetLength(float sourceLength)
    {
        return K * (sourceLength + sourceRest - sourceGate) + targetGate - targetRest;
    }
};

// ell_t(x') = ell_s(x) + dt: a fixed length change (e.g. antithetic sampling with the same endpoints).
ShiftLengthCondition makeLengthOffset(float dt)
{
    ShiftLengthCondition condition = { 1.f, 0.f, dt, 0.f, 0.f };
    return condition;
}

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
// G is the chart's metric (see IShiftChart.metric). The gradient gauges move along G^-1 g, the steepest direction on
// the surface, whatever the chart's coordinates: a = c G R g with c = det(G)^-1/2, which keeps a . Δ a length (in
// orthonormal coordinates G = I, c = 1 and a = R g).
void gaugeTerms(
    GaugeMode mode,
    float2 a_const,
    float3 G,
    float2 g0, float2 g1,
    float3 H0, float3 H1,
    float2 Delta,
    out float2 a,
    out float2 JpDelta,
    out float2 J0Delta)
{
    if (mode == GaugeMode::Constant)
    {
        a = a_const;
        JpDelta = float2(0.0, 0.0);
        J0Delta = float2(0.0, 0.0);
        return;
    }
    // Exactly 1 for orthonormal coordinates.
    float c = all(G == float3(1.f, 0.f, 1.f)) ? 1.f : 1.f / sqrt(G.x * G.z - G.y * G.y);
    float2 RGDel = Rperp(Hmul(G, Delta));
    if (mode == GaugeMode::OrthoGradStart)
    {
        a = c * Hmul(G, Rperp(g0));
        JpDelta = float2(0.0, 0.0);
        // (∂a/∂xi)^T Δ = c (G R H0)^T Δ = - c H0 R (G Δ)
        J0Delta = float2(0.0, 0.0) - c * Hmul(H0, RGDel);
        return;
    }

    // ORTHO_AVG_GRAD
    a = c * Hmul(G, Rperp(0.5 * (g0 + g1)));
    // (∂a/∂xi')^T Δ = -0.5 c H1 R (G Δ)
    JpDelta = float2(0.0, 0.0) - 0.5 * c * Hmul(H1, RGDel);
    // (∂a/∂xi )^T Δ = -0.5 c H0 R (G Δ)
    J0Delta = float2(0.0, 0.0) - 0.5 * c * Hmul(H0, RGDel);
}

// Solves ell_t(xi') = condition.targetLength(ell_s(xi)) with the gauge a . (xi' - xi) = 0. xi is the source vertex in
// sourceOps's coordinates (sourceOps evaluates the source path's two segments ell_s, and its state represents the
// source vertex); xi' is in ops's coordinates (the target path's ell_t). The gauge compares the raw coordinates, and
// the avg_grad gauge a = R (g_s(xi) + g_t(xi')) / 2 is symmetric under swapping the roles, so the reverse shift (charts
// and conditions swapped) has the same solutions. The source rows of the Jacobian (d/dxi) use ell_s's gradient g_s
// and Hessian H_s at xi.
//   - traceStart = false: ops's state at xi already represents the source vertex (both charts are the same function).
//   - traceStart = true: the charts differ; ops's start point X_t(xi) is another surface point, traced here.
// Without a distinct source (distinctSource = false), ops and sourceOps are the same function (same endpoints and
// chart): ell_s = ell_t and g_s = g_t, the single-length solve.
// The equations have several roots (e.g. avg_grad always has a second one, where the gradients at both ends cancel),
// and Newton finds the one its start leads to: the forward shift starts at xi, the reverse at xi'. So that they find
// each other, the solve converges both equations, and accepts a root only on its start's branch: the path lengths
// change the same way along the move at both ends (the chord rule), and the map keeps the orientation. Both rules are
// symmetric, so the forward and reverse shifts accept and reject the same pairs.
NewtonResult solveShiftNewton<Chart : IShiftChart>(
    inout Chart ops,
    Chart sourceOps,
    bool distinctSource,
    bool traceStart,
    ShiftLengthCondition condition,
    float2 xi,
    GaugeMode mode,
    float2 a_const,          // used iff CONSTANT_A
    int maxIters,            // e.g., 10
    float tol                // e.g., 1e-6
)
{
    NewtonResult R;
    R.xi_prime = xi;
    R.detJ = 1.0;
    R.signedDetJ = 1.0;
    R.iters = 0;
    R.status = NewtonResultStatus::Success;

    const float epsDet = 1e-18;

    // Start eval (fixed during solve)
    float  L0; float2 g0; float3 H0;
    if (traceStart) ops.update(xi);
    if(!ops.eval(xi, L0, g0, H0)){
        R.status = NewtonResultStatus::InvalidPoint; return R;
    }
    // Source length at the start: g0/H0 below are the source's gradient and Hessian.
    float2 gt0 = g0; float3 Ht0 = H0;
    float Ls = L0;
    if (distinctSource)
    {
        if (!sourceOps.eval(xi, Ls, g0, H0)) { R.status = NewtonResultStatus::InvalidPoint; return R; }
    }
    float targetValue = condition.targetLength(Ls);
    // A target below the shortest path over the chart's surface has no solution: stop before iterating (on planes,
    // about half of the failed solves, which would otherwise iterate until the step stalls). The margin keeps every
    // target that a solve could reach within tol, so this rejects no shift that could succeed.
    if (targetValue < ops.lengthLowerBound() - 2.f * tol)
    {
        R.status = NewtonResultStatus::Unreachable;
        return R;
    }
    const float3 G = ops.metric();

    // no need to search (a distinct source needs the Jacobian of its map even where xi' = xi)
    if (abs(targetValue - L0) <= tol && !distinctSource)
    {
        R.xi_prime = xi;
        R.detJ = 1.0;
        return R;
    }

    float2 e = xi;
    float  L1 = L0; float2 g1 = gt0; float3 H1 = Ht0;
    float2 a, JpDelta, J0Delta;
    float2 Delta;
    float inv00, inv01, inv10, inv11, detJp;
    // At the start Delta = 0, so the gauge residual F2 is 0 for every gauge.
    float F1 = L1 - targetValue;
    float F2 = 0.f;
    float merit = abs(F1);
    // Where the start already has the target length, xi' = xi solves both equations; only the Jacobian is needed.
    bool success = merit <= tol;
    float beta = 1.0f;

    // --- Newton iterations using only Jp = ∂F/∂η' ---
    for (int it = 0; it < maxIters && !success; ++it)
    {
        R.iters = it + 1;

        Delta = e - xi;
        gaugeTerms(mode, a_const, G, g0, g1, H0, H1, Delta, a, JpDelta, J0Delta);

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
        float F1_try = L_try - targetValue;
        float F2_try = 0.f;
        if (update_eta)
        {
            float2 a_try, JpD_try, J0D_try;
            gaugeTerms(mode, a_const, G, g0, g_try, H0, H_try, e_try - xi, a_try, JpD_try, J0D_try);
            F2_try = dot(a_try, e_try - xi);
        }
        // Both equations in the merit: a step may not trade the gauge for the length. Both are lengths: F2 is the
        // gauge vector (a chart gradient for grad and avg_grad) times a coordinate offset.
        float merit_try = max(abs(F1_try), abs(F2_try));

        if(!update_eta || !(merit_try <= merit)){
            beta *= 0.5f;
            // Halved six times in a row: no descent near here (e.g. a target below the length's minimum), so stop.
            if (beta < 1.f / 32.f) break;
        } else {
            e = e_try;
            L1 = L_try;
            g1 = g_try;
            H1 = H_try;
            F1 = F1_try;
            F2 = F2_try;
            merit = merit_try;
            beta = min(1.0, beta * 2.0f);
            if(merit < tol){
                success = true;
                break;
            }
        }
    }
    // Final point
    R.xi_prime = e;

    Delta = e - xi;
    gaugeTerms(mode, a_const, G, g0, g1, H0, H1, Delta, a, JpDelta, J0Delta);
    // Jp rows: [ g1^T ; (a + JpDelta)^T ]
    float a11 = g1.x, a12 = g1.y;
    float b11 = a.x + JpDelta.x, b12 = a.y + JpDelta.y;
    inv2(a11, a12, b11, b12, inv00, inv01, inv10, inv11, detJp);

    // J0: row1 = -g0^T; row2 = (∂a/∂η)^T Δ - a
    float n11 = -g0.x, n12 = -g0.y;
    float n21 =  J0Delta.x - a.x;
    float n22 =  J0Delta.y - a.y;
    float detJ0 = n11 * n22 - n12 * n21;

    if (abs(detJp) < 1e-20)
    {
        R.status = (R.status != 0 ? R.status : NewtonResultStatus::Singular);
        R.detJ = 0.0;
        R.signedDetJ = 0.0;
    }
    else
    {
        R.signedDetJ = detJ0 / detJp;
        R.detJ = abs(R.signedDetJ);
    }

    if (!success) R.status = NewtonResultStatus::NoConverge;
    // Reject too large a Jacobian change (after the iteration check, which must not restore Success).
    if (R.detJ >= 10.0 || R.detJ < 0.1) R.status = (NewtonResultStatus::NoConverge);
    if (R.status != NewtonResultStatus::Success) return R;

    // Root selection. The forward solve starts at xi and the reverse at xi', and each finds the root on its own branch;
    // they are inverse only when both points are on one branch of both lengths. Both rules are symmetric: the reverse
    // shift evaluates the same quantities with the roles swapped. A root on another branch reverses the orientation,
    // or the chord crosses a minimum of one of the lengths.
    if (!(R.signedDetJ > 0.f))
    {
        R.status = NewtonResultStatus::BranchRejected;
        return R;
    }
    if (any(Delta != 0.f))
    {
        // The source length's gradient at xi' (in the target's chart unless the charts differ).
        float2 gs1 = g1;
        if (distinctSource)
        {
            float Ld; float3 Hd;
            bool valid;
            if (traceStart)
            {
                Chart sourceAtEnd = sourceOps;
                sourceAtEnd.update(e);
                valid = sourceAtEnd.eval(e, Ld, gs1, Hd);
            }
            else
            {
                Chart sourceAtEnd = ops;
                sourceAtEnd.setEndpoints(sourceOps.firstEndpoint(), sourceOps.secondEndpoint());
                valid = sourceAtEnd.eval(e, Ld, gs1, Hd);
            }
            if (!valid) { R.status = NewtonResultStatus::BranchRejected; return R; }
        }
        // ell_s and ell_t at xi and xi' change the same way along the chord.
        float4 slopes = float4(dot(g0, Delta), dot(gt0, Delta), dot(g1, Delta), dot(gs1, Delta));
        if (!(all(slopes > 0.f) || all(slopes < 0.f)))
            R.status = NewtonResultStatus::BranchRejected;
    }
    return R;
}
