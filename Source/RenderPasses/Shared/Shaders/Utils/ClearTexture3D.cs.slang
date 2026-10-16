/** Zeroes every texel of a 3D float texture (InlinePass::Texture3DClearer).

    gfx's UAV clear on Vulkan leaves depth slices from 1024 on untouched, so per-pixel stacks that are cleared every
    frame and then added to (histograms, per-bounce layers) would keep accumulating there.
    CHANNELS (1, 2 or 4) must match the texture format (R32Float, RG32Float, RGBA32Float).
*/
#ifndef CHANNELS
#define CHANNELS 1
#endif

#if CHANNELS == 1
typedef float Texel;
#elif CHANNELS == 2
typedef float2 Texel;
#else
typedef float4 Texel;
#endif

cbuffer CB
{
    uint3 gSize;
}

RWTexture3D<Texel> gTexture;

[numthreads(8, 8, 4)]
void main(uint3 id: SV_DispatchThreadID)
{
    if (any(id >= gSize))
        return;
    gTexture[id] = Texel(0.f);
}
