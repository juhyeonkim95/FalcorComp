import RenderPasses.Shared.Shaders.Utils.LoadShadingData;
import RenderPasses.Shared.Shaders.Utils.SingleChannel;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.Utils.RayUtils;
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Lights.Laser;

cbuffer CB
{
    uint2 gFrameDim;
    uint gFrameCount;    // Frame count since scene was loaded.

    uint gSamplesPerPixel;
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional


// Outputs
RWTexture2D<float4> gOutputColor;

// Static configuration based on defines set from the host.
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kComputeDirect = COMPUTE_DIRECT;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;

static const float3 kDefaultBackgroundColor = float3(0, 0, 0);


// Trace camera paths and connect them to a sampled laser endpoint.
float3 tracePath(const uint2 pixel, const uint2 frameDim)
{
    float3 outColor = float3(0.f);

    const float3 primaryRayOrigin = gScene.camera.getPosition();
    const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gViewW);

    const HitInfo hit0 = HitInfo(gVBuffer[pixel]);

    if (hit0.isValid())
    {
        SampleGenerator sg = createPixelSampleGenerator(pixel, gFrameCount, kPathSampleStream);

        ShadingData sd0 = loadShadingData(hit0, primaryRayOrigin, primaryRayDir);
        IMaterialInstance mi0 = gScene.materials.getMaterialInstance(sd0, ExplicitLodTextureSampler(0.f));
        LaserLightSampler lls = createLaserLightSampler();


        for(uint i=0; i<gSamplesPerPixel; i++){
            float3 result = float3(0.0f);
            float3 throughput = float3(1.0f);

            //
            // (1) First Hit Material
            //
            ShadingData sd = sd0;
            IMaterialInstance mi = mi0;
            BSDFSample bsdfSample = {};

            HitInfo hit = hit0;
            float hitT;

            // Direct illumination at the primary hit (camera -> primary -> light).
            if(kComputeDirect){
                // sample light
                LightSample ls = {};
                lls.generateLightSample(sg, ls);
                LightConnection connection = evaluateLightConnection(sd, mi, ls, sg);
                result += throughput * (connection.bsdfCosine * connection.incidentRadiance);
            }
            for(uint depth=1; depth<kMaxBounces && any(throughput > 0.) && !any(throughput < 0.) && hit.isValid(); depth++){
                // -------------------- BSDF Sampling ----------------------
                if(!mi.sample(sd, sg, bsdfSample, kUseImportanceSampling)){
                    break;
                }
                throughput *= bsdfSample.weight;

                bool is_transmission = bsdfSample.isLobe(LobeType::Transmission);

                float3 rayOrigin = sd.computeRayOrigin(!is_transmission);
                hit = traceRay(rayOrigin, bsdfSample.wo, hitT);

                if(hit.isValid() && any(throughput > 0.)){
                    sd = loadShadingData(hit, rayOrigin, bsdfSample.wo);
                    mi = gScene.materials.getMaterialInstance(sd, ExplicitLodTextureSampler(0.f));

                    // sample light
                    LightSample ls = {};
                    lls.generateLightSample(sg, ls);
                    LightConnection connection = evaluateLightConnection(sd, mi, ls, sg);
                    result += throughput * (connection.bsdfCosine * connection.incidentRadiance);
                }
            }
            if (any(isinf(result) || isnan(result))) result = 0.f;
            outColor += result;
        }
        outColor /= gSamplesPerPixel;
    }
    else
    {
        // Background pixel.
        outColor = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
    }

    return outColor;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gFrameDim))
        return;

    float3 color = tracePath(pixel, gFrameDim);
#if USE_SINGLE_CHANNEL
    color = float3(selectChannel(color));
#endif
    gOutputColor[pixel] = float4(color, 1.f);
}
