// Temporal reuse shared by the time-gated and histogram ReSTIR passes: the previous frame's
// primary hit that a pixel reprojects to, and the mass its reservoirs may carry.
// is_valid_gMotionVector is the pass's define for its optional motion vector input.
import Scene.RaytracingInline;
import RenderPasses.Shared.Shaders.Utils.LoadShadingData;

struct TemporalHistory
{
    bool valid;
    uint pixelIndex;      // Linearized previous pixel.
    ShadingData primary;  // Previous primary hit, seen from the previous camera.
    float primaryLength;  // Previous camera -> previous primary hit.
};

// Follow the motion vector of `pixel` to last frame's V-buffer (previousVBuffer, rendered from
// previousCameraPosition). The prefix change between the frames is left to the shift mapping.
TemporalHistory findTemporalHistory(uint2 pixel, uint2 frameDim, Texture2D<float2> motionVector,
    Texture2D<PackedHitInfo> previousVBuffer, float3 previousCameraPosition)
{
    TemporalHistory history = {};
    float2 previousPosition = float2(pixel) + 0.5f;
#if is_valid_gMotionVector
    previousPosition += motionVector[pixel] * float2(frameDim);
#endif
    if (!all(isfinite(previousPosition)) || any(previousPosition < 0.f) ||
        any(previousPosition >= float2(frameDim))) return history;
    uint2 previousPixel = uint2(floor(previousPosition));
    HitInfo previousHit = HitInfo(previousVBuffer[previousPixel]);
    if (!previousHit.isValid()) return history;
    float3 previousPoint = gScene.getVertexData(previousHit.getTriangleHit()).posW;
    float3 previousDirection = previousPoint - previousCameraPosition;
    history.primaryLength = length(previousDirection);
    if (!(history.primaryLength > 0.f)) return history;
    history.primary = loadShadingData(previousHit, previousCameraPosition,
        previousDirection / history.primaryLength);
    history.pixelIndex = previousPixel.y * frameDim.x + previousPixel.x;
    history.valid = true;
    return history;
}

// Mass of a history reservoir, capped at historyLength frames of samplesPerPixel paths
// (uncapped if historyLength < 0; a length of zero disables temporal reuse altogether).
float temporalHistoryMass(float mass, float historyLength, uint samplesPerPixel)
{
    return historyLength > 0.f ? min(mass, historyLength * float(samplesPerPixel)) : mass;
}
