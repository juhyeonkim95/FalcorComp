#include "Utils/Math/MathConstants.slangh"
import Utils.Transient.Ellipsoid;

struct SampleResultArea
{
    bool   ok;
    float3 p;     // sampled point (world)
    float  pdfA;  // pdf w.r.t. surface area
};

// ---------- lightweight helpers ----------
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
inline float2 pointFromAngle(float ang, float r) { return float2(r * cos(ang), r * sin(ang)); }
inline float  norm2pi(float a) { float t = fmod(a, 2.0 * M_PI); return (t < 0.0) ? t + 2.0 * M_PI : t; }

inline void edgeCircleIntersections(float2 A, float2 B, float r, inout float angles[6], inout int ac)
{
    float2 S = B - A;
    float a2 = dot(S, S);
    if (a2 <= 1e-20) return;

    float b2   = 2.0 * dot(S, A);
    float c2   = dot(A, A) - r*r;
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

inline bool fullCircleInside(float2 tri2[3], float r)
{
    // circle center at (0,0)
    if (!pointInTri2(float2(0,0), tri2[0], tri2[1], tri2[2])) return false;
    float d0 = sdToEdge(float2(0,0), tri2[0], tri2[1]);
    float d1 = sdToEdge(float2(0,0), tri2[1], tri2[2]);
    float d2 = sdToEdge(float2(0,0), tri2[2], tri2[0]);
    return (d0 >= r - 1e-6) && (d1 >= r - 1e-6) && (d2 >= r - 1e-6);
}

// ====== Main: Ellipsoid–Triangle sampling (area domain) ======
SampleResultArea sampleOnTriangleEllipsoid(
    Ellipsoid E,
    float3 p1, float3 p2, float3 p3,
    float  uSel, float uTheta)      // arc selection + angle sample
{
    SampleResultArea R; R.ok=false; R.p=0; R.pdfA=0;

    // Map triangle to unit-sphere space
    float3 q1 = toUnitSphereSpace(E, p1);
    float3 q2 = toUnitSphereSpace(E, p2);
    float3 q3 = toUnitSphereSpace(E, p3);

    // Plane in sphere-space: n·q + d = 0
    float3 n = normalize(cross(q2 - q1, q3 - q1));
    float  d = -dot(n, q1);

    // Circle intersection with unit sphere iff |d| <= 1
    float h = abs(d);
    if (h > 1.0 + 1e-7) return R;

    float  rc = sqrt(max(1.0 - h*h, 0.0)); // circle radius
    if(rc < 1e-10) return R;

    float3 Cc = -d * n;                    // circle center (sphere-space)

    // In-plane basis (no lambda/makeBasis): helper axis, then cross
    float3 helper = (abs(n.z) < 0.999f) ? float3(0,0,1) : float3(0,1,0);
    float3 e1 = normalize(cross(helper, n)); // in-plane
    float3 e2 = cross(n, e1);                // in-plane, orthonormal

    // Project triangle (relative to circle center) into 2D (e1,e2)
    float2 tri2[3] = {
        float2(dot(e1, q1 - Cc), dot(e2, q1 - Cc)),
        float2(dot(e1, q2 - Cc), dot(e2, q2 - Cc)),
        float2(dot(e1, q3 - Cc), dot(e2, q3 - Cc))
    };

    // Collect circle–edge intersection angles
    float angles[6]; int ac = 0;
    edgeCircleIntersections(tri2[0], tri2[1], rc, angles, ac);
    edgeCircleIntersections(tri2[1], tri2[2], rc, angles, ac);
    edgeCircleIntersections(tri2[2], tri2[0], rc, angles, ac);

    // ---------- Full circle case ----------
    if (ac == 0)
    {
        if (!fullCircleInside(tri2, rc)) return R;

        float ThetaTot = 2.0 * M_PI;
        float theta = 2.0 * M_PI * uTheta;

        // sphere-space point on circle
        float2 c2 = pointFromAngle(theta, rc);
        float3 y  = Cc + c2.x * e1 + c2.y * e2;

        // back to world (ellipsoid surface)
        float3 p  = fromUnitSphereSpace(E, y);

        // area-PDF terms
        float3 nTri = normalize(cross(p2 - p1, p3 - p1));

        float3 u1v = (p - E.p1) / max(length(p - E.p1), 1e-20);
        float3 u2v = (p - E.p2) / max(length(p - E.p2), 1e-20);
        float3 s   = u1v + u2v;
        float3 sPerp = s - nTri * dot(nTri, s);
        float  gradPlane = length(sPerp);
        if(gradPlane < 1e-10) return R;

        float3 that = (-sin(theta)) * e1 + (cos(theta)) * e2; // sphere-space tangent
        float3 Jt =
            E.axis0 * (E.extent.x * that.x) +
            E.axis1 * (E.extent.y * that.y) +
            E.axis2 * (E.extent.z * that.z);
        float  JtNorm = length(Jt);
        if(JtNorm < 1e-10) return R;

        float pdfA = (gradPlane) / (rc * ThetaTot * JtNorm);

        R.ok   = true;
        R.p    = p;
        R.pdfA = pdfA;
        return R;
    }

    // ---------- Intersecting arcs case ----------
    // Normalize & sort angles
    for (int i=0; i<ac; ++i) angles[i] = norm2pi(angles[i]);
    for (int i=1; i<ac; ++i)
    {
        float key = angles[i]; int j = i-1;
        while (j>=0 && angles[j] > key) { angles[j+1]=angles[j]; j--; }
        angles[j+1] = key;
    }

    struct Arc { float a0, a1; };
    Arc arcs[6]; float arcW[6]; int arcCount = 0;
    float ThetaTot = 0.0;

    for (int i=0; i<ac; ++i)
    {
        float a0 = angles[i];
        float a1 = angles[(i+1)%ac];
        if (i == ac-1) a1 += 2.0 * M_PI;

        float amid = 0.5 * (a0 + a1);
        float2 pm = pointFromAngle(amid, rc);
        if (!pointInTri2(pm, tri2[0], tri2[1], tri2[2])) continue;

        float dTheta = a1 - a0;
        arcs[arcCount] = Arc(a0, a1);
        arcW[arcCount] = dTheta;
        ThetaTot += dTheta;
        arcCount++;
    }
    if(ThetaTot < 1e-10) return R;
    if (arcCount == 0) return R;

    // pick arc ∝ angle length, then uniform on it
    float pick = uSel * ThetaTot;
    int sel = 0; float acc = 0.0;
    for (int i=0; i<arcCount; ++i)
    {
        if (pick <= acc + arcW[i]) { sel = i; break; }
        acc += arcW[i];
    }
    float theta = lerp(arcs[sel].a0, arcs[sel].a1, uTheta);

    // sphere-space point on chosen arc
    float2 c2 = pointFromAngle(theta, rc);
    float3 y  = Cc + c2.x * e1 + c2.y * e2;

    // back to world
    float3 p  = fromUnitSphereSpace(E, y);

    // area-PDF terms
    float3 nTri = normalize(cross(p2 - p1, p3 - p1));

    float3 u1v = normalize(p - E.p1);
    float3 u2v = normalize(p - E.p2);
    float3 s   = u1v + u2v;
    float3 sPerp = s - nTri * dot(nTri, s);
    float  gradPlane = length(sPerp);
    if(gradPlane < 1e-10) return R;

    float3 that = (-sin(theta)) * e1 + (cos(theta)) * e2; // sphere-space tangent
    float3 Jt =
        E.axis0 * (E.extent.x * that.x) +
        E.axis1 * (E.extent.y * that.y) +
        E.axis2 * (E.extent.z * that.z);
    float  JtNorm = length(Jt);
    if(JtNorm < 1e-10) return R;

    float pdfA = (gradPlane) / (rc * ThetaTot * JtNorm);
    if(pdfA < 1e-10 || pdfA > 1e10) return R;
    
    // if(rc * ThetaTot < 1e-3 || pdfA < 1e-5){
    //     R.ok=false;
    //     R.pdfA = 0.0;
    //     return R;
    // }
    R.ok   = true;
    R.p    = p;
    R.pdfA = pdfA;
    return R;
}


float pdfUniformEllipsoidTriangleArc(
    Ellipsoid E,
    float3 p1, float3 p2, float3 p3)
{
    // Map triangle to unit-sphere space
    float3 q1 = toUnitSphereSpace(E, p1);
    float3 q2 = toUnitSphereSpace(E, p2);
    float3 q3 = toUnitSphereSpace(E, p3);

    // Plane in sphere-space: n·q + d = 0
    float3 n = normalize(cross(q2 - q1, q3 - q1));
    float  d = -dot(n, q1);

    float h = abs(d);
    if (h > 1.0 + 1e-7)
        return 0.0;

    float rc = sqrt(max(1.0 - h*h, 0.0));
    float3 Cc = -d * n;

    // In-plane basis
    float3 helper = (abs(n.z) < 0.999f) ? float3(0,0,1) : float3(0,1,0);
    float3 e1 = normalize(cross(helper, n));
    float3 e2 = cross(n, e1);

    // Project triangle into 2D
    float2 tri2[3] = {
        float2(dot(e1, q1 - Cc), dot(e2, q1 - Cc)),
        float2(dot(e1, q2 - Cc), dot(e2, q2 - Cc)),
        float2(dot(e1, q3 - Cc), dot(e2, q3 - Cc))
    };

    // Collect circle–edge intersection angles
    float angles[6]; int ac = 0;
    edgeCircleIntersections(tri2[0], tri2[1], rc, angles, ac);
    edgeCircleIntersections(tri2[1], tri2[2], rc, angles, ac);
    edgeCircleIntersections(tri2[2], tri2[0], rc, angles, ac);

    float ThetaTot = 0.0;

    // ---------- Full circle ----------
    if (ac == 0)
    {
        if (!fullCircleInside(tri2, rc))
            return 0.0;

        ThetaTot = 2.0 * M_PI;
    }
    else
    {
        // Normalize & sort
        for (int i = 0; i < ac; ++i)
            angles[i] = norm2pi(angles[i]);

        for (int i = 1; i < ac; ++i)
        {
            float key = angles[i];
            int j = i - 1;
            while (j >= 0 && angles[j] > key)
            {
                angles[j + 1] = angles[j];
                j--;
            }
            angles[j + 1] = key;
        }

        // Sum valid arc lengths
        for (int i = 0; i < ac; ++i)
        {
            float a0 = angles[i];
            float a1 = angles[(i + 1) % ac];
            if (i == ac - 1)
                a1 += 2.0 * M_PI;

            float amid = 0.5 * (a0 + a1);
            float2 pm = pointFromAngle(amid, rc);

            if (!pointInTri2(pm, tri2[0], tri2[1], tri2[2]))
                continue;

            ThetaTot += (a1 - a0);
        }

        if (ThetaTot <= 1e-20)
            return 0.0;
    }
    ThetaTot *= rc;
    // Uniform over θ on valid arcs
    return 1.0 / ThetaTot;
}