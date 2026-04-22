import SurfaceOpsInterface;

// Doppler / path-velocity condition on a local plane.
//
// Geometry:
//   X(eta) = x0 + eta.x * t + eta.y * b
//
// Velocity scalar (constant velocities wrt eta):
//   V(eta) = d/dt |p1 - X| + d/dt |p2 - X|
//         = dot(u1, w1) + dot(u2, w2)
//   where ri = pi - X, di = |ri|, ui = ri/di, wi = vi - v.
//
// Gradient (wrt eta):
//   ∇_X V_i = - w_i,perp / d_i
//   w_i,perp = (I - ui ui^T) wi = wi - (ui·wi) ui
//   g = [ dot(t, ∇_X V), dot(b, ∇_X V) ]
//
// Hessian (wrt eta): H = J^T (∇^2_X V) J, with J=[t b].
// We implement applyH(v) = (∇^2_X V_i) v via directional derivative:
//
// For one segment i, define:
//   c = ui·wi
//   wperp = wi - c ui
//   uv = ui·v
//   vperp = v - uv ui
//   vwperp = v·wperp
//
// Then:
//   (∇^2_X V_i) v = -( (vwperp) ui + c vperp + (uv) wperp ) / d^2
//
// Finally:
//   Hxx = t·applyH(t),  Hxy = t·applyH(b),  Hyy = b·applyH(b)  (summed over i=1,2).

export struct LocalPlaneOps : ISurfaceOps
{
    float3 p1;
    float3 p2;

    // velocities (assumed constant wrt eta)
    float3 v1;
    float3 v2;
    float3 v;   // plane point velocity

    float3 x0;
    float3 t;
    float3 b;

    float2 project(float2 eta)
    {
        return eta;
    }

    float3 X(float2 eta)
    {
        return x0 + eta.x * t + eta.y * b;
    }

    bool eval(float2 eta, out float V, out float2 g, out float3 H)
    {
        const float eps = 1e-20;

        float3 Xw = X(eta);

        // Accumulators
        float3 gradX = float3(0.0);
        float Hxx = 0.0;
        float Hxy = 0.0;
        float Hyy = 0.0;
        V = 0.0;

        // Inline "applyH" for one segment (pi, wi)
        // Returns (∇^2_X (dot(u, w))) vdir.
        // (No lambdas in Slang; we expand twice for vdir=t and vdir=b.)
        {
            // ----- Segment 1 -----
            float3 r = p1 - Xw;
            float d = max(length(r), eps);
            float invD = 1.0 / d;
            float invD2 = invD * invD;

            float3 u = r * invD;

            float3 w = v1 - v;

            float c = dot(u, w);
            float3 wperp = w - c * u;            // (I - u u^T) w

            // V contribution
            V += c;

            // gradX contribution: -wperp/d
            gradX += -(wperp * invD);

            // applyH(t)
            {
                float3 vdir = t;
                float uv = dot(u, vdir);
                float3 vperp = vdir - uv * u;            // (I - u u^T) v
                float vwperp = dot(vdir, wperp);

                float3 Hv = -((vwperp) * u + c * vperp + (uv) * wperp) * invD2;

                Hxx += dot(t, Hv);
                Hyy += 0.0; // nothing here; Hyy handled in applyH(b)
                Hxy += 0.0; // Hxy handled in applyH(b)
            }

            // applyH(b)
            {
                float3 vdir = b;
                float uv = dot(u, vdir);
                float3 vperp = vdir - uv * u;
                float vwperp = dot(vdir, wperp);

                float3 Hv = -((vwperp) * u + c * vperp + (uv) * wperp) * invD2;

                Hxy += dot(t, Hv);
                Hyy += dot(b, Hv);
            }
        }

        {
            // ----- Segment 2 -----
            float3 r = p2 - Xw;
            float d = max(length(r), eps);
            float invD = 1.0 / d;
            float invD2 = invD * invD;

            float3 u = r * invD;

            float3 w = v2 - v;

            float c = dot(u, w);
            float3 wperp = w - c * u;

            V += c;
            gradX += -(wperp * invD);

            // applyH(t)
            {
                float3 vdir = t;
                float uv = dot(u, vdir);
                float3 vperp = vdir - uv * u;
                float vwperp = dot(vdir, wperp);

                float3 Hv = -((vwperp) * u + c * vperp + (uv) * wperp) * invD2;

                Hxx += dot(t, Hv);
                Hyy += 0.0;
                Hxy += 0.0;
            }

            // applyH(b)
            {
                float3 vdir = b;
                float uv = dot(u, vdir);
                float3 vperp = vdir - uv * u;
                float vwperp = dot(vdir, wperp);

                float3 Hv = -((vwperp) * u + c * vperp + (uv) * wperp) * invD2;

                Hxy += dot(t, Hv);
                Hyy += dot(b, Hv);
            }
        }

        // Convert gradX -> grad wrt eta
        g = float2(dot(t, gradX), dot(b, gradX));

        // Pack Hessian wrt eta
        H = float3(Hxx, Hxy, Hyy);
        return true;
    }

    [mutating]
    void update(float2 eta)
    {
    }
};
