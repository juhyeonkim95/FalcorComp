struct Sphere
{
    float3 p;
    float R;
}

struct Ellipsoid
{
    // foci + parameter
    float3 p1;
    float3 p2;
    float  t;

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
// Returns false if invalid (t <= |p2 - p1|).
bool buildEllipsoidFromFoci(float3 p1, float3 p2, float t, float3 n1, float3 n2, out Ellipsoid E)
{
    E.p1 = p1;
    E.p2 = p2;
    E.t  = t;
    E.n1 = n1;
    E.n2 = n2;

    float3 delta = p2 - p1;
    float  d     = length(delta);      // distance between foci = 2c

    // Invalid (empty) if t <= d
    if (t <= d)
        return false;

    // Center
    E.center = 0.5 * (p1 + p2);

    // Semi-axis lengths: major a, minor b
    float a  = 0.5 * t;                // 2a = t
    float c  = 0.5 * d;                // 2c = d
    float a2 = a * a;
    float c2 = c * c;
    float b2 = max(a2 - c2, 0.0);      // guard FP
    float b  = sqrt(b2);

    E.extent = float3(a, b, b);

    // Major axis direction U0 = (p2 - p1)/|p2 - p1|
    float3 U0 = delta / d;

    // Build U1, U2 perpendicular to U0
    float3 U1, U2;
    buildOrthonormalBasis(U0, U1, U2);

    E.axis0 = U0;
    E.axis1 = U1;
    E.axis2 = U2;

    // Quadratic form M = sum_i (1/extent_i^2) * Ui Ui^T
    float invA2 = 1.0 / a2;
    float invB2 = (b2 > 0.0) ? (1.0 / b2) : 0.0;

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


// Squared length
float lengthSq(float3 v) { return dot(v, v); }

// Closest–point-on-segment distance test to unit sphere centered at origin
// Returns true if segment [p0,p1] intersects (or touches) the sphere.
bool segmentIntersectsUnitSphere(float3 p0, float3 p1)
{
    float3 d  = p1 - p0;
    float  dd = dot(d, d);
    float epsilon = 1e-3;
    if (dd <= 0.0f)
    {
        // Degenerate segment
        return lengthSq(p0) < 1.0f - epsilon;
    }

    float t = -dot(p0, d) / dd;
    t = clamp(t, 0.0f, 1.0f);

    float3 c = p0 + t * d;
    return lengthSq(c) < 1.0f - epsilon;
}

// Point-in-triangle test (barycentric, 3D, triangle assumed non-degenerate)
bool pointInTriangle(float3 p, float3 a, float3 b, float3 c)
{
    float3 v0 = b - a;
    float3 v1 = c - a;
    float3 v2 = p - a;

    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);

    float denom = d00 * d11 - d01 * d01;
    if (denom <= 0.0f) return false; // degenerate

    float invDenom = 1.0f / denom;
    float v = (d11 * d20 - d01 * d21) * invDenom;
    float w = (d00 * d21 - d01 * d20) * invDenom;
    float u = 1.0f - v - w;
    
    float epsilon = 1e-3;

    return (u >= epsilon) && (v >= epsilon) && (w >= epsilon);
}

// Point-in-quad via split into two triangles (convex quad)
bool pointInQuad(float3 p, float3 a, float3 b, float3 c, float3 d)
{
    return pointInTriangle(p, a, b, c) || pointInTriangle(p, a, c, d);
}

// Returns true if AABB is completely outside the ellipsoid (no intersection).
// AABB: center = origin, half extent = extent (axis-aligned).
bool AABBOutsideEllipsoid(Ellipsoid E, float3 origin, float3 extent)
{
    const float eps = 1e-3f;

    // 0) Build 8 AABB vertices in world space.
    float3 verts[8];
    int idx = 0;
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
                verts[idx++] = origin + float3(sx * extent.x, sy * extent.y, sz * extent.z);
            }
        }
    }

    // 0b) Transform vertices into unit-sphere space.
    float3 v[8];
    for (int i = 0; i < 8; ++i)
    {
        v[i] = toUnitSphereSpace(E, verts[i]);
    }
    
    // 1) Check 8 vertices: if any is inside or on the unit sphere, then
    //    the AABB is NOT completely outside.
    for (int i = 0; i < 8; ++i)
    {
        if (lengthSq(v[i]) <= 1.0f - eps)
        {
            return false; // intersects ellipsoid
        }
    }
    // return true;

    // 2) Check 12 edges: if any edge segment intersects the unit sphere,
    //    then the AABB is NOT completely outside.
    int2 edges[12] = {
        int2(0,1), int2(1,3), int2(3,2), int2(2,0), // bottom (z-)
        int2(4,5), int2(5,7), int2(7,6), int2(6,4), // top (z+)
        int2(0,4), int2(1,5), int2(3,7), int2(2,6)  // vertical edges
    };

    for (int e = 0; e < 12; ++e)
    {
        int i0 = edges[e].x;
        int i1 = edges[e].y;
        if (segmentIntersectsUnitSphere(v[i0], v[i1]))
        {
            return false; // edge intersects ellipsoid
        }
    }


    // 3) Check 6 faces (each split into 2 triangles).
    // Faces defined by vertex indices (using the same 0..7 indexing):
    //
    // 0: -X face (0,2,6,4)
    // 1: +X face (1,3,7,5)
    // 2: -Y face (0,1,5,4)
    // 3: +Y face (2,3,7,6)
    // 4: -Z face (0,1,3,2)
    // 5: +Z face (4,5,7,6)
    int4 faces[6] = {
        int4(0,2,6,4), // -X
        int4(1,3,7,5), // +X
        int4(0,1,5,4), // -Y
        int4(2,3,7,6), // +Y
        int4(0,1,3,2), // -Z
        int4(4,5,7,6)  // +Z
    };

    for (int f = 0; f < 6; ++f)
    {
        int4 fi = faces[f];
        float3 a = v[fi.x];
        float3 b = v[fi.y];
        float3 c = v[fi.z];
        float3 d = v[fi.w];

        // Plane of the face in unit-sphere space
        float3 n = normalize(cross(b - a, c - a));
        float  dist = dot(n, a);            // plane: n·x = dist
        float  adist = abs(dist);

        // If the plane is farther than radius 1, sphere doesn't intersect this face plane.
        if (adist > 1.0f + eps)
            continue;

        // Projection of sphere center (0) onto plane: x_p = n * dist
        float3 proj = n * dist;

        // Check if this projection lies inside the quad; if yes, sphere intersects face interior.
        if (pointInQuad(proj, a, b, c, d))
        {
            return false; // sphere (ellipsoid) intersects face
        }
    }

    // If we reach here, no vertex, edge, or face intersects the unit sphere.
    // Therefore, the AABB is completely outside the ellipsoid.
    return true;
}

// Returns true if the triangle (p0, p1, p2) is completely inside the ellipsoid.
bool TriangleInsideEllipsoid(Ellipsoid E, float3 p0, float3 p1, float3 p2)
{
    const float eps = 1e-6f;

    float3 verts[3] = { p0, p1, p2 };

    // Check each vertex
    [unroll]
    for (int i = 0; i < 3; ++i)
    {
        // Transform to unit-sphere space
        float3 v = toUnitSphereSpace(E, verts[i]);

        // If any vertex is outside the unit sphere, triangle is not fully inside
        if (dot(v, v) > 1.0f + eps)
            return false;
    }

    // All 3 vertices are inside the ellipsoid
    return true;
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

bool triInNegativeHalfSpace(float3 p1, float3 p2, float3 p3,
                            float3 p,  float3 n)
{
    // Signed distances of each vertex to the plane (p, n)
    float d1 = dot(p1 - p, n);
    float d2 = dot(p2 - p, n);
    float d3 = dot(p3 - p, n);

    // If the vertex with the largest distance is still negative,
    // then all three are in the negative half-space.
    float dMax = max(d1, max(d2, d3));
    return dMax < 0.0f;   // or < -eps if you want a tolerance
}

bool focusPointsValidOnPlane(float3 p1, float3 p2,
                            float3 p,  float3 n)
{
    // Signed distances of each vertex to the plane (p, n)
    float d1 = (dot(normalize(p1 - p), n));
    float d2 = (dot(normalize(p2 - p), n));
    
    if((d1 < 0 && d2 > 0) || (d1 > 0 && d2 <0))
        return false;
    if((abs(d1) < 1e-4) || (abs(d2) < 1e-4))
        return false;
    return true;
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

bool isAABBCuttingSphere(Sphere S, float3 origin, float3 extent)
{
    const float eps = 1e-6f;
    float3 delta = abs(S.p - origin);
    return (delta.x - eps <= (S.R + extent.x)) &&
           (delta.y - eps <= (S.R + extent.y)) &&
           (delta.z - eps <= (S.R + extent.z));
}


bool isAABBValidForSphere(Sphere S, float3 origin, float3 extent)
{
    if(!isAABBCuttingSphere(S, origin, extent))
        return false;
    return true;
}


bool isTriangleValid(Ellipsoid E, float3 p1, float3 p2, float3 p3, float3 n)
{
    if(triInNegativeHalfSpace(p1, p2, p3, E.p1, E.n1)
     || triInNegativeHalfSpace(p1, p2, p3, E.p2, E.n2)){
        return false;
    }

    if(!focusPointsValidOnPlane(E.p1, E.p2, p1, n))
    {
        return false;
    }

    if(TriangleInsideEllipsoid(E, p1, p2, p3)){
        return false;
    }
    return true;
}