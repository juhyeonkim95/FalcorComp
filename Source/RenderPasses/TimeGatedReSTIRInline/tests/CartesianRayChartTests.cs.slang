import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.CartesianRayChart;

RWStructuredBuffer<float4> results;

float3 planeHit(float2 eta)
{
    float3 d = CartesianRayChart::direction(eta);
    float3 normal = normalize(float3(.2f, -.1f, 1.f));
    return 2.f * d / dot(normal, d);
}

[numthreads(1, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    float2 eta = float2(0.f);
    if (tid.x == 1) eta = float2(.3f, -.5f);
    if (tid.x == 2) eta = float2(2.f, 1.f);
    if (tid.x == 3) eta = float2(-1.f, .2f);
    float h = .002f;
    float2 ex = float2(h, 0.f), ey = float2(0.f, h);
    float3 d, du, dv, duu, duv, dvv;
    CartesianRayChart::derivatives(eta, d, du, dv, duu, duv, dvv);
    float3 xp, xu, xv, xuu, xuv, xvv;
    float3 xm, xmu, xmv, xmuu, xmuv, xmvv;
    float3 yp, yu, yv, yuu, yuv, yvv;
    float3 ym, ymu, ymv, ymuu, ymuv, ymvv;
    CartesianRayChart::derivatives(eta + ex, xp, xu, xv, xuu, xuv, xvv);
    CartesianRayChart::derivatives(eta - ex, xm, xmu, xmv, xmuu, xmuv, xmvv);
    CartesianRayChart::derivatives(eta + ey, yp, yu, yv, yuu, yuv, yvv);
    CartesianRayChart::derivatives(eta - ey, ym, ymu, ymv, ymuu, ymuv, ymvv);
    float gradientError = max(length(du - (xp - xm) / (2.f * h)), length(dv - (yp - ym) / (2.f * h)));
    float hessianError = max(length(duu - (xu - xmu) / (2.f * h)),
        max(length(duv - (xv - xmv) / (2.f * h)), length(dvv - (yv - ymv) / (2.f * h))));
    float sigma = CartesianRayChart::solidAngleDensity(eta);
    results[tid.x * 2] = float4(gradientError, hessianError, abs(sigma - length(cross(du, dv))), float(CartesianRayChart::isValid(eta)));

    // Independently finite-difference the ray/plane intersection in world space.
    // This catches a missing nonconstant chart-density factor in dA/deta.
    float3 normal = normalize(float3(.2f, -.1f, 1.f));
    float3 hit = planeHit(eta);
    float G = abs(dot(normal, d)) / dot(hit, hit);
    float3 dx = (planeHit(eta + ex) - planeHit(eta - ex)) / (2.f * h);
    float3 dy = (planeHit(eta + ey) - planeHit(eta - ey)) / (2.f * h);
    results[tid.x * 2 + 1] = float4(sigma / G, length(cross(dx, dy)), abs(length(d) - 1.f),
        float(CartesianRayChart::isValid(float2(1e8f, 0.f))));
}
