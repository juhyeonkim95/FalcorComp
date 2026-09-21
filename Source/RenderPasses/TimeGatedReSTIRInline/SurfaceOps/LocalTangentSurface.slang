import SurfaceOpsInterface;

export struct LocalPlaneOps: ISurfaceOps
{
    float3 p1; // target preceding vertex
    float3 sourceP1; // source preceding vertex
    float3 p2;
    float3 x0;
    float3 t;
    float3 b;

    // Legacy construction describes a single potential (source = target).
    __init(float3 p1, float3 p2, float3 x0, float3 t, float3 b)
    {
        this.p1 = p1; this.sourceP1 = p1; this.p2 = p2;
        this.x0 = x0;
        this.t = t;
        this.b = b;
    }

    __init(float3 sourceP1, float3 targetP1, float3 p2, float3 x0, float3 t, float3 b)
    {
        this.p1 = targetP1; this.sourceP1 = sourceP1; this.p2 = p2;
        this.x0 = x0;
        this.t = t;
        this.b = b;
    }

    float2 project(float2 coordinates)
    {
        return coordinates;
    }

    float3 X(float2 coordinates)
    {
        return x0 + coordinates.x * t + coordinates.y * b;
    }

    // Returns true on success. Outputs:
    //   L  = |p1 - X| + |p2 - X|
    //   g  = gradient wrt (coordinates.x, coordinates.y)
    //   H  = (Hxx, Hxy, Hyy) packed in a float3
    bool evalTarget(float2 xi_prime, out float L, out float2 g, out float3 H)
    {
        return evalAtFocus(p1, xi_prime, L, g, H);
    }

    // Analytic charts have no mutable hit to snapshot.
    [mutating]
    void initializeSource(float2 xi) {}

    bool evalSource(float2 xi, out float L, out float2 g, out float3 H)
    {
        return evalAtFocus(sourceP1, xi, L, g, H);
    }

    bool evalAtFocus(float3 precedingPoint, float2 coordinates, out float L, out float2 g, out float3 H)
    {
        const float eps = 1e-8f;
        L = 0.f; g = float2(0.f); H = float3(0.f);
        if (!all(isfinite(coordinates))) return false;

        float3 Xw = X(coordinates);
        float3 r1 = precedingPoint - Xw;
        float3 r2 = p2 - Xw;

        float d1 = length(r1);
        float d2 = length(r2);
        if (!(d1 > eps) || !(d2 > eps) || !isfinite(d1 + d2)) return false;

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
        return isfinite(L) && all(isfinite(g)) && all(isfinite(H));
    }

    // dummy
    [mutating]
    void update(float2 coordinates)
    {

    }
};
