from offline_rendering import *

def run():
    scene_name = "cornell-box-dragon-diffuse"
    time_gate = 0.01
    max_bounce = 6

    output_folder = "/media/juhyeon/Data1/TransientReSTIR/results_final/result_offline_rendering_v1"

    common_options = {
        "isLightSourceLaser": True,
        "specularRoughnessThreshold": 0.05,
        "laserCollocated": False,
        "isSceneDynamic": False,
        "spatialReuseIteration": 3,
        "spatialReuseNeighborCount": 5,
        "spatialReuseGatherRadius": 10,
        'laserAngle': 0.0
    }

    experiments = {
        "path" : {"integrator": "path"},
        "naive_reconnection" : {"shiftmapMethod": "no"},
        #"ray_trace_avg_grad" : {"shiftmapMethod": "ray_trace", "gaugeMode": "avg_grad", "NewtonMaxIteration":5},
        # "local_tangent_avg_grad" : {"shiftmapMethod": "local_tangent", "gaugeMode": "avg_grad", "NewtonMaxIteration":5},
        "area_adaptive_avg_grad" : {"shiftmapMethod": "area_adaptive", "gaugeMode": "avg_grad", "NewtonMaxIteration":5},
    }

    falcor.Logger.verbosity = falcor.Logger.Level.Error
    testbed = falcor.Testbed(create_window=False)

    # Load scene.
    scene_path = '../scene/%s/scene-v4.pbrt' % (scene)
    testbed.load_scene(scene_path)
    
    timelimits = [3]
    use_time = True

    for expname, expoptions in experiments.items():
        if use_time:
            for timelimit in timelimits:
                run_single_experiment(testbed, scene, output_folder, 
                    0, timegate, maxBounce, expname_temp,
                    {**common_options, **options, **timegaterough_options}, 
                    show_time=True, time_limit=timelimit, 
                    scene_scale=scene_scale, laser_angle=laser_angle, 
                    use_point_light=use_point_light
                )
        else:
            for spp in spps:
                run_single_experiment(testbed, scene, output_folder, 
                    spp * SAMPLE_PER_PASS, timegate, maxBounce, expname_temp,
                    {**common_options, **options, **timegaterough_options}, 
                    show_time=True,
                    scene_scale=scene_scale, laser_angle=laser_angle, 
                    use_point_light=use_point_light
                )

run()