/** Transport probing (O'Toole et al. 2012, 2014; Shared/Host/Configs/ProbingConfig.h). A path whose camera ray has the
    unit direction cameraDir (from the camera) and whose projector ray has the unit direction projectorDir (from the
    light to the path's last vertex) is weighted by Pi(i, j), from the epipolar lines of the two rays. The epipolar
    lines are the planes through the baseline, the line through the camera and the light; with the light at the camera
    (coaxial), the planes through the camera and its right axis, the image rows.

      PROBING_EPIPOLAR:     1 when the projector ray lies on the camera ray's line, within half a line width: the
                            direct and retro-reflective photo. Coaxial: when the projector ray is the camera ray.
      PROBING_NON_EPIPOLAR: the complement, the indirect-only photo.
      PROBING_MASKS:        K random masks m_k of the camera's lines and their complements p_k = 1 - m_k shown by the
                            projector (O'Toole et al. 2014, Algorithm 2): (4 / K) sum_k m_k(line i) p_k(line j), zero
                            on the same line and 1 on average elsewhere, which approximates PROBING_NON_EPIPOLAR.
*/
#include "Utils/Math/MathConstants.slangh"
import Utils.Math.HashUtils;

#define PROBING_NONE 0
#define PROBING_EPIPOLAR 1
#define PROBING_NON_EPIPOLAR 2
#define PROBING_MASKS 3

#ifndef PROBING_MODE
#define PROBING_MODE PROBING_NONE
#endif

cbuffer Probing
{
    float gProbingLineAngle;    // Width of an epipolar line, in radians.
    uint gProbingMaskCount;     // Masks: K, 1 to 128.
    uint gProbingSeed;          // Masks: seed of the random masks.
    float3 gProbingCameraRight; // Unit right axis of the camera: the axis of the coaxial lines.
}

/// Below this baseline, the light is at the camera (coaxial).
static const float kCoaxialBaseline = 1e-6f;

/// The axis of the epipolar planes: the baseline's direction, or the camera's right axis when the light is at the
/// camera.
float3 epipolarAxis(float3 cameraPos, float3 projectorPos, out bool coaxial)
{
    float3 baseline = projectorPos - cameraPos;
    float baselineLength = length(baseline);
    coaxial = !(baselineLength > kCoaxialBaseline);
    return coaxial ? gProbingCameraRight : baseline / baselineLength;
}

/// Whether the projector ray lies on the camera ray's epipolar line, within half a line width; coaxial, whether it is
/// the camera ray.
bool onEpipolarLine(float3 cameraPos, float3 cameraDir, float3 projectorPos, float3 projectorDir)
{
    bool coaxial;
    float3 axis = epipolarAxis(cameraPos, projectorPos, coaxial);
    float tolerance = sin(0.5f * gProbingLineAngle);
    if (coaxial)
        return dot(cameraDir, projectorDir) > 0.f && length(cross(cameraDir, projectorDir)) <= tolerance;
    float3 normal = cross(axis, cameraDir);
    float normalLength = length(normal);
    if (!(normalLength > 0.f)) return true; // A camera ray along the baseline lies on every epipolar plane.
    return abs(dot(normal / normalLength, projectorDir)) <= tolerance;
}

/// Index of the epipolar line, a plane through `axis`, that holds the direction `v`: its angle around the axis in
/// [0, pi), in lines of gProbingLineAngle.
uint epipolarLine(float3 axis, float3 v)
{
    float3 w1 = normalize(cross(axis, abs(axis.x) < 0.9f ? float3(1.f, 0.f, 0.f) : float3(0.f, 1.f, 0.f)));
    float3 w2 = cross(axis, w1);
    float3 normal = cross(axis, v);
    float angle = atan2(dot(normal, w2), dot(normal, w1));
    angle -= M_PI * floor(angle / M_PI); // The planes are unoriented.
    return uint(angle / gProbingLineAngle);
}

/// Masks k = 32 word .. 32 word + 31 of the line `line`, one bit each.
uint maskBits(uint line, uint word)
{
    return jenkinsHash(jenkinsHash(jenkinsHash(gProbingSeed) ^ line) + word);
}

/// (4 / K) sum_k m_k(lineI) (1 - m_k(lineJ)).
float maskWeight(uint lineI, uint lineJ)
{
    uint count = 0;
    for (uint word = 0; 32u * word < gProbingMaskCount; word++)
    {
        uint bits = min(gProbingMaskCount - 32u * word, 32u);
        uint valid = bits == 32u ? 0xffffffffu : (1u << bits) - 1u;
        count += countbits(maskBits(lineI, word) & ~maskBits(lineJ, word) & valid);
    }
    return 4.f * float(count) / float(gProbingMaskCount);
}

/// Pi(i, j) of a path (PROBING_MODE); 1 without probing.
float probingWeight(float3 cameraPos, float3 cameraDir, float3 projectorPos, float3 projectorDir)
{
#if PROBING_MODE == PROBING_EPIPOLAR
    return onEpipolarLine(cameraPos, cameraDir, projectorPos, projectorDir) ? 1.f : 0.f;
#elif PROBING_MODE == PROBING_NON_EPIPOLAR
    return onEpipolarLine(cameraPos, cameraDir, projectorPos, projectorDir) ? 0.f : 1.f;
#elif PROBING_MODE == PROBING_MASKS
    bool coaxial;
    float3 axis = epipolarAxis(cameraPos, projectorPos, coaxial);
    return maskWeight(epipolarLine(axis, cameraDir), epipolarLine(axis, projectorDir));
#else
    return 1.f;
#endif
}
