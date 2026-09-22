// Shared path payload and RIS update; pass-specific reconstruction stays in each pass.
// RESERVOIR_SCALAR_TARGET defaults to RGB when undefined. Histogram passes set it
// consistently for reflection and execution. IS_SCENE_DYNAMIC enables replay data.
import Utils.Color.ColorHelpers;
import Utils.Sampling.SampleGenerator;
import Scene.Raytracing;

float getReservoirWeight(float3 f)
{
#if RESERVOIR_SCALAR_TARGET
    return f.x;
#else
    return luminance(f);
#endif
}

float getReservoirWeight(float f) { return f; }

struct Reservoir
{
    // Path notation: camera -> ... -> a -> x -> y -> z -> ... -> v -> light.
    // x is the reconnection vertex; y is the next vertex toward the light.
    // When rcVertexBounce == 0, reconnection fields below are unused and may be stale.

    // Selected target contribution (RGB, or red for scalar histograms), including the time gate.
    // During initial generation: path MC contribution (before technique MIS) * p_A for reconnectable paths,
    // where p_A contains the actual proposal area PDFs for a -> x and surface x -> y.
    // These edges may use a BSDF proposal or the terminal ellipsoidal proposal.
    // For a non-reconnectable path, stores the path MC contribution directly.
#if RESERVOIR_SCALAR_TARGET
    float f;
#else
    float3 f;
#endif
    // Sum of reservoir selection weights. Initially: sum(MIS weight * getReservoirWeight(path MC contribution) / samplesPerPixel).
    float wSum;
    // Accumulated candidate count/mass supplied to update(). Initially counts submitted
    // completed-path candidates across bounce depths. Histogram generation resets M
    // to its number of camera-path trials when finalizing each bin.
    float M;
    // Final normalization: wSum / getReservoirWeight(f), or zero for a zero target.
    // The selected reservoir estimates RGB contribution as W * f.
    float W;

    // Surface hit identifying x, the first vertex passing the reconnection eligibility test.
    HitInfo rcVertexHit;
    // Surface hit identifying y. For x -> light, stores ls.hit instead;
    // a laser endpoint has a surface hit, while a point-light endpoint has an invalid hit.
    HitInfo rcNextVertexHit;
    // Light propagation direction INTO y from the suffix: normalize(y - z).
    // Opposite to the outward direction from y toward its incoming light.
    // For y -> light: normalize(y - light); for a light endpoint: ls.dir
    // (laser propagation direction, or a dummy direction for a point light).
    float3 rcNextVertexWi;
    // Suffix payload for this reservoir's frame, excluding y's BSDF, camera-prefix throughput, and time gate.
    // This is a weighted incoming-light contribution, NOT raw incoming radiance:
    // y -> light: Li(y) * incident shading cosine.
    // y -> z -> ... -> light: estimated Li(y) * incident shading cosine / original solid-angle pdf(y -> z).
    // This PDF is the BSDF or ellipse density, according to how that edge was sampled.
    // The Li estimate includes later sampled BSDF weights and final light visibility.
    // If y is the light endpoint: ls.Li (source payload).
    float3 rcNextVertexIrradiance;
    // Suffix path length from y to the source, excluding the camera prefix and x -> y.
    // Includes the laser endpoint -> source distance; for a light endpoint, equals ls.laserT.
    float rcNextVertexPathLength;
    // Full candidate camera -> source path length used to evaluate the time gate.
    float totalPathLength;

    // Camera-walk depth of x: primary surface is depth 0, first secondary hit is depth 1.
    // Zero is the sentinel for a candidate with no reconnectable vertex.
    uint rcVertexBounce;
    // BSDF RNG state before this camera path's first BSDF sample; used to replay its prefix.
    // Does not contain the separate reservoir-selection or light-sampling RNG state.
    uint initRandomSeed;

    // Number of camera-walk edges after x before the final direct light connection.
    // 0: x -> light; 1: x -> y -> light; 2: x -> y -> z -> light; etc.
    uint rcNextVertexBounce;
    #if IS_SCENE_DYNAMIC
    // BSDF RNG state immediately before sampling y -> z; assigned only when that edge exists.
    uint rcNextVertexRandomSeed;
    // Original ray arriving at y when y->z was sampled. Reconnection may later move x.
    float3 rcNextVertexRayDirection;
    // Light RNG state immediately before generating this candidate's final light sample.
    uint lightRandomSeed;
    #endif

    [mutating]
    bool update(float3 newf, float weight, float M, inout SampleGenerator sg){
        this.wSum += weight;
        this.M += M;
        if(sampleNext1D(sg) * this.wSum < weight){
#if RESERVOIR_SCALAR_TARGET
            this.f = getReservoirWeight(newf);
#else
            this.f = newf;
#endif
            return true;
        }
        return false;
    }
    __init()
    {
        this.wSum = 0;
        this.M = 0;
        this.f = 0.f;
        this.W = 0.0;
        this.rcNextVertexWi = float3(1,0,0);
        this.rcNextVertexIrradiance = float3(0.0);
        this.rcNextVertexPathLength = 0.0;
        this.rcVertexBounce = 0;
        this.totalPathLength = 0;
        this.rcNextVertexBounce = 0;
    }
};

