![](assets/teaser.png)

# ToF ReSTIR 
This repository is the official Falcor implementation of "ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling" (SIGGRAPH 2026, submission id 251).

## Added Render Pass for ToF rendering
We added several render pass for ToF rendering. Instead of using full path tracer (`PathTracer` in Falcor), we implemented our own path tracer with inline raytracing and built variations based on this path tracer.

### Time-gated Image Rendering (H x W)
For time-gated image rendering (per-frame output is H x W), we provides following two render passes.

#### MinimalTimeGatedPathTracer
This is a render pass that uses naive path tracer for ToF rendering.
Followings are parameters used.

- `computeDirect` : whether to also show direct illumination
- `timeGateWindow` : time gate window
- `timeMin` : simulation minimum ToF
- `timeMax` : simulation maximum ToF
- `timeBin` : simulation steps (Simulation repeats from `timeMin` to `timeMax` with step number of `timeBin`. Interval between each frame may not match with `timeGateWindow`.)
- `samplingMethod`: sampling method, one of `direct`, `ellipsoidal`, `tri_approx`
- `useEllipsoidalMIS` : use MIS for ellipsoidal connection (with direct)

#### MinimalTimeGatedReSTIR
This is a render pass that uses ReSTIR algorithm for ToF rendering.
Followings are parameters used. We skip the overlapping parameters.
- `shiftmapMethod` : method for path length shift mapping. should be one of 
(`no` - naive ReSTIR PT, `local_tangent` - use local tangent surface, `barycentric` - use barycentric coordinate, `ray_trace` - use unit hemisphere and ray tracing, `area_adaptive` - use `local_tangent` and `ray_trace` based on hit point's triangle size)
- `gaugeAxis` : Gauge axis used for Newton's iteration
- `gaugeMode` : Gauge searching mode. should be one of (`constant` - use `gaugeAxis`, `grad` - use starting point gradient, `avg_grad` - use both starting and end point gradients)
- `NewtonMaxIteration` : maximum Newton's iteration
- `NewtonRelativeTolerance` : Newton's iteration relative tolerance
- `timeGateWindowRough` : rough time gate (used for shrink mapping)
- `roughTimeGateSampleRatio` : sample ratio that uses rough time gate (used for shrink mappint)
- `temporalHistoryLength` : $M_{cap}$ in ReSTIR paper, to adjust temporal history length.
- `spatialReuseIteration` : spatial reuse iteration
- `spatialReuseNeighborCount` : number of neighbors used for spatial reuse
- `spatialReuseGatherRadius` : size of neighbor searching radiuse for spatial reuse
- `useTemporalReuse` : whether to use temporal reuse (disable for offline rendering)

### Transient Histogram Rendering (H x W x B)
For transient histogram rendering (per-frame output is H x W x B), we provides following two render passes.
Note that for each method, we splat the sampled path's contribution into corresponding time bin (so called path reuse in Jarabo et al.).

#### MinimalTransientPathTracer
This is a render pass that uses naive path tracer for transient histogram rendering.
Followings are parameters used.

- `timeBin` : Time bin is used instead of `timeGateWindow` for transient renderers.
- `useKernelDensityEstimation` : whether to use kernerl density estimation from Jarabo et al.

#### MinimalTransientReSTIR
This is a render pass that uses naive path tracer for transient histogram rendering.
Parameter remains the same with `MinimalTimeGatedReSTIR` case.


### Doppler Frequency Image Rendering (H x W)
We also provides frequency rendering for Doppler shift:
- `MinimalFrequencyGatedPathTracer` : Doppler frequency shift image rendering with naive path tracer.
- `MinimalFrequencyGatedReSTIR` : Doppler frequency shift image rendering with ReSTIR algorithm.
Overall parameters are same with time-gated renderers, but now time means frequency.

## Usage
Here we show how to build render pass for off-line single image rendering with time-gated ReSTIR on python code.

```
def build_tof_render_graph(testbed):
  render_graph = testbed.create_render_graph("PathTracer")

  # Create ToF ReSTIR pass
  render_graph.create_pass(
            "PathTracer", "MinimalTimeGatedReSTIR", 
            {
                "timeMin": 9.0,
                "timeMax": 12.0,
                "timeBin": 512,
                "timeGateWindow": 0.02,
                "laserCollocated": False,
                "isLightSourceLaser": True,
                "samplesPerPixel": 32,
                "shiftmapMethod": "area_adaptive",
                "gaugeMode": "avg_grad",
                "useTemporalReuse": False,
                "spatialReuseIteration": 3,
                "spatialReuseNeighborCount": 5,
                "spatialReuseGatherRadius": 10
            }
        )

    # create V Buffer
    render_graph.create_pass("VBufferRT", "VBufferRT", {'samplePattern': 'Center', 'sampleCount': 1, 'useAlphaTest': True})
    
    # render V Buffer (1 x 1 size) for collimated laser hit point
    laser_position, laser_direction, laser_power = get_laser_info(scene_name)
    render_graph.create_pass(
        "LaserVBufferRT", "LaserVBufferRT", 
        {'samplePattern': 'Center', 'sampleCount': 1, 'useAlphaTest': False,
        'laserPosition': laser_position.tolist(),
        'laserDirection': laser_direction.tolist(),
        'laserPower': laser_power.tolist(),
        'laserAngle': 0.0
        }
    )
    
    # Other render passes
    render_graph.create_pass("AccumulatePass", "AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})
    render_graph.create_pass("ToneMapper", "ToneMapper", {'autoExposure': False, 'exposureCompensation': 0.0})
    

    # connect edges
    render_graph.add_edge("VBufferRT.vbuffer", "PathTracer.vbuffer")
    render_graph.add_edge("VBufferRT.viewW", "PathTracer.viewW")

    render_graph.add_edge("LaserVBufferRT.vbuffer", "PathTracer.laservbuffer")
    render_graph.add_edge("LaserVBufferRT.viewW", "PathTracer.laserviewW")

    render_graph.add_edge("PathTracer.color", "AccumulatePass.input")
    render_graph.add_edge("AccumulatePass.output", "ToneMapper.src")

    # mark output
    render_graph.mark_output("AccumulatePass.output")

    return render_graph
```

## Tutotials
(TBA) We will add more tutorials later.
