import matplotlib
matplotlib.use('svg')

import falcor
from utils.image_utils import *
import ast
from tqdm import tqdm, trange
import matplotlib.pyplot as plt
import matplotlib.cm as cm
from PIL import Image
from utils.path_utils import *
import time

def setup_renderpass(testbed, **kwargs):
    if testbed.render_graph != None:
        print("________EXIST")
        return
    print("________CREATE")
    render_graph = testbed.create_render_graph("PathTracer")
    useAntitheticSampling = kwargs.get("useAntitheticSampling", True)

    # create render pass
    render_graph.create_pass(
        "PathTracer", "MinimalCWToFPathTracer", 
        {
            'computeDirect': kwargs.get("computeDirect", True),
            'samplesPerPixel': 1,
            'maxBounces': int(kwargs.get("maxBounces", 4)),
            "useAntitheticSampling": useAntitheticSampling,
            "patternTotalBits": int(kwargs.get("patternTotalBits")),
            "patternCurrentBit": int(kwargs.get("patternCurrentBit")),
            "patternUseVertical": bool(kwargs.get("patternUseVertical")),
            "patternBaseBit":0
        }
    )

    # V buffer
    render_graph.create_pass("VBufferRT", "VBufferRT", 
        {'samplePattern': 'Halton', 'sampleCount': 32, 'useAlphaTest': True}
    )

    # accumulate pass
    render_graph.create_pass("AccumulatePass", "AccumulatePass", {'enabled': True, 'precisionMode': 'Single'})

    render_graph.add_edge("VBufferRT.vbuffer", "PathTracer.vbuffer")
    render_graph.add_edge("VBufferRT.viewW", "PathTracer.viewW")
    render_graph.add_edge("PathTracer.color", "AccumulatePass.input")
    render_graph.mark_output("AccumulatePass.output")
    testbed.render_graph = render_graph

def run(testbed, **kwargs):
    setup_renderpass(testbed, **kwargs)
    testbed.render_graph.get_pass("PathTracer").set_pattern_info(
        int(kwargs.get("patternTotalBits")),
        int(kwargs.get("patternCurrentBit")),
        int(kwargs.get("patternBaseBit", 0)),
        bool(kwargs.get("patternUseVertical")),
    )
    
    testbed.resize_frame_buffer(1024, 1024)
    
    time_budget = kwargs.get("time", -1)
    spp_budget = kwargs.get("spp", 16)

    if time_budget > 0:
        # skip some initial frames
        for _ in range(200):
            testbed.frame()

    # start rendering
    testbed.render_graph.get_pass("AccumulatePass").reset()
    
    testbed.profiler.enabled = True
    testbed.profiler.start_capture()

    if time_budget > 0:
        print("===========(Time Budget)===========")
        spp_budget = 0
        # run for Time budget
        start = time.time()
        while time.time() - start < time_budget:
            testbed.frame()
            spp_budget += 1
    else:
        print("===========(SPP Budget)===========")
        #run for SPP budget
        for i in trange(spp_budget):
            testbed.frame()

    capture = testbed.profiler.end_capture()
    testbed.profiler.enabled = False
    meanTimes = capture["events"]["/RenderGraphExe::execute()/gpu_time"]["stats"]["mean"]
    values = capture["events"]["/RenderGraphExe::execute()/gpu_time"]["records"]
    
    output = testbed.render_graph.get_output("AccumulatePass.output").to_numpy()[...,0:3]
    image = get_luminance(output)

    result_output_folder = kwargs.get("result_output_folder")
    scene_name = kwargs.get("scene_name")
    expname = kwargs.get("expname")
    filename = kwargs.get("filename")
    useAntitheticSampling = kwargs.get("useAntitheticSampling", True)

    output_folder = "%s/%s/%s/%s" % (PROJECT_FOLDER, result_output_folder, scene_name, expname)
    if not os.path.exists(output_folder):
        os.makedirs(output_folder)

    np.save("%s/%s_spp_%d.npy" % (output_folder, filename, spp_budget), image)


    img = image
    H, W = img.shape
    fig = plt.figure(figsize=(H/100, W/100), dpi=100)
    ax = plt.axes([0, 0, 1, 1])  # full canvas
    ax.imshow(img, vmin=-0.0001, vmax=0.0001, cmap="bwr")
    ax.set_axis_off()

    plt.savefig(
        "%s/%s_spp_%d.png" % (output_folder, filename, spp_budget),
        dpi=100,
        bbox_inches='tight',
        pad_inches=0
    )
    plt.close(fig)

def run_exp(expname, useAntitheticSampling, spp, **kwargs):
    testbed = falcor.Testbed(create_window=False)
    scene_name = "cornell-box-bunny-diffuse"
    scene_path = '../scenes/%s/scene-v4.pbrt' % scene_name
    
    common_configs = {
        "result_output_folder":"20260501_testcode",
        "scene_name":scene_name, **kwargs
    }

    testbed.load_scene(scene_path)
    patternTotalBits = kwargs.get("patternTotalBits", 0)
    patternBaseBit = kwargs.get("patternBaseBit", 0)

    patternUseVerticals = [True, False]
    current_bits = [0] #list(np.arange(patternTotalBits))
    
    for current_bit in current_bits:
        for patternUseVertical in patternUseVerticals:
            filename = "%s_%d" % ("vertical" if patternUseVertical else "horizontal", current_bit)
            run(testbed, 
                patternCurrentBit=current_bit, 
                patternUseVertical=patternUseVertical, 
                expname="totalbit_%d/xor_%d/%s" % (patternTotalBits, 1 << (patternBaseBit + 1), expname),
                filename=filename,
                spp = spp,
                useAntitheticSampling=useAntitheticSampling, **common_configs)


if __name__ == "__main__":
    total_bits = [10]
    xor_bits = [0, 1]

    for total_bit in total_bits:
        for xor_bit in xor_bits:
            common_configs = {"patternTotalBits": total_bit, "patternBaseBit": xor_bit}
            run_exp("antithetic_indirect", True, spp=64 * 4, computeDirect=False, **common_configs)
            run_exp("naive_indirect", False, spp=128 * 4, computeDirect=False, **common_configs)
            run_exp("GT_indirect", True, spp=2048 * 16, computeDirect=False, **common_configs)