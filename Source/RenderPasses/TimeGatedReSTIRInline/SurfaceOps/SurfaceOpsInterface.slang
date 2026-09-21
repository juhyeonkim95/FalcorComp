// =============================================================
// Ops interface the solver expects
// Implement this on your surface chart type.
//   eval(xi) -> L, g, H  with H packed as (Hxx, Hxy, Hyy)
//   project(xi) -> domain projection (can be identity)
// =============================================================
export interface ISurfaceOps
{
    bool   eval(float2 xi, out float L, out float2 g, out float3 H);
    float2 project(float2 xi);

    [mutating]
    void update(float2 xi);
};
