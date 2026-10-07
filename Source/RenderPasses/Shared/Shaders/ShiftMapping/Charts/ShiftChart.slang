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

    // A lower bound of |p1 - X| + |p2 - X| over the chart's surface: a target length below it has no solution.
    float lengthLowerBound();

    // The chart's metric (X_u . X_u, X_u . X_v, X_v . X_v), so that the gradient gauges follow the path length's
    // steepest direction on the surface (G^-1 g in chart coordinates) rather than the coordinates' gradient g.
    float3 metric();
};
