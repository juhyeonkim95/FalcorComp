
import SurfaceOps.SurfaceOpsInterface;

// =============================================================
// Gauge mode
// =============================================================
enum GaugeMode : uint
{
    CONSTANT_A      = 0,
    ORTHO_GRAD_START= 1,
    ORTHO_AVG_GRAD  = 2,
};

enum NewtonResultStatus : uint
{
    SUCCESS         = 0,
    NO_CONVERGE     = 1,
    SINGULAR        = 2,
    INVALID_POINT   = 3,
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

bool finite_surface_eval(float L, float2 g, float3 H)
{
    return isfinite(L) && all(isfinite(g)) && all(isfinite(H));
}

bool regular_jacobian(float2 row0, float2 row1, float determinant)
{
    float scale = length(row0) * length(row1);
    return all(isfinite(row0)) && all(isfinite(row1)) && isfinite(scale) &&
        isfinite(determinant) && scale > 0.f &&
        abs(determinant) > max(1e-30f, 1e-7f * scale);
}

void inv2(float a,float b,float c,float d,
                 out float m00,out float m01,out float m10,out float m11,out float det)
{
    det = a * d - b * c;
    float inv = 1.0 / det;
    m00 =  d * inv; m01 = -b * inv;
    m10 = -c * inv; m11 =  a * inv;
}

// ----------------- gauge_terms (packed Hessians) -----------------
// Builds: a(η',η),   JpΔ = (∂a/∂xi')^T Δ,   J0Δ = (∂a/∂xi )^T Δ
void gauge_terms(
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

    if (mode == GaugeMode::CONSTANT_A)
    {
        a = a_const;
        JpDelta = float2(0.0, 0.0);
        J0Delta = float2(0.0, 0.0);
        return;
    }
    if (mode == GaugeMode::ORTHO_GRAD_START)
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

// Spatial reuse changes both foci and the length offset. Differentiate the
// source potential as well as the destination potential. Both Ops share a chart.
// avg_grad uses (K * grad L_source(u) + grad L_target(v)) / 2, so swapping
// source/target and using 1/K describes the same constraint in reverse.
NewtonResult solve_paired_shift<SurfaceOps : ISurfaceOps>(
    inout SurfaceOps source, inout SurfaceOps target, float2 u,
    float lengthOffset, float K, GaugeMode mode, float2 axis, int maxIters, float tol, float coordinateTol)
{
    NewtonResult result;
    result.xi_prime = u;
    result.detJ = 0.f;
    result.iters = 0;
    result.status = NewtonResultStatus::NO_CONVERGE;
    if (!(K > 0.f) || !isfinite(K) || !isfinite(lengthOffset) ||
        !(tol > 0.f) || !isfinite(tol) || !(coordinateTol > 0.f) || !isfinite(coordinateTol) || maxIters < 0 || !all(isfinite(u))) return result;
    float L0; float2 g0; float3 H0;
    source.initializeSource(u);
    if (!source.evalSource(u, L0, g0, H0) || !finite_surface_eval(L0, g0, H0))
    {
        result.status = NewtonResultStatus::INVALID_POINT;
        return result;
    }
    g0 *= K;
    H0 *= K;
    float goal = K * L0 + lengthOffset;
    float2 v = u;
    float L1; float2 g1; float3 H1;
    target.update(v);
    if (!target.evalTarget(v, L1, g1, H1) || !finite_surface_eval(L1, g1, H1))
    {
        result.status = NewtonResultStatus::INVALID_POINT;
        return result;
    }
    for (int iteration = 0; iteration <= maxIters; ++iteration)
    {
        float2 a, dTarget, dSource;
        gauge_terms(mode, axis, g0, g1, H0, H1, v - u, a, dTarget, dSource);
        float gaugeLength = length(a);
        if (!(gaugeLength > 0.f) || !isfinite(gaugeLength)) return result;
        float2 residual = float2(L1 - goal, dot(a, v - u));
        float2 rowTarget = a + dTarget;
        float detTarget = g1.x * rowTarget.y - g1.y * rowTarget.x;
        if (!regular_jacobian(g1, rowTarget, detTarget))
        {
            result.status = NewtonResultStatus::SINGULAR;
            return result;
        }
        if (!all(isfinite(float4(residual, detTarget, gaugeLength)))) return result;
        // Length and chart coordinates have different units (especially for
        // barycentrics and hemisphere angles). Normalize each constraint separately.
        float2 normalizedResidual = float2(residual.x / tol, residual.y / gaugeLength / coordinateTol);
        if (!all(isfinite(normalizedResidual))) return result;
        if (max(abs(normalizedResidual.x), abs(normalizedResidual.y)) <= 1.f)
        {
            float2 rowSource = dSource - a;
            float detSource = -g0.x * rowSource.y + g0.y * rowSource.x;
            if (!regular_jacobian(-g0, rowSource, detSource))
            {
                result.status = NewtonResultStatus::SINGULAR;
                return result;
            }
            float J = abs(detSource / detTarget);
            if (!(J > 0.f)) return result;
            if (!isfinite(J)) return result;
            result.xi_prime = v;
            result.detJ = J;
            result.status = NewtonResultStatus::SUCCESS;
            return result;
        }
        if (iteration == maxIters) break;
        float2 step = float2(rowTarget.y * residual.x - g1.y * residual.y,
                            -rowTarget.x * residual.x + g1.x * residual.y) / detTarget;
        if (!all(isfinite(step))) return result;
        // Backtrack on both residuals, not only path length.
        float merit = dot(normalizedResidual, normalizedResidual);
        bool accepted = false;
        float alpha = 1.f;
        for (uint trial = 0; trial < 6; ++trial)
        {
            float2 candidate = target.project(v - alpha * step);
            float Lt; float2 gt; float3 Ht;
            target.update(candidate);
            if (all(isfinite(candidate)) && target.evalTarget(candidate, Lt, gt, Ht) && finite_surface_eval(Lt, gt, Ht))
            {
                float2 at, dt, ds;
                gauge_terms(mode, axis, g0, gt, H0, Ht, candidate - u, at, dt, ds);
                float atLength = length(at);
                float2 rt = float2((Lt - goal) / tol, dot(at, candidate - u) / max(atLength, 1e-20f) / coordinateTol);
                if (atLength > 0.f && all(isfinite(rt)) && dot(rt, rt) < merit)
                {
                    v = candidate;
                    // The accepted trial already updated the surface and evaluated
                    // its derivatives. Reuse them on the next Newton iteration.
                    L1 = Lt;
                    g1 = gt;
                    H1 = Ht;
                    accepted = true;
                    break;
                }
            }
            alpha *= 0.5f;
        }
        result.iters = iteration + 1;
        if (!accepted) return result;
    }
    return result;
}

// Previous implementation retained for reference, disabled at user request.
/*
// One solver for all charts. F1 = L_target(xiPrime) - L_source(xi) - offset.
// avg_grad uses Rperp((grad L_source(xi) + grad L_target(xiPrime))/2).
// The caller handles any shrink factor in the length offset and final determinant.
// Single trial per iteration, with the original persistent damping factor.
NewtonResult solve_xi_prime_newton_det<SurfaceOps : ISurfaceOps>(
    inout SurfaceOps ops, float2 xi, float offset,
    GaugeMode mode, float2 axis, int maxIters, float tol, float coordinateTol = -1.f)
{
    if (coordinateTol < 0.f) coordinateTol = tol;
    NewtonResult result;
    result.xi_prime = xi;
    result.detJ = 0.f;
    result.iters = 0;
    result.status = NewtonResultStatus::NO_CONVERGE;
    if (!isfinite(offset) ||
        !(tol > 0.f) || !isfinite(tol) || !(coordinateTol > 0.f) || !isfinite(coordinateTol)) return result;

    ops.update(xi); // Initialize the shared hit before either potential is evaluated.
    float Ls; float2 gs; float3 Hs;
    if (!ops.evalSource(xi, Ls, gs, Hs) || !finite_surface_eval(Ls, gs, Hs)) return result;
    float goal = Ls + offset;
    float2 xiPrime = xi;
    float Lt; float2 gt; float3 Ht;
    if (!ops.evalTarget(xiPrime, Lt, gt, Ht) || !finite_surface_eval(Lt, gt, Ht)) return result;
    float beta = 1.f;
    for (int iteration = 0; iteration <= maxIters; ++iteration)
    {
        float2 a, dPrime, dXi;
        gauge_terms(mode, axis, gs, gt, Hs, Ht, xiPrime - xi, a, dPrime, dXi);
        float gaugeLength = length(a);
        if (!(gaugeLength > 0.f) || !isfinite(gaugeLength)) return result;
        float2 residual = float2(Lt - goal, dot(a, xiPrime - xi));
        float2 normalized = float2(residual.x / tol, residual.y / gaugeLength / coordinateTol);
        if (!all(isfinite(normalized))) return result;
        float2 rowPrime = a + dPrime;
        float detPrime = gt.x * rowPrime.y - gt.y * rowPrime.x;
        if (!regular_jacobian(gt, rowPrime, detPrime)) return result;
        if (max(abs(normalized.x), abs(normalized.y)) <= 1.f)
        {
            // F_xi: [-grad L_s(xi); (partial a/partial xi)^T*Delta - a].
            // F_xiPrime: [grad L_t(xiPrime); (partial a/partial xiPrime)^T*Delta + a].
            float2 rowXi = dXi - a;
            float detXi = -gs.x * rowXi.y + gs.y * rowXi.x;
            if (!regular_jacobian(-gs, rowXi, detXi)) return result;
            float J = abs(detXi / detPrime);
            if (!(J > 0.f) || !isfinite(J)) return result;
            result.xi_prime = xiPrime;
            result.detJ = J; // Caller applies any shrink factor afterward.
            result.status = NewtonResultStatus::SUCCESS;
            return result;
        }
        if (iteration == maxIters) break;
        float2 step = float2(rowPrime.y * residual.x - gt.y * residual.y,
                            -rowPrime.x * residual.x + gt.x * residual.y) / detPrime;
        if (!all(isfinite(step))) return result;
        float2 candidate = ops.project(xiPrime - beta * step);
        ops.update(candidate);
        float Ltrial; float2 gtrial; float3 Htrial;
        bool accepted = false;
        if (ops.evalTarget(candidate, Ltrial, gtrial, Htrial) && finite_surface_eval(Ltrial, gtrial, Htrial))
        {
            float2 trialA, dp, ds;
            gauge_terms(mode, axis, gs, gtrial, Hs, Htrial, candidate - xi, trialA, dp, ds);
            float trialGaugeLength = length(trialA);
            if (trialGaugeLength > 0.f && isfinite(trialGaugeLength))
            {
                float2 trialResidual = float2((Ltrial - goal) / tol,
                    dot(trialA, candidate - xi) / trialGaugeLength / coordinateTol);
                accepted = all(isfinite(trialResidual)) && dot(trialResidual, trialResidual) < dot(normalized, normalized);
            }
        }
        if (accepted)
        {
            xiPrime = candidate; Lt = Ltrial; gt = gtrial; Ht = Htrial;
            beta = min(1.f, 2.f * beta);
        }
        else beta *= .5f;
        result.iters = iteration + 1;
    }
    return result;
}
*/

// Restored from TimeGatedReSTIRInline copy/NewtonSolver.slang.
// g_source/H_source/L_source are source values; g_target/H_target/L_target are target values. K stays in the caller.
NewtonResult solve_xi_prime_newton_det<SurfaceOps : ISurfaceOps>(
    inout SurfaceOps ops,
    float2 xi, float lengthOffset,
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
    R.status = NewtonResultStatus::SUCCESS;

    const float epsDet = 1e-18;
    const float epsDir = 1e-12;
    const float ctol   = 1e-9;

    // Source values are fixed at xi. They contain only the two local edges.
    // Solve L_target(xi_prime) - L_source(xi) - lengthOffset = 0.
    // At K=1: lengthOffset = sourcePrefix-targetPrefix + targetTime-sourceTime.
    float  L_source; float2 g_source; float3 H_source;
    ops.initializeSource(xi); // Freeze source geometry; target trials cannot overwrite it.
    if(!ops.evalSource(xi, L_source, g_source, H_source) || !finite_surface_eval(L_source, g_source, H_source)){
        R.status = NewtonResultStatus::INVALID_POINT; return R;
    }
    
    float2 xi_prime = xi;
    // The initial target potential differs from the fixed source potential.
    float L_target; float2 g_target; float3 H_target;
    if (!ops.evalTarget(xi_prime, L_target, g_target, H_target) || !finite_surface_eval(L_target, g_target, H_target))
    {
        R.status = NewtonResultStatus::INVALID_POINT; R.detJ = 0.f; return R;
    }

    // Predictor: move orthogonal to starting gauge
    float2 a0 = (mode == GaugeMode::CONSTANT_A) ? a_const : Rperp(g_source);
    float2 dir = Rperp(a0);
    float n2 = max(dot(dir, dir), 1e-20);
    dir *= rsqrt(n2); // normalize
    
    // float g0dir = dot(g_source, dir);
    // float s0 = (abs(g0dir) > epsDir) ? (lengthOffset / g0dir) : 0.0;


    float2 a, JpDelta, J0Delta;
    float2 Delta;
    float inv00, inv01, inv10, inv11, detJp;
    // Even zero displacement still needs the source/target determinant below.
    bool success = abs(L_target - L_source - lengthOffset) <= tol;
    float beta = 1.0f;

    // --- Newton iterations using only Jp = ∂F/∂xi' ---
    for (int it = 0; it < maxIters && !success; ++it)
    {
        R.iters = it + 1;
        // ops.update(xi_prime);
        
        Delta = xi_prime - xi;
        gauge_terms(mode, a_const, g_source, g_target, H_source, H_target, Delta, a, JpDelta, J0Delta);

        // Current Residuals
        float F1 = L_target - L_source - lengthOffset;
        float F2 = dot(a, Delta);

        // Jp rows: [ g_target^T ; (a + JpDelta)^T ]
        float a11 = g_target.x, a12 = g_target.y;
        float b11 = a.x + JpDelta.x, b12 = a.y + JpDelta.y;

        detJp = a11 * b12 - a12 * b11;
        if (!isfinite(detJp) || abs(detJp) < epsDet) { R.status = NewtonResultStatus::SINGULAR; R.detJ = 0.0; return R; }
        inv2(a11, a12, b11, b12, inv00, inv01, inv10, inv11, detJp);
        // if (abs(F1) < tol && abs(F2) < tol) {success = true; break;}

        // Δxi' = - Jp^{-1} F
        float rhs1 = -F1, rhs2 = -F2;
        float dx = inv00 * rhs1 + inv01 * rhs2;
        float dy = inv10 * rhs1 + inv11 * rhs2;

        // Trial update with current β
        float  L_try; float2 g_try; float3 H_try;
        const float2 xi_prime_trial = ops.project(float2(xi_prime.x + beta*dx, xi_prime.y + beta*dy) );
        ops.update(xi_prime_trial);
        bool valid_target = ops.evalTarget(xi_prime_trial, L_try, g_try, H_try);
        float F1_try = L_try - L_source - lengthOffset;

        if(!valid_target || !finite_surface_eval(L_try, g_try, H_try) || (abs(F1_try) > abs(F1))){
            beta *= 0.5f;
        } else {
            xi_prime = xi_prime_trial;
            L_target = L_try;
            g_target = g_try;
            H_target = H_try;
            beta = min(1.0, beta * 2.0f);
            if(abs(F1_try) < tol){
                success = true;
                break;
            }
        }
    }
    // Final point
    R.xi_prime = xi_prime;
    ops.update(xi_prime); // Restore the accepted ray hit after a rejected trial.

    Delta = xi_prime - xi;
    gauge_terms(mode, a_const, g_source, g_target, H_source, H_target, Delta, a, JpDelta, J0Delta);
    // Jp rows: [ g_target^T ; (a + JpDelta)^T ]
    float a11 = g_target.x, a12 = g_target.y;
    float b11 = a.x + JpDelta.x, b12 = a.y + JpDelta.y;
    detJp = a11 * b12 - a12 * b11;

    // J0: row1 = -g_source^T; row2 = (∂a/∂xi)^T Δ - a
    float n11 = -g_source.x, n12 = -g_source.y;
    float n21 =  J0Delta.x - a.x;
    float n22 =  J0Delta.y - a.y;
    float detJ0 = n11 * n22 - n12 * n21;

    if (!isfinite(detJp) || abs(detJp) < 1e-20 || !isfinite(detJ0))
    {
        R.status = NewtonResultStatus::SINGULAR; R.detJ = 0.f; return R;
    }
    R.detJ = abs(detJ0 / detJp);
    if (!(R.detJ > 0.f) || !isfinite(R.detJ))
    {
        R.status = NewtonResultStatus::SINGULAR; R.detJ = 0.f; return R;
    }
    // Preserve the original determinant cutoff and length-only convergence.
    R.status = success && R.detJ >= .1f && R.detJ < 10.f
        ? NewtonResultStatus::SUCCESS : NewtonResultStatus::NO_CONVERGE;
    return R;
}
