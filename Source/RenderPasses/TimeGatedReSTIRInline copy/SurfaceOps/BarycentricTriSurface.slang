import SurfaceOpsInterface;

// Distance from two points p1, p2 to a point X on a triangle parameterized by barycentric (eta.x, eta.y).
// Triangle vertices: v0, v1, v2 (triposW0,1,2).
export struct BarycentricTriOps : ISurfaceOps
{
    float3 p1;
    float3 p2;

    float3 v0; // triposW0
    float3 v1; // triposW1
    float3 v2; // triposW2

    // Optional: you can clamp/project eta into the barycentric domain here if you want.
    float2 project(float2 eta)
    {
        return eta;
    }

    // Barycentric parameterization:
    // eta.x = b1, eta.y = b2, b0 = 1 - b1 - b2.
    float3 X(float2 eta)
    {
        float b1 = eta.x;
        float b2 = eta.y;
        float b0 = 1.0 - b1 - b2;
        return b0 * v0 + b1 * v1 + b2 * v2;
        // equivalently: return v0 + b1 * (v1 - v0) + b2 * (v2 - v0);
    }

    // Evaluate L = |p1 - X| + |p2 - X| and its gradient/Hessian w.r.t. (eta.x, eta.y).
    bool eval(float2 eta, out float L, out float2 g, out float3 H)
    {
        const float eps = 1e-20;

        // Current point on triangle
        float3 Xw = X(eta);

        // Vectors to the two endpoints
        float3 r1 = p1 - Xw;
        float3 r2 = p2 - Xw;

        float d1 = max(length(r1), eps);
        float d2 = max(length(r2), eps);

        float3 u1 = r1 * (1.0 / d1); // unit direction from X -> p1
        float3 u2 = r2 * (1.0 / d2); // unit direction from X -> p2

        L = d1 + d2;

        // Tangent directions of the parameterization on the triangle
        float3 e1 = v1 - v0; // ∂X/∂eta.x
        float3 e2 = v2 - v0; // ∂X/∂eta.y

        // Gradient: g = [∂L/∂eta.x, ∂L/∂eta.y]
        // ∂L/∂X = -(u1 + u2) = -s
        float3 s = u1 + u2;
        g = float2(-dot(e1, s), -dot(e2, s));

        // Hessian: H_ij = e_i^T A e_j, where
        // A = (I - u1 u1^T) / d1 + (I - u2 u2^T) / d2
        float3 applyA_e1 = (e1 - dot(u1, e1) * u1) * (1.0 / d1)
                         + (e1 - dot(u2, e1) * u2) * (1.0 / d2);
        float3 applyA_e2 = (e2 - dot(u1, e2) * u1) * (1.0 / d1)
                         + (e2 - dot(u2, e2) * u2) * (1.0 / d2);

        float Hxx = dot(e1, applyA_e1);
        float Hxy = dot(e1, applyA_e2);
        float Hyy = dot(e2, applyA_e2);

        H = float3(Hxx, Hxy, Hyy);
        return true;
    }

    [mutating]
    void update(float2 eta)
    {
        // no-op for now
    }
};
