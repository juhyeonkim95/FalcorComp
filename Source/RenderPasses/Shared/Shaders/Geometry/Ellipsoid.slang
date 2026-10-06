struct Ellipsoid
{
    // foci + parameter
    float3 p1;
    float3 p2;
    float  t;
    float3 p_original;
    
    // normal at each foci
    float3 n1;
    float3 n2;

    // geometric description
    float3 center;   // midpoint of the foci
    float3 extent;   // local semi-axes (a, b, b)

    // orthonormal frame of the ellipsoid (major axis = axis0)
    float3 axis0;    // U0 (along p2 - p1)
    float3 axis1;    // U1
    float3 axis2;    // U2

    // quadratic form: (x - center)^T * M * (x - center) <= 1
    float3x3 M;

    // cached world-space AABB
    float3 aabbOrigin;  // = center
    float3 aabbExtent;  // half-extent of the ellipsoid’s AABB
    
};

// helpers
float3x3 outerProduct(float3 a, float3 b) {
    // returns a * b^T (column-major literal)
    return float3x3(a * b.x, a * b.y, a * b.z);
}

void buildOrthonormalBasis(float3 n, out float3 u, out float3 v)
{
    // n is assumed normalized; build u,v s.t. {n,u,v} is ONB
    float3 t = (abs(n.z) < 0.999f) ? float3(0,0,1) : float3(0,1,0);
    u = normalize(cross(t, n));
    v = cross(n, u);
}

// Build ellipsoid from two foci and sum-of-distances t.
// Coincident foci define a sphere. Reject empty or numerically unrepresentable ellipsoids.
bool buildEllipsoidFromFoci(float3 p1, float3 p2, float t, float3 n1, float3 n2, out Ellipsoid E)
{
    E = {};
    if (!(t > 0.f) || isinf(t) || any(isinf(p1) || isnan(p1)) || any(isinf(p2) || isnan(p2))) return false;

    float3 delta = p2 - p1;
    float deltaScale = max(abs(delta.x), max(abs(delta.y), abs(delta.z)));
    if (isinf(deltaScale)) return false;

    // For coincident foci the shape is a sphere, so its orientation is arbitrary.
    float3 U0 = float3(1.f, 0.f, 0.f);
    float d = 0.f;
    if (deltaScale > 0.f)
    {
        // Normalize in scaled coordinates: length(delta) can underflow for close foci.
        // Keep the actual axis for distinct foci, even for a very small ellipsoid.
        float3 scaledDelta = delta / deltaScale;
        float scaledLength = length(scaledDelta);
        U0 = scaledDelta / scaledLength;
        d = deltaScale * scaledLength;
    }
    if (!(t > d)) return false;

    float a = 0.5f * t;
    float a2 = a * a;
    // Equivalent to a^2 - c^2, with less cancellation for nearly collapsed ellipsoids.
    float b2 = (0.5f * (t - d)) * (0.5f * t + 0.5f * d);
    if (!(a2 > 0.f) || !(b2 > 0.f) || isinf(a2) || isinf(b2)) return false;
    float invA2 = 1.f / a2;
    float invB2 = 1.f / b2;
    if (isinf(invA2) || isinf(invB2)) return false;
    float b = sqrt(b2);

    E.p1 = p1;
    E.p2 = p2;
    E.t = t;
    E.n1 = n1;
    E.n2 = n2;
    E.center = 0.5f * p1 + 0.5f * p2;
    E.extent = float3(a, b, b);

    // Build U1, U2 perpendicular to U0
    float3 U1, U2;
    buildOrthonormalBasis(U0, U1, U2);

    E.axis0 = U0;
    E.axis1 = U1;
    E.axis2 = U2;

    // Quadratic form M = sum_i (1/extent_i^2) * Ui Ui^T
    float3x3 M0 = outerProduct(U0, U0) * invA2;
    float3x3 M1 = outerProduct(U1, U1) * invB2;
    float3x3 M2 = outerProduct(U2, U2) * invB2;

    E.M = M0 + M1 + M2;

    // ---------- cache world-space AABB ----------
    // For a rotated ellipsoid with axes (U0,U1,U2) and radii (a,b,b),
    // the world half-extent along component k ∈ {x,y,z} is:
    // r_k = sqrt( (a*U0_k)^2 + (b*U1_k)^2 + (b*U2_k)^2 )
    float3 U0c = float3(E.axis0.x, E.axis0.y, E.axis0.z);
    float3 U1c = float3(E.axis1.x, E.axis1.y, E.axis1.z);
    float3 U2c = float3(E.axis2.x, E.axis2.y, E.axis2.z);

    float3 r;
    r.x = sqrt( (a*U0c.x)*(a*U0c.x) + (b*U1c.x)*(b*U1c.x) + (b*U2c.x)*(b*U2c.x) );
    r.y = sqrt( (a*U0c.y)*(a*U0c.y) + (b*U1c.y)*(b*U1c.y) + (b*U2c.y)*(b*U2c.y) );
    r.z = sqrt( (a*U0c.z)*(a*U0c.z) + (b*U1c.z)*(b*U1c.z) + (b*U2c.z)*(b*U2c.z) );

    E.aabbOrigin = E.center;
    E.aabbExtent = r;

    return true;
}

// Transform world-space point x into unit-sphere space,
// where the ellipsoid becomes |x'| = 1.
float3 toUnitSphereSpace(Ellipsoid E, float3 x)
{
    float3 d = x - E.center;   // relative to ellipsoid center

    // Coordinates in ellipsoid principal-axis basis, then scale by 1/extent
    float3 xp;
    xp.x = dot(d, E.axis0) / E.extent.x;
    xp.y = dot(d, E.axis1) / E.extent.y;
    xp.z = dot(d, E.axis2) / E.extent.z;

    return xp; // ellipsoid maps to unit sphere: |xp| = 1
}

// inverse map: unit-sphere → world (ellipsoid surface)
float3 fromUnitSphereSpace(Ellipsoid E, float3 y)
{
    float3 ys = float3(y.x * E.extent.x, y.y * E.extent.y, y.z * E.extent.z);
    return E.center + (E.axis0 * ys.x + E.axis1 * ys.y + E.axis2 * ys.z);
}

// Returns true if the AABB (center + half extent) is completely inside the ellipsoid.
bool AABBInsideEllipsoid(Ellipsoid E, float3 origin, float3 extent)
{
    const float eps = 1e-6f;

    // Loop over 8 vertices of the AABB
    [unroll]
    for (int iz = 0; iz < 2; ++iz)
    {
        float sz = (iz == 0) ? -1.0f : 1.0f;
        [unroll]
        for (int iy = 0; iy < 2; ++iy)
        {
            float sy = (iy == 0) ? -1.0f : 1.0f;
            [unroll]
            for (int ix = 0; ix < 2; ++ix)
            {
                float sx = (ix == 0) ? -1.0f : 1.0f;

                // Vertex in world space
                float3 vert = origin + float3(sx * extent.x,
                                              sy * extent.y,
                                              sz * extent.z);

                // Transform to unit-sphere space
                float3 v = toUnitSphereSpace(E, vert);

                // If any vertex is outside the unit sphere, box is not fully inside
                if (dot(v, v) > 1.0f + eps)
                    return false;
            }
        }
    }

    // All 8 vertices are inside the ellipsoid
    return true;
}

// Fast AABB vs ellipsoid (via cached ellipsoid AABB).
// Box is centered at `origin` with half-extent `extent`.
bool isAABBCuttingEllipsoid(Ellipsoid E, float3 origin, float3 extent)
{
    const float eps = 1e-6f;

    float3 delta = abs(E.aabbOrigin - origin);
    return (delta.x - eps <= (E.aabbExtent.x + extent.x)) &&
           (delta.y - eps <= (E.aabbExtent.y + extent.y)) &&
           (delta.z - eps <= (E.aabbExtent.z + extent.z));
}

bool boxInNegativeHalfSpace(float3 minB, float3 maxB, float3 p, float3 n)
{
    // Extreme point of the box in direction of n (support point).
    float3 v;
    v.x = (n.x > 0.0f) ? maxB.x : minB.x;
    v.y = (n.y > 0.0f) ? maxB.y : minB.y;
    v.z = (n.z > 0.0f) ? maxB.z : minB.z;

    // If even the farthest point along +n is on the negative side,
    // then the whole box is in the negative half-space.
    float d = dot(v - p, n);
    return d < 0.0f;
}

bool isAABBValidForEllipoid(Ellipsoid E, float3 origin, float3 extent)
{
    // (1) Exclude: AABB not cutting ellipsoid AABB
    if(!isAABBCuttingEllipsoid(E, origin, extent))
        return false;
    
    // (2) Exclude: AABB is in negative half-plane at both foci.
    float3 minB = origin - extent;
    float3 maxB = origin + extent;
    if (boxInNegativeHalfSpace(minB, maxB, E.p1, E.n1) ||
        boxInNegativeHalfSpace(minB, maxB, E.p2, E.n2))
    {
        return false;
    }

    // (3) AABB is inside Ellipsoid
    if(AABBInsideEllipsoid(E, origin, extent))
        return false;
    return true;
}

