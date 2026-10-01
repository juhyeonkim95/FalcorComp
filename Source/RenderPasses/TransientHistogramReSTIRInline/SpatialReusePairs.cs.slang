import RenderPasses.Shared.Shaders.Utils.TimeGate;
import RenderPasses.Shared.Shaders.Utils.TransientHistogram;
import RenderPasses.Shared.Shaders.ReSTIR.SpatialReuse;

cbuffer CB
{
    SpatialReuse gSpatialReuse;
}

// First pass of a spatial reuse iteration (SPATIAL_REUSE_PAIRS), for the bins of the current chunk: thread (x, y, z)
// computes the shifts of pixel (x / candidates, y)'s candidate x % candidates at the chunk's bin z. A warp holds all
// candidates of a few neighboring pixels, so their loads of the same central data coalesce.
// SpatialReuse.cs.slang then resamples each pixel's bins from these records.
[numthreads(32, 2, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint candidates = gSpatialReuse.getMaxCandidateCount();
    uint2 pixel = uint2(dispatchThreadId.x / candidates, dispatchThreadId.y);
    if (any(pixel >= gSpatialReuse.gFrameDim)) return;
    gSpatialReuse.evaluatePair(pixel, gTimeBin, gSpatialReuse.pairFirstBin + dispatchThreadId.z,
        dispatchThreadId.x % candidates, true);
}
