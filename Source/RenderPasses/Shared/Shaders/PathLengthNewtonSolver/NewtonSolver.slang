
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

// Restored constant-offset solver: c is held fixed for the Jacobian.
NewtonResult solve_xi_prime_newton_det<SurfaceOps : ISurfaceOps>(
    inout SurfaceOps ops,
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
    R.status = NewtonResultStatus::SUCCESS;

    const float epsDet = 1e-18;
    const float epsDir = 1e-12;
    const float ctol   = 1e-9;

    // Start eval (fixed during solve)
    float  L0; float2 g0; float3 H0;
    // ops.update(xi);
    if(!ops.eval(xi, L0, g0, H0)){
        R.status = NewtonResultStatus::INVALID_POINT; return R;
    }

    // no need to search
    if (abs(c) <= tol)
    {
        R.xi_prime = xi;
        R.detJ = 1.0;
        return R;
    }

    // Predictor: move orthogonal to starting gauge
    float2 a0 = (mode == GaugeMode::CONSTANT_A) ? a_const : Rperp(g0);
    float2 dir = Rperp(a0);
    float n2 = max(dot(dir, dir), 1e-20);
    dir *= rsqrt(n2); // normalize

    // float g0dir = dot(g0, dir);
    // float s0 = (abs(g0dir) > epsDir) ? (c / g0dir) : 0.0;
    float2 e = xi; //ops.project(xi + s0 * dir);

    float  L1 = L0; float2 g1 = g0; float3 H1 = H0;
    float2 a, JpDelta, J0Delta;
    float2 Delta;
    float inv00, inv01, inv10, inv11, detJp;
    bool success = false;
    float beta = 1.0f;

    // --- Newton iterations using only Jp = ∂F/∂η' ---
    for (int it = 0; it < maxIters; ++it)
    {
        R.iters = it + 1;
        // ops.update(e);

        Delta = e - xi;
        gauge_terms(mode, a_const, g0, g1, H0, H1, Delta, a, JpDelta, J0Delta);

        // Current Residuals
        float F1 = L1 - L0 - c;
        float F2 = dot(a, Delta);

        // Jp rows: [ g1^T ; (a + JpDelta)^T ]
        float a11 = g1.x, a12 = g1.y;
        float b11 = a.x + JpDelta.x, b12 = a.y + JpDelta.y;

        inv2(a11, a12, b11, b12, inv00, inv01, inv10, inv11, detJp);
        if (abs(detJp) < epsDet) { R.status = NewtonResultStatus::SINGULAR; R.detJ = 0.0; return R; }
        // if (abs(F1) < tol && abs(F2) < tol) {success = true; break;}

        // Δη' = - Jp^{-1} F
        float rhs1 = -F1, rhs2 = -F2;
        float dx = inv00 * rhs1 + inv01 * rhs2;
        float dy = inv10 * rhs1 + inv11 * rhs2;

        // Trial update with current β
        float  L_try; float2 g_try; float3 H_try;
        const float2 e_try = ops.project(float2(e.x + beta*dx, e.y + beta*dy) );
        ops.update(e_try);
        bool update_eta = ops.eval(e_try, L_try, g_try, H_try);
        float F1_try = L_try - L0 - c;

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


        // Delta = e - xi;
        // gauge_terms(mode, a_const, g0, g1, H0, H1, Delta, a, JpDelta, J0Delta);
        // if(!update_eta || F1_try > F1){
        //     beta *= 0.5f;
        // } else {
        //     e = e_try;
        // }
        // e = ops.project(e + float2(dx, dy));
    }
    // Final point
    R.xi_prime = e;

    Delta = e - xi;
    gauge_terms(mode, a_const, g0, g1, H0, H1, Delta, a, JpDelta, J0Delta);
    // Jp rows: [ g1^T ; (a + JpDelta)^T ]
    float a11 = g1.x, a12 = g1.y;
    float b11 = a.x + JpDelta.x, b12 = a.y + JpDelta.y;
    inv2(a11, a12, b11, b12, inv00, inv01, inv10, inv11, detJp);

    // J0: row1 = -g0^T; row2 = (∂a/∂η)^T Δ - a
    float n11 = -g0.x, n12 = -g0.y;
    float n21 =  J0Delta.x - a.x;
    float n22 =  J0Delta.y - a.y;
    float detJ0 = n11 * n22 - n12 * n21;

    if (abs(detJp) < 1e-20) { R.status = (R.status != 0 ? R.status : NewtonResultStatus::SINGULAR); R.detJ = 0.0; }
    else                    { R.detJ = abs(detJ0 / detJp); }

    // reject too large jacobian change
    if (R.detJ >= 10.0 || R.detJ < 0.1) R.status = (NewtonResultStatus::NO_CONVERGE);
    if (R.iters >= maxIters) R.status = (success ? NewtonResultStatus::SUCCESS : NewtonResultStatus::NO_CONVERGE);
    return R;
}
