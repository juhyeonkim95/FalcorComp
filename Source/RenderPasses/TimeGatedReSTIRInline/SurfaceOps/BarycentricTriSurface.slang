import SurfaceOpsInterface;

// Distance from two points p1, p2 to a point X on a triangle parameterized by barycentric (coordinates.x, coordinates.y).
// Triangle vertices: v0, v1, v2 (triposW0,1,2).
export struct BarycentricTriOps : ISurfaceOps
{
    float3 p1; // preceding vertex
    float3 p2;

    float3 v0; // triposW0
    float3 v1; // triposW1
    float3 v2; // triposW2

    // Do not clamp onto triangle edges: that would collapse the 2D mapping.
    // The caller checks that the solved point belongs to this triangle.
    __init(float3 p1, float3 p2, float3 v0, float3 v1, float3 v2)
    {
        this.p1 = p1; this.p2 = p2;
        this.v0 = v0;
        this.v1 = v1;
        this.v2 = v2;
    }

    float2 project(float2 coordinates)
    {
        return coordinates;
    }

    // Barycentric parameterization:
    // coordinates.x = b1, coordinates.y = b2, b0 = 1 - b1 - b2.
    float3 X(float2 coordinates)
    {
        float b1 = coordinates.x;
        float b2 = coordinates.y;
        float b0 = 1.0 - b1 - b2;
        return b0 * v0 + b1 * v1 + b2 * v2;
        // equivalently: return v0 + b1 * (v1 - v0) + b2 * (v2 - v0);
    }

    // Evaluate L = |p1 - X| + |p2 - X| and its gradient/Hessian w.r.t. (coordinates.x, coordinates.y).
    bool eval(float2 coordinates, out float L, out float2 g, out float3 H)
    {
        const float eps = 1e-8f;
        L = 0.f; g = float2(0.f); H = float3(0.f);
        if (!all(isfinite(coordinates))) return false;

        // Current point on triangle
        float3 Xw = X(coordinates);

        // Vectors to the two endpoints
        float3 r1 = p1 - Xw;
        float3 r2 = p2 - Xw;

        float d1 = length(r1);
        float d2 = length(r2);
        if (!(d1 > eps) || !(d2 > eps) || !isfinite(d1 + d2)) return false;

        float3 u1 = r1 * (1.0 / d1); // unit direction from X -> p1
        float3 u2 = r2 * (1.0 / d2); // unit direction from X -> p2

        L = d1 + d2;

        // Tangent directions of the parameterization on the triangle
        float3 e1 = v1 - v0; // ∂X/∂coordinates.x
        float3 e2 = v2 - v0; // ∂X/∂coordinates.y

        // Gradient: g = [∂L/∂coordinates.x, ∂L/∂coordinates.y]
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
        return isfinite(L) && all(isfinite(g)) && all(isfinite(H));
    }

    [mutating]
    void update(float2 coordinates)
    {
        // no-op for now
    }
};
