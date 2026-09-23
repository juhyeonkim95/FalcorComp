// Initial candidate generation shared by the time-gated and histogram ReSTIR passes.
// Each pass owns its BSDF walk and gate evaluation; this module records the
// reconnection state along the walk and submits completed paths to a reservoir.
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Scene.RaytracingInline;
import RenderPasses.Shared.ReSTIR.Reservoirs;
import RenderPasses.Shared.Lights.LaserLightSampler;
import RenderPasses.Shared.Lights.LightConnection;

float shadingCosine(ShadingData surface, IMaterialInstance material, float3 direction)
{
    return abs(dot(material.getProperties(surface).guideNormal, direction));
}

// camera -> ... -> a -> x -> y -> z -> ... -> light.
// During light evaluation, postBounce is 0 at x, 1 at y, 2 at z, etc.
// At the next iteration's BSDF sample it is already incremented: 2 means y->z.
struct ReconnectionState
{
    HitInfo xHit;
    HitInfo yHit;
    float3 incomingDirectionAtY;
    uint bounce;
    uint postBounce;
    uint prefixSeed;
    uint suffixSeed;
#if IS_SCENE_DYNAMIC
    float3 yRayDirection; // Original incoming camera-walk ray at y, preserved through reuse.
#endif
    float areaPdf;              // p_A(a->x), then p_A(a->x) * p_A(x->y).
    float3 suffixThroughput;    // cosine_y/pdf_y, then sampled weights at z and beyond.
    float suffixLength;        // y->...->current surface; excludes current->light.

    // surface is the hit at the end of the segment; segmentIoR is the IoR of the
    // surface the segment leaves, which scales its optical length.
    [mutating]
    void recordHit(HitInfo hit, ShadingData surface, BSDFSample sample, uint depth,
        bool eligible, float segmentLength, float segmentIoR, float suffixDirectionWeight, uint sampleSeed)
    {
        float opticalLength = segmentLength * segmentIoR;
        if (bounce == 0)
        {
            if (eligible)
            {
                bounce = depth;
                xHit = hit;
                float cosine = max(dot(surface.getOrientedFaceNormal(), -sample.wo), 0.f);
                areaPdf = sample.pdf * cosine / max(segmentLength * segmentLength, kMinLightDistSqr);
            }
        }
        else if (postBounce == 1)
        {
            yHit = hit;
#if IS_SCENE_DYNAMIC
            yRayDirection = sample.wo;
#endif
            float cosine = max(dot(surface.getOrientedFaceNormal(), -sample.wo), 0.f);
            areaPdf *= sample.pdf * cosine / max(segmentLength * segmentLength, kMinLightDistSqr);
        }
        else if (postBounce == 2)
        {
            incomingDirectionAtY = -sample.wo;
            suffixSeed = sampleSeed;
            suffixThroughput *= suffixDirectionWeight;
            suffixLength += opticalLength;
        }
        else
        {
            suffixThroughput *= sample.weight;
            suffixLength += opticalLength;
        }
    }
};

// Submit one completed-path candidate ending with surface -> light. totalLength is the
// full camera -> source length and gate its time-gate value. Keep the Monte Carlo
// contribution, the area target, and the RIS selection weight distinct.
// rejectEmptyCandidates skips zero/non-finite candidates entirely, so they
// neither count toward M nor consume a reservoir RNG draw.
void submitCandidate(inout Reservoir reservoir, ReconnectionState rc,
    ShadingData surface, IMaterialInstance material, LightSample light,
    LightConnection connection, float totalLength, float gate, float3 throughput,
    float techniqueWeight, uint samplesPerPixel, uint lightSeed, bool rejectEmptyCandidates,
    inout SampleGenerator rng)
{
    float3 contribution = throughput * connection.bsdfCosine * connection.incidentRadiance * gate;
    float3 target = rc.bounce > 0 ? contribution * rc.areaPdf : contribution;
    // The target is reconstructed by spatial reuse without a technique label.
    // MIS changes selection/W, never the stored physical target or suffix payload.
    float selectionWeight = getReservoirWeight(contribution) * techniqueWeight / float(samplesPerPixel);
    if (rejectEmptyCandidates && (!(selectionWeight > 0.f) || !isfinite(selectionWeight) ||
        !all(isfinite(target)) || !(getReservoirWeight(target) > 0.f))) return;
    if (!reservoir.update(target, selectionWeight, 1, rng)) return;

    reservoir.totalPathLength = totalLength;
    reservoir.rcVertexBounce = rc.bounce;
    if (rc.bounce == 0) return; // Reconnection fields are unused for this local-only sample.

    reservoir.rcVertexHit = rc.xHit;
    reservoir.initRandomSeed = rc.prefixSeed;
    reservoir.rcNextVertexBounce = rc.postBounce;
    if (rc.postBounce == 0)
    {
        // x->light: y is the light endpoint, not a BSDF-sampled surface.
        reservoir.rcNextVertexHit = light.hit;
        reservoir.rcNextVertexWi = light.dir;
        reservoir.rcNextVertexIrradiance = light.Li;
        reservoir.rcNextVertexPathLength = light.laserT;
    }
    else
    {
        reservoir.rcNextVertexHit = rc.yHit;
        reservoir.rcNextVertexPathLength = rc.suffixLength + connection.distance + light.laserT;
        if (rc.postBounce == 1)
        {
            // y->light: Q = cosine_y * Li, with no BSDF direction PDF.
            reservoir.rcNextVertexWi = -connection.direction;
            reservoir.rcNextVertexIrradiance = connection.incidentRadiance *
                shadingCosine(surface, material, connection.direction);
        }
        else
        {
            // y->z->...->light: Q = cosine_y/pdf_y * estimated Li(y, omega_yz).
            // Excludes y's BSDF, camera-prefix throughput, and the time gate.
            reservoir.rcNextVertexWi = rc.incomingDirectionAtY;
            reservoir.rcNextVertexIrradiance = rc.suffixThroughput *
                connection.bsdfCosine * connection.incidentRadiance;
        }
    }
#if IS_SCENE_DYNAMIC
    reservoir.rcNextVertexRayDirection = rc.yRayDirection;
    reservoir.rcNextVertexRandomSeed = rc.suffixSeed;
    reservoir.lightRandomSeed = lightSeed;
#endif
}
