import SurfaceOpsInterface;
// import Scene.Raytracing;
// import Scene.Intersection;
import Scene.RaytracingInline;
// import LoadShadingData;

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

export struct RayTraceHemisphereOps:ISurfaceOps
{
    // Geometry
    float3 p1, p2, p2o;        // endpoints for L
    float3 t2, b2, n2;    // TBN at p2 (for hemisphere directions)

    HitInfo hit;
    float hitT;

    __init(float3 p1, float3 p2, float3 p2o, float3 t2, float3 b2, float3 n2){
        this.p1 = p1;
        this.p2 = p2;
        this.p2o = p2o;
        this.t2 = t2;
        this.b2 = b2;
        this.n2 = n2;
    }

    // Domain projection: mu in [0,1], psi in [0,1)
    float2 project(float2 eta)
    {
        float mu  = clamp(eta.x, 0.0, 1.0);
        float psi = frac(eta.y);
        return float2(mu, psi);
    }

    // --- hemisphere direction (LOCAL) ---
    static float3 dir_local(float mu, float psi)
    {
        float s_mu = sqrt(max(1.0 - mu*mu, 0.0));
        float cphi = cos(M_2PI * psi), sphi = sin(M_2PI * psi);
        return float3(s_mu * cphi, s_mu * sphi, mu);
    }

    // --- hemisphere direction (LOCAL) and partials wrt (mu, psi) ---
    static void dir_partials_local(
        float mu, float psi,
        out float3 dL, out float3 dL_mu, out float3 dL_psi,
        out float3 dL_mumu, out float3 dL_mupsi, out float3 dL_psipsi)
    {
        float s_mu = sqrt(max(1.0 - mu*mu, 0.0));
        float cphi = cos(M_2PI * psi), sphi = sin(M_2PI * psi);

        dL = float3(s_mu * cphi, s_mu * sphi, mu);

        float inv = (s_mu > 0.0) ? (1.0 / s_mu) : 0.0;
        float q   = -mu * inv;

        dL_mu   = float3(q * cphi, q * sphi, 1.0);
        dL_psi  = M_2PI * float3(-s_mu * sphi, s_mu * cphi, 0.0);

        // second partials of d
        float inv3 = (s_mu > 0.0) ? (inv * inv * inv) : 0.0; // d^2 sqrt(1-mu^2)/dmu^2 = -(1-mu^2)^(-3/2)
        dL_mumu   = float3(-cphi * inv3, -sphi * inv3, 0.0);
        dL_mupsi  = M_2PI * float3((mu * inv) * sphi, -(mu * inv) * cphi, 0.0);
        dL_psipsi = (M_2PI * M_2PI) * float3(-s_mu * cphi, -s_mu * sphi, 0.0);
    }

    // local->world (columns are TBN at p2)
    float3 to_world(float3 vL) { return vL.x * t2 + vL.y * b2 + vL.z * n2; }

    // --- Apply A(v) = (I-u1u1^T)v/d1 + (I-u2u2^T)v/d2 without forming A
    static float3 apply_A(float3 v, float3 u1, float d1, float3 u2, float d2)
    {
        return (v - dot(u1, v) * u1) * (1.0 / d1)
             + (v - dot(u2, v) * u2) * (1.0 / d2);
    }
    
    [mutating]
    void update(float2 eta)
    {
        float2 et = project(eta);
        float3 dL = dir_local(et.x, et.y);
        float3 d  = to_world(dL); // unit

        Ray ray = Ray(p2o, d, 0.0f, FLT_MAX);
        SceneRayQuery<0> sceneRayQuery;
        hit = sceneRayQuery.traceRay(ray, hitT);
    }

    // ---- eval: uses si.t as ρ, with derivatives from frozen plane at (si.p, si.n) ----
    bool eval(float2 eta, out float L, out float2 g, out float3 H)
    {
        if(!hit.isValid() || hitT < 1e-4){
            return false;
        }
        
        // direction + partials in world
        float2 e = project(eta);
        float3 dL, dL_mu, dL_psi, dL_mumu, dL_mupsi, dL_psipsi;
        dir_partials_local(e.x, e.y, dL, dL_mu, dL_psi, dL_mumu, dL_mupsi, dL_psipsi);

        float3 d       = to_world(dL);
        float3 d_mu    = to_world(dL_mu);
        float3 d_psi   = to_world(dL_psi);
        float3 d_mumu  = to_world(dL_mumu);
        float3 d_mupsi = to_world(dL_mupsi);
        float3 d_psipsi= to_world(dL_psipsi);

        
        VertexData v = gScene.getVertexData(hit.getTriangleHit());

        float3 x = v.posW;
        bool frontFacing = dot(d, v.faceNormalW) >= 0.f;
        float3 n = frontFacing ? v.faceNormalW : -v.faceNormalW;
        float  r = length(p2 - x);
        // max(hitT, 1e-20);

        // plane factors at hit
        float  s0     = max(dot(n, d), 1e-20);
        float  s_mu   = dot(n, d_mu);
        float  s_psi  = dot(n, d_psi);
        float  s_mumu = dot(n, d_mumu);
        float  s_mupsi= dot(n, d_mupsi);
        float  s_pp   = dot(n, d_psipsi);

        // Jacobian columns: T_i = r ( d_i - (s_i/s0) d )
        float3 T_mu   = r * (d_mu  - (s_mu  / s0) * d);
        float3 T_psi  = r * (d_psi - (s_psi / s0) * d);

        // Second derivatives X_ij
        float3 X_mumu   = r * ( d_mumu   - (s_mu  / s0) * d_mu
                                              - (s_mu  / s0) * d_mu
                                              - (s_mumu/ s0) * d
                                              + 2.0 * (s_mu * s_mu)   / (s0 * s0) * d );
        float3 X_mupsi  = r * ( d_mupsi  - (s_mu  / s0) * d_psi
                                              - (s_psi / s0) * d_mu
                                              - (s_mupsi/ s0) * d
                                              + 2.0 * (s_mu * s_psi) / (s0 * s0) * d );
        float3 X_psipsi = r * ( d_psipsi - (s_psi / s0) * d_psi
                                              - (s_psi / s0) * d_psi
                                              - (s_pp   / s0) * d
                                              + 2.0 * (s_psi * s_psi) / (s0 * s0) * d );

        // Path geometry at hit
        float3 r1 = p1 - x;
        float3 r2 = p2 - x;
        float  d1 = length(r1); // max(, 1e-20);
        float  d2 = length(r2); // max(length(r2), 1e-20);
        float3 u1 = normalize(r1);//r1 * (1.0 / d1);
        float3 u2 = normalize(r2);// * (1.0 / d2);

        float3 svec = u1 + u2; // = -∇_x L(x)

        // Gradient on chart: g = J^T (-s)
        g.x = -dot(T_mu,  svec);
        g.y = -dot(T_psi, svec);

        // Hessian on chart: H = J^T A J + Q,   Q_ij = (-s)·X_ij
        float3 AJ_mu  = apply_A(T_mu,  u1, d1, u2, d2);
        float3 AJ_psi = apply_A(T_psi, u1, d1, u2, d2);

        float jtaj00 = dot(T_mu,  AJ_mu);
        float jtaj01 = dot(T_mu,  AJ_psi);
        float jtaj11 = dot(T_psi, AJ_psi);

        float q11 = -dot(svec, X_mumu);
        float q12 = -dot(svec, X_mupsi);
        float q22 = -dot(svec, X_psipsi);

        // (Hxx, Hxy, Hyy)
        H = float3(jtaj00 + q11, jtaj01 + q12, jtaj11 + q22);

        // Objective L = |p1-x| + |p2-x|
        L = d1 + d2;
        return true;
    }
}