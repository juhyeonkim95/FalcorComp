import SurfaceOpsInterface;

export struct LocalPlaneOps:ISurfaceOps
{
    float3 p1;
    float3 p2;
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

    // Returns true on success. Outputs:
    //   L  = |p1 - X| + |p2 - X|
    //   g  = gradient wrt (eta.x, eta.y)
    //   H  = (Hxx, Hxy, Hyy) packed in a float3
    bool eval(float2 eta, out float L, out float2 g, out float3 H)
    {
        const float eps = 1e-20;

        float3 Xw = X(eta);
        float3 r1 = p1 - Xw;
        float3 r2 = p2 - Xw;

        float d1 = max(length(r1), eps);
        float d2 = max(length(r2), eps);

        float3 u1 = r1 * (1.0 / d1);
        float3 u2 = r2 * (1.0 / d2);

        L = d1 + d2;

        float3 s = u1 + u2;
        g = float2(-dot(t, s), -dot(b, s));

        // Helper inline function (no lambdas in Slang)
        // applyA(v) = (I - u1 u1^T) v / d1 + (I - u2 u2^T) v / d2
        float3 applyA_t = (t - dot(u1, t) * u1) * (1.0 / d1) + (t - dot(u2, t) * u2) * (1.0 / d2);
        float3 applyA_b = (b - dot(u1, b) * u1) * (1.0 / d1) + (b - dot(u2, b) * u2) * (1.0 / d2);

        float Hxx = dot(t, applyA_t);
        float Hxy = dot(t, applyA_b);
        float Hyy = dot(b, applyA_b);

        H = float3(Hxx, Hxy, Hyy);
        return true;
    }

    // dummy
    [mutating]
    void update(float2 eta)
    {

    }
};