// =============================================================
// Ops interface the solver expects
// Implement this on your surface chart type.
//   eval(xi) -> L, g, H  with H packed as (Hxx, Hxy, Hyy)
//   project(xi) -> domain projection (can be identity)
// =============================================================
export interface IShiftChart
{
    bool   eval(float2 xi, out float L, out float2 g, out float3 H);
    float2 project(float2 xi);

    [mutating]
    void update(float2 xi);

    // The fixed vertices p1, p2 of the path length |p1 - X| + |p2 - X|. Replacing them keeps the chart's state (e.g. a
    // ray chart's hit), so that another path's length can be evaluated at the same point.
    float3 firstEndpoint();
    float3 secondEndpoint();
    [mutating]
    void setEndpoints(float3 p1, float3 p2);
};
