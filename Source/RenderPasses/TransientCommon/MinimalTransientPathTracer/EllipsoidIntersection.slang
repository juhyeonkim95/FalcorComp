#ifndef PI
#define PI 3.14159265358979323846
#endif

struct OrthoBasis { float3 u, v, w; };

struct SampleResultArea
{
    bool   ok;
    float3 p;     // sampled point (world)
    float  pdfA;  // pdf w.r.t. surface area
};

// ---------- helpers (same as before) ----------
inline OrthoBasis makeBasis(float3 w)
{
    float3 a = (abs(w.z) < 0.999) ? float3(0,0,1) : float3(0,1,0);
    float3 u = normalize(cross(a, w));
    float3 v = cross(w, u);
    OrthoBasis B = { u, v, w };
    return B;
}

inline bool pointInTri2(float2 p, float2 a, float2 b, float2 c)
{
    float2 v0 = c - a, v1 = b - a, v2 = p - a;
    float den = v0.x * v1.y - v1.x * v0.y;
    if (abs(den) < 1e-20) return false;
    float s = (v2.x * v1.y - v1.x * v2.y) / den;
    float t = (v0.x * v2.y - v2.x * v0.y) / den;
    float u = 1.0 - s - t;
    return (s >= 0.0) && (t >= 0.0) && (u >= 0.0);
}

inline float sdToEdge(float2 q, float2 a, float2 b)
{
    float2 e = b - a;
    float2 n = float2(-e.y, e.x);
    float ln = length(n);
    if (ln < 1e-20) return 1e30;
    return abs(dot(n, q - a)) / ln;
}

inline float2 pointFromAngle(float ang, float rc) { return float2(rc * cos(ang), rc * sin(ang)); }
inline float  norm2pi(float a) { float t = fmod(a, 2.0 * PI); return (t < 0.0) ? t + 2.0 * PI : t; }

inline void edgeCircleIntersections(float2 A, float2 B, float rc, inout float angles[6], inout int ac)
{
    float2 S = B - A;
    float a2 = dot(S, S);
    if (a2 <= 1e-20) return;

    float b2   = 2.0 * dot(S, A);
    float c2   = dot(A, A) - rc*rc;
    float disc = b2*b2 - 4.0*a2*c2;
    if (disc < 0.0) return;

    float inv = 0.5 / a2;
    float sqrtD = sqrt(max(disc, 0.0));
    float t0 = (-b2 - sqrtD) * inv;
    float t1 = (-b2 + sqrtD) * inv;

    [unroll]
    for (int k=0; k<2; ++k)
    {
        float t = (k==0)? t0 : t1;
        if (t < 0.0 || t > 1.0) continue;
        float2 Pk = A + t * S;
        float ang = atan2(Pk.y, Pk.x);
        bool unique = true;
        [unroll]
        for (int i=0; i<ac; ++i)
            if (abs(ang - angles[i]) <= 1e-5) { unique=false; break; }
        if (unique && ac < 6) angles[ac++] = ang;
    }
}

inline bool fullCircleInside(float2 tri2[3], float rc)
{
    bool insideCenter = pointInTri2(float2(0,0), tri2[0], tri2[1], tri2[2]);
    if (!insideCenter) return false;
    float d0 = sdToEdge(float2(0,0), tri2[0], tri2[1]);
    float d1 = sdToEdge(float2(0,0), tri2[1], tri2[2]);
    float d2 = sdToEdge(float2(0,0), tri2[2], tri2[0]);
    return (d0 >= rc - 1e-6) && (d1 >= rc - 1e-6) && (d2 >= rc - 1e-6);
}

// Map world <-> sphere-space coordinates (no lambdas)
inline float3 toSphereCoord(float3 x, float3 m, OrthoBasis B, float a, float b)
{
    float3 r = x - m;
    float3 yLocal = float3(dot(B.u, r), dot(B.v, r), dot(B.w, r));
    return float3(yLocal.x / b, yLocal.y / b, yLocal.z / a);
}
inline float3 toWorldCoord(float3 y, float3 m, OrthoBasis B, float a, float b)
{
    float3 yScaled = float3(y.x * b, y.y * b, y.z * a);
    return m + (B.u * yScaled.x + B.v * yScaled.y + B.w * yScaled.z);
}

// ---------- main: sample with time gate and return area-PDF ----------
SampleResultArea sampleOnTrianglePathLength(
    float3 x1, float3 x2,
    float3 p1, float3 p2, float3 p3,
    float  t1, float  t2,    // time gate
    float  alpha,            // distance-per-time (use 1 if your t is already a distance)
    float  uT,               // random in [0,1): time sample
    float  uSel, float uTheta)  // arc selection + angle sample
{
    SampleResultArea R; R.ok=false; R.p=0; R.pdfA=0;

    // 1) sample time and convert to path length c
    float t = lerp(t1, t2, uT);
    float c = alpha * t;

    // Ellipsoid params
    float focalDist = length(x2 - x1);
    float f = 0.5 * focalDist;
    float a = 0.5 * c;                        // semi-major
    if (a <= f + 1e-7) return R;              // no feasible ellipse
    float b = sqrt(max(a*a - f*f, 0.0));      // semi-minor
    float3 m = 0.5 * (x1 + x2);               // center
    float3 aDir = normalize(x2 - x1);
    OrthoBasis B = makeBasis(aDir);           // ellipsoid axis frame

    // Transform triangle to sphere-space
    float3 q1 = toSphereCoord(p1, m, B, a, b);
    float3 q2 = toSphereCoord(p2, m, B, a, b);
    float3 q3 = toSphereCoord(p3, m, B, a, b);

    // Sphere-plane circle
    float3 n = normalize(cross(q2 - q1, q3 - q1));
    float  d = -dot(n, q1);
    float  h = abs(d);
    if (h > 1.0 + 1e-7) return R;             // plane misses unit sphere
    float  rc = sqrt(max(1.0 - h*h, 0.0));    // circle radius
    float3 Cc = -d * n;                       // circle center

    // In-plane 2D frame
    OrthoBasis P = makeBasis(n);              // P.u, P.v in the plane
    float2 tri2[3] = {
        float2(dot(P.u, q1 - Cc), dot(P.v, q1 - Cc)),
        float2(dot(P.u, q2 - Cc), dot(P.v, q2 - Cc)),
        float2(dot(P.u, q3 - Cc), dot(P.v, q3 - Cc))
    };

    // Intersections (angles)
    float angles[6]; int ac = 0;
    edgeCircleIntersections(tri2[0], tri2[1], rc, angles, ac);
    edgeCircleIntersections(tri2[1], tri2[2], rc, angles, ac);
    edgeCircleIntersections(tri2[2], tri2[0], rc, angles, ac);

    // Full-circle case
    float ThetaTot = 0.0;
    bool fullCircle = false;
    if (ac == 0)
    {
        if (!fullCircleInside(tri2, rc)) return R;
        fullCircle = true;
        ThetaTot = 2.0 * PI;
    }
    else
    {
        // normalize and sort angles
        for (int i=0; i<ac; ++i) angles[i] = norm2pi(angles[i]);
        for (int i=1; i<ac; ++i)
        {
            float key = angles[i]; int j = i-1;
            while (j>=0 && angles[j] > key) { angles[j+1]=angles[j]; j--; }
            angles[j+1] = key;
        }

        // build arcs, keep those whose midpoint is inside
        struct Arc { float a0, a1; };
        Arc arcs[6]; float arcW[6]; int arcCount = 0;

        for (int i=0; i<ac; ++i)
        {
            float a0 = angles[i];
            float a1 = angles[(i+1)%ac];
            if (i == ac-1) a1 += 2.0 * PI;

            float amid = 0.5 * (a0 + a1);
            float2 pm = pointFromAngle(amid, rc);
            if (!pointInTri2(pm, tri2[0], tri2[1], tri2[2])) continue;

            float dTheta = a1 - a0;
            arcs[arcCount] = Arc(a0, a1);
            arcW[arcCount] = dTheta;      // we keep Δθ; circle length is rc*Δθ (rc cancels later)
            ThetaTot += dTheta;
            arcCount++;
        }
        if (arcCount == 0) return R;

        // pick arc by Δθ, then pick θ uniformly
        float pick = uSel * ThetaTot;
        int sel = 0; float acc = 0.0;
        for (int i=0; i<arcCount; ++i)
        {
            if (pick <= acc + arcW[i]) { sel = i; break; }
            acc += arcW[i];
        }
        float a0 = arcs[sel].a0;
        float a1 = arcs[sel].a1;

        float theta = lerp(a0, a1, uTheta);

        // point on circle (sphere-space), then to world
        float2 c2 = pointFromAngle(theta, rc);
        float3 y  = Cc + c2.x * P.u + c2.y * P.v;
        float3 p  = toWorldCoord(y, m, B, a, b);

        // ---- Area PDF ----

        // 1) f_C(c) from uniform t in [t1,t2] with c = alpha * t
        float fC = (1.0 / max(t2 - t1, 1e-20)) * (1.0 / max(alpha, 1e-20));

        // 2) in-plane gradient magnitude ||∇_plane L(p)||
        float3 nTri = normalize(cross(p2 - p1, p3 - p1));
        float3 u1v = (p - x1) / max(length(p - x1), 1e-20);
        float3 u2v = (p - x2) / max(length(p - x2), 1e-20);
        float3 s   = u1v + u2v;
        float3 sPerp = s - nTri * dot(nTri, s);
        float  gradPlane = max(length(sPerp), 1e-20);

        // 3) |J * t_hat| at theta
        //    t_hat (sphere-space) = -sinθ * e1 + cosθ * e2  with e1=P.u, e2=P.v
        float3 that = (-sin(theta)) * P.u + (cos(theta)) * P.v;
        // Apply J = R diag(b,b,a): worldDir = b*(that·B.u)*B.u + b*(that·B.v)*B.v + a*(that·B.w)*B.w
        float3 Jt =
              (B.u * (b * dot(B.u, that)))
            + (B.v * (b * dot(B.v, that)))
            + (B.w * (a * dot(B.w, that)));
        float  JtNorm = max(length(Jt), 1e-20);

        // 4) total angle measure ThetaTot (radians)
        float pdfA = fC * (gradPlane) / (max(ThetaTot, 1e-20) * JtNorm);

        R.ok   = true;
        R.p    = p;
        R.pdfA = pdfA;
        return R;
    }

    // Full-circle-inside path:
    {
        // θ uniform on [0,2π)
        float theta = 2.0 * PI * uTheta;

        float2 c2 = pointFromAngle(theta, rc);
        float3 y  = Cc + c2.x * P.u + c2.y * P.v;
        float3 p  = toWorldCoord(y, m, B, a, b);

        // Terms as above
        float fC = (1.0 / max(t2 - t1, 1e-20)) * (1.0 / max(alpha, 1e-20));

        float3 nTri = normalize(cross(p2 - p1, p3 - p1));
        float3 u1v = (p - x1) / max(length(p - x1), 1e-20);
        float3 u2v = (p - x2) / max(length(p - x2), 1e-20);
        float3 s   = u1v + u2v;
        float3 sPerp = s - nTri * dot(nTri, s);
        float  gradPlane = max(length(sPerp), 1e-20);

        float3 that = (-sin(theta)) * P.u + (cos(theta)) * P.v;
        float3 Jt =
              (B.u * (b * dot(B.u, that)))
            + (B.v * (b * dot(B.v, that)))
            + (B.w * (a * dot(B.w, that)));
        float  JtNorm = max(length(Jt), 1e-20);

        float pdfA = fC * (gradPlane) / (max(ThetaTot, 1e-20) * JtNorm); // ThetaTot = 2π here

        R.ok   = true;
        R.p    = p;
        R.pdfA = pdfA;
        return R;
    }
}
