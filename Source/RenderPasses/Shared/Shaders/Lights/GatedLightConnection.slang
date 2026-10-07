// Next-event estimation under the time gate (gTimeCenter, TimeGate.slang): a connection contributes in proportion to
// the gate on the total length of its path, pathLength (camera to the surface) + connection.distance + light.laserT.
__exported import RenderPasses.Shared.Shaders.Lights.LightConnection;
import RenderPasses.Shared.Shaders.Lights.LaserLightSampler;
import RenderPasses.Shared.Shaders.Utils.TimeGate;
import Utils.Sampling.SampleGenerator;
import Scene.RaytracingInline;

// connectToLight() from a surface at optical path length pathLength, with the total length of the path and its gate.
// Returns whether the connection can contribute: connected and inside the gate. Otherwise its radiance stays zero,
// and callers skip shadeLightConnection() (a visibility ray and a BSDF evaluation) and whatever only scales it.
bool connectToLightGated(ShadingData surface, LightSample light, float pathLength, out LightConnection connection,
    out float totalLength, out float gate, bool useWideGate = false)
{
    bool connected;
    connection = connectToLight(surface, light, connected);
    totalLength = pathLength + connection.distance + light.laserT;
    gate = pathLengthImportance(totalLength, gTimeCenter, useWideGate);
    return connected && gate != 0.f;
}

// BSDF * cosine * Li * gate of the connection from a surface at optical path length pathLength; zero outside the gate.
float3 evalGatedLightConnection(ShadingData surface, IMaterialInstance material, LightSample light, float pathLength,
    inout SampleGenerator rng)
{
    LightConnection connection;
    float totalLength, gate;
    if (connectToLightGated(surface, light, pathLength, connection, totalLength, gate))
        shadeLightConnection(connection, surface, material, light, rng);
    return connection.bsdfCosine * connection.incidentRadiance * gate;
}
