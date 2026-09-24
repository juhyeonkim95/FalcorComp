// main: sum image on the left half, 4 x 4 grid of selected bins on the right half, and a
// crosshair on the selected pixel. readProfile: the selected pixel's histogram, one thread per bin.

cbuffer CB
{
    uint2 gOutputDim;
    uint3 gHistogramDim; // width, height, bins
    float gSumScale;     // bin width / frame count
    float gTileScale;    // histogram range / frame count * 2^exposure
    uint4 gTileBins[4];  // bin of each tile, row-major
    int2 gSelectedPixel; // histogram pixel with a crosshair and profile; negative if none
    uint gProfileRadius; // the profile averages a (2r + 1)^2 patch
    float gProfileScale; // 1 / frame count
}

Texture3D<float4> gHistogram;
RWTexture2D<float4> gOutput;
RWStructuredBuffer<float4> gProfile;

static const float3 kBorderColor = float3(0.25f);
static const float3 kMarkerColor = float3(0.f, 20.f, 20.f); // cyan after tone mapping

float3 loadBin(uint2 pixel, uint bin)
{
    float4 value = gHistogram[uint3(pixel, bin)];
#if SINGLE_CHANNEL
    return value.rrr;
#else
    return value.rgb;
#endif
}

// The histogram fitted (aspect preserved, centered) into the output rectangle [origin, origin + size).
struct Fit
{
    float2 offset; // output position of histogram pixel (0, 0)'s corner
    float scale;   // output pixels per histogram pixel
};

Fit fitPanel(float2 origin, float2 size)
{
    float2 histogramSize = float2(gHistogramDim.xy);
    Fit fit;
    fit.scale = min(size.x / histogramSize.x, size.y / histogramSize.y);
    fit.offset = origin + 0.5f * (size - fit.scale * histogramSize);
    return fit;
}

// Histogram pixel range covered by output pixel `pixel`. False outside the image.
bool footprint(uint2 pixel, Fit fit, out uint2 first, out uint2 last)
{
    float2 histogramSize = float2(gHistogramDim.xy);
    float2 lo = (float2(pixel) - fit.offset) / fit.scale;
    float2 hi = (float2(pixel) + 1.f - fit.offset) / fit.scale;
    first = uint2(0);
    last = uint2(0);
    if (any(hi <= 0.f) || any(lo >= histogramSize)) return false;
    first = uint2(clamp(floor(lo), 0.f, histogramSize - 1.f));
    last = uint2(clamp(ceil(hi) - 1.f, float2(first), histogramSize - 1.f));
    return true;
}

// Crosshair around the selected pixel with a gap, so the pixel itself stays visible.
bool onMarker(uint2 pixel, Fit fit, float armLength)
{
    if (any(gSelectedPixel < 0)) return false;
    float2 center = fit.offset + (float2(gSelectedPixel) + 0.5f) * fit.scale;
    float2 d = abs(float2(pixel) + 0.5f - center);
    float gap = 0.5f * fit.scale + 1.f;
    return (d.y < 0.5f && d.x >= gap && d.x <= gap + armLength) ||
           (d.x < 0.5f && d.y >= gap && d.y <= gap + armLength);
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
        Fit fit = fitPanel(float2(0.f), float2(halfWidth, gOutputDim.y));
        if (onMarker(pixel, fit, 8.f))
            color = kMarkerColor;
        else if (footprint(pixel, fit, first, last))
            color = sumImage(first, last);
    }
    else
    {
        float2 tileSize = float2(halfWidth, gOutputDim.y) / 4.f;
        float2 local = float2(pixel) - float2(halfWidth, 0.f);
        uint2 tile = min(uint2(local / tileSize), uint2(3));
        float2 tileOrigin = float2(halfWidth, 0.f) + float2(tile) * tileSize;
        Fit fit = fitPanel(tileOrigin + 1.f, tileSize - 1.f);
        // One-pixel border on the left and top edge of every tile.
        if (any(float2(pixel) < tileOrigin + 1.f))
            color = kBorderColor;
        else if (onMarker(pixel, fit, 4.f))
            color = kMarkerColor;
        else if (footprint(pixel, fit, first, last))
            color = binImage(first, last, gTileBins[tile.y][tile.x]);
    }
    gOutput[pixel] = float4(color, 1.f);
}

[numthreads(64, 1, 1)]
void readProfile(uint3 dispatchThreadId: SV_DispatchThreadID)
{
    uint bin = dispatchThreadId.x;
    if (bin >= gHistogramDim.z) return;
    int2 lo = max(gSelectedPixel - int(gProfileRadius), int2(0));
    int2 hi = min(gSelectedPixel + int(gProfileRadius), int2(gHistogramDim.xy) - 1);
    float3 sum = 0.f;
    for (int y = lo.y; y <= hi.y; ++y)
        for (int x = lo.x; x <= hi.x; ++x)
            sum += loadBin(uint2(x, y), bin);
    int2 count = hi - lo + 1;
    gProfile[bin] = float4(sum * gProfileScale / float(count.x * count.y), 0.f);
}
