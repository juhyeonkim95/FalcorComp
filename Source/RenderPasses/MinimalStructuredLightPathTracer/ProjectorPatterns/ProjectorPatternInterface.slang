export interface IProjectorPattern
{
    float2 antitheticCoord(float2 uv, float r);
    float eval(float2 uv);
    float antitheticJacobian(float2 uv);
};
