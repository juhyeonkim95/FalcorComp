// Sum image on the left half, 4 x 4 grid of selected bins on the right half.

cbuffer CB
{
    uint2 gOutputDim;
    uint3 gHistogramDim; // width, height, bins
    float gSumScale;     // bin width / frame count
    float gTileScale;    // histogram range / frame count * 2^exposure
    uint4 gTileBins[4];  // bin of each tile, row-major
}

Texture3D<float4> gHistogram;
RWTexture2D<float4> gOutput;

static const float3 kBorderColor = float3(0.25f);

float3 loadBin(uint2 pixel, uint bin)
{
    float4 value = gHistogram[uint3(pixel, bin)];
#if SINGLE_CHANNEL
    return value.rrr;
#else
    return value.rgb;
#endif
}

// Histogram pixel range covered by output pixel `pixel` when the histogram is fitted (aspect
// preserved, centered) into the output rectangle [origin, origin + size). False outside the image.
bool footprint(uint2 pixel, float2 origin, float2 size, out uint2 first, out uint2 last)
{
    float2 histogramSize = float2(gHistogramDim.xy);
    float scale = min(size.x / histogramSize.x, size.y / histogramSize.y);
    float2 offset = origin + 0.5f * (size - scale * histogramSize);
    float2 lo = (float2(pixel) - offset) / scale;
    float2 hi = (float2(pixel) + 1.f - offset) / scale;
    first = uint2(0);
    last = uint2(0);
    if (any(hi <= 0.f) || any(lo >= histogramSize)) return false;
    first = uint2(clamp(floor(lo), 0.f, histogramSize - 1.f));
    last = uint2(clamp(ceil(hi) - 1.f, float2(first), histogramSize - 1.f));
    return true;
}

float3 sumImage(uint2 first, uint2 last)
{
    float3 sum = 0.f;
    for (uint y = first.y; y <= last.y; ++y)
        for (uint x = first.x; x <= last.x; ++x)
            for (uint bin = 0; bin < gHistogramDim.z; ++bin)
                sum += loadBin(uint2(x, y), bin);
    uint2 count = last - first + 1;
    return sum * gSumScale / float(count.x * count.y);
}

float3 binImage(uint2 first, uint2 last, uint bin)
{
    float3 sum = 0.f;
    for (uint y = first.y; y <= last.y; ++y)
        for (uint x = first.x; x <= last.x; ++x)
            sum += loadBin(uint2(x, y), bin);
    uint2 count = last - first + 1;
    return sum * gTileScale / float(count.x * count.y);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint2 pixel = dispatchThreadId.xy;
    if (any(pixel >= gOutputDim)) return;

    float3 color = 0.f;
    float halfWidth = 0.5f * float(gOutputDim.x);
    uint2 first, last;
    if (float(pixel.x) < halfWidth)
    {
        if (footprint(pixel, float2(0.f), float2(halfWidth, gOutputDim.y), first, last))
            color = sumImage(first, last);
    }
    else
    {
        float2 tileSize = float2(halfWidth, gOutputDim.y) / 4.f;
        float2 local = float2(pixel) - float2(halfWidth, 0.f);
        uint2 tile = min(uint2(local / tileSize), uint2(3));
        float2 tileOrigin = float2(halfWidth, 0.f) + float2(tile) * tileSize;
        // One-pixel border on the left and top edge of every tile.
        if (any(float2(pixel) < tileOrigin + 1.f))
            color = kBorderColor;
        else if (footprint(pixel, tileOrigin + 1.f, tileSize - 1.f, first, last))
            color = binImage(first, last, gTileBins[tile.y][tile.x]);
    }
    gOutput[pixel] = float4(color, 1.f);
}
