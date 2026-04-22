import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;
import EventSVGFCommon;

cbuffer PerImageCB
{
    float eventThreshold;

    Texture2D gPrevBrightness;
    Texture2D gCurrentBrightnessDifference;
};

float4 main(FullScreenPassVsOut vsOut) : SV_TARGET0
{
    const int2 ipos = int2(vsOut.posH.xy);
    float B = CurrentBrightnessDifference[ipos] + PrevBrightness[ipos];
    int event = 0;
    if(B > eventThreshold){
        B -= eventThreshold;
        event += 1;
    }
    if(B < - eventThreshold){
        B += eventThreshold;
        event -=1;
    }
    return float4(B, event, 0.0, 0.0);
}