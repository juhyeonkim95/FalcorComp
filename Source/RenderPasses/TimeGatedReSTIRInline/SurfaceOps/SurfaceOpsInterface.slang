// =============================================================
// Ops interface the solver expects
// Implement this on your surface chart type.
//   evalTarget(xi_prime) -> L, g, H  with H packed as (Hxx, Hxy, Hyy)
//   project(coordinates) -> domain projection (can be identity)
//   update(coordinates) -> refresh geometry before EVERY eval, including line-search trials
// Domain constraints must not silently collapse a 2D chart onto its boundary.
// =============================================================
export interface ISurfaceOps
{
    // Fix source geometry at xi before Newton updates the target geometry.
    [mutating]
    void initializeSource(float2 xi);

    // Source potential in the same chart; legacy single-potential charts use evalTarget().
    bool evalSource(float2 xi, out float L, out float2 g, out float3 H);
    bool   evalTarget(float2 xi_prime, out float L, out float2 g, out float3 H);
    float2 project(float2 coordinates);

    [mutating]
    void update(float2 coordinates);
};

