"""Antithetic sampling for aperiodic binary structured-light codes: codes made of antithetic
blocks (XOR codes, random balanced blocks) and arbitrary codes (optimal-transport and
scale-based maps), each compared with naive sampling at equal time."""
# 1. Load the scene
import time

import matplotlib
matplotlib.use("Agg")  # no window
import matplotlib.pyplot as plt
import numpy as np
import falcorcomp as falcor

testbed = falcor.Testbed(create_window=False)
testbed.load_scene("cornell-box/scene-v4-nolight.pbrt")
testbed.resize_frame_buffer(512, 512)
testbed.scene.camera.aspectRatio = 1.0
testbed.clock.pause()

SECONDS = 0.3              # rendering time for each method
REFERENCE_FRAMES = 16384   # 16384 frames x 16 spp for each reference
COLUMNS = 1024             # code length: one value per projector column

# 2. Make the codes and their antithetic maps


def random_blocks(block=4, seed=0):
    """Every block of `block` columns holds as many 0s as 1s, in random order. Each
    column is paired with a column of the opposite value in its block."""
    rng = np.random.default_rng(seed)
    code = np.concatenate([rng.permutation([0] * (block // 2) + [1] * (block // 2))
                           for _ in range(COLUMNS // block)])
    matching = np.empty(COLUMNS, dtype=np.uint32)
    for start in range(0, COLUMNS, block):
        zeros = start + np.flatnonzero(code[start:start + block] == 0)
        ones = start + np.flatnonzero(code[start:start + block] == 1)
        matching[zeros], matching[ones] = ones, zeros
    return code, matching


def random_code(seed):
    """As many 0s as 1s, shuffled: no structure at all."""
    code = np.array([0] * (COLUMNS // 2) + [1] * (COLUMNS // 2))
    np.random.default_rng(seed).shuffle(code)
    return code


def optimal_transport(code):
    """The k-th 0 is paired with the k-th 1, which minimizes the total distance."""
    zeros, ones = np.flatnonzero(code == 0), np.flatnonzero(code == 1)
    matching = np.empty(COLUMNS, dtype=np.uint32)
    matching[zeros], matching[ones] = ones, zeros
    return matching


def scale_intervals(code):
    """Runs of equal values, each paired with the next run (0s with 1s) and mapped
    linearly onto it: (srcStart, srcEnd, dstStart, dstEnd) in columns, per interval."""
    edges = np.flatnonzero(np.diff(code)) + 1
    runs = list(zip(np.r_[0, edges], np.r_[edges, COLUMNS]))
    ids, intervals = np.empty(COLUMNS, dtype=np.uint32), []

    def add(source, target):
        ids[source[0]:source[1]] = len(intervals)
        intervals.append((*source, *target))

    for i in range(0, len(runs) - 1, 2):
        add(runs[i], runs[i + 1])
        add(runs[i + 1], runs[i])
    if len(runs) % 2:  # a last, unpaired run maps onto itself (no antithetic run)
        add(runs[-1], runs[-1])
    return ids, np.array(intervals, dtype=np.uint32).ravel()


def mean_distance(code, matching):
    """How far columns move on average (the earth mover's distance per column)."""
    return float(np.mean(np.abs(np.arange(COLUMNS) - matching.astype(int))))


# 3. Build the render graph
STRUCTURED_LIGHT = {
    "samplesPerPixel": 1, "maxBounces": 4,
    "computeDirect": False,  # indirect light only
    "projectorPosition": [0.4, 1.0, 6.8], "projectorDirection": [0.0, 0.0, -1.0],
    "projectorFov": [30.0, 30.0], "projectorIntensity": [10.0, 10.0, 10.0],
    "patternAxis": "u",
    "useSingleChannel": True, "singleChannel": "luminance",
}


def create_graph(properties, code=None, **mapping):
    graph = testbed.create_render_graph("StructuredLight")
    graph.create_pass("VBuffer", "VBufferRT", {"samplePattern": "Center", "sampleCount": 1})
    tracer = graph.create_pass("Tracer", "StructuredLightPathTracerInline",
                               {**STRUCTURED_LIGHT, **properties})
    if code is not None:  # an "arbitrary" pattern: the code and its antithetic map
        tracer.set_pattern_data(code.tolist(), **{k: v.tolist() for k, v in mapping.items()})
    graph.create_pass("Accumulate", "AccumulatePass", {"precisionMode": "SingleCompensated"})
    graph.add_edge("VBuffer.vbuffer", "Tracer.vbuffer")
    graph.add_edge("VBuffer.viewW", "Tracer.viewW")
    graph.add_edge("Tracer.color", "Accumulate.input")
    graph.mark_output("Accumulate.output")
    return graph


# 4. Render each method for the same time
def render(graph, seconds=None, frames=None):
    testbed.render_graph = graph
    testbed.frame()  # compiles the shaders
    start = time.perf_counter()
    while time.perf_counter() - start < 1.0:  # warm up the GPU
        testbed.frame()
    graph.get_pass("Accumulate").reset()
    testbed.device.wait()
    count, elapsed = 0, 0.0
    while (elapsed < seconds) if seconds is not None else (count < frames):
        start = time.perf_counter()
        testbed.frame()
        testbed.device.wait()  # include the frame's GPU time
        elapsed += time.perf_counter() - start
        count += 1
    return graph.get_output("Accumulate.output").to_numpy()[..., 0], count


def relative_mse(image, reference):
    return float(np.mean((image - reference) ** 2) / np.mean(reference ** 2))


def compare(methods, reference_graph):
    """methods: (name, graph) pairs rendered for SECONDS each; returns labeled images."""
    reference, _ = render(reference_graph, frames=REFERENCE_FRAMES)
    images = []
    for name, graph in methods:
        image, spp = render(graph, seconds=SECONDS)
        error = relative_mse(image, reference)
        print(f"  {name}: {spp} spp, relMSE {error:.4f}")
        images.append((f"{name}: {spp} spp\nrelMSE {error:.3g}", image))
    return images + [("Reference", reference)]


def show(rows, path):
    fig, axes = plt.subplots(len(rows), len(rows[0][1]),
                             figsize=(3 * len(rows[0][1]), 3.2 * len(rows)), squeeze=False)
    for row, (label, images) in zip(axes, rows):
        limit = np.percentile(np.abs(images[-1][1]), 99)
        for ax, (title, image) in zip(row, images):
            ax.imshow(image, cmap="bwr", vmin=-limit, vmax=limit)
            ax.set_title(title, fontsize=10)
            ax.set_xticks([])
            ax.set_yticks([])
        row[0].set_ylabel(label, fontsize=11)
    fig.tight_layout()
    fig.savefig(path, dpi=100)


# 5. Codes made of antithetic blocks
XOR_BIT = 6  # Gray bit 6, XORed with the base bit
blocks_code, blocks_matching = random_blocks()
BLOCK_CODES = [
    ("XOR-02", dict(properties={"pattern": "xor", "patternBits": 10,
                                "patternBit": XOR_BIT, "patternBaseBit": 0})),
    ("XOR-04", dict(properties={"pattern": "xor", "patternBits": 10,
                                "patternBit": XOR_BIT, "patternBaseBit": 1})),
    ("Random blocks of 4", dict(properties={"pattern": "arbitrary"}, code=blocks_code,
                                antithetic_index=blocks_matching)),
]
rows = []
for name, setup in BLOCK_CODES:
    print(name)
    properties = setup.pop("properties")
    naive = create_graph({**properties, "samplingMethod": "bsdf"}, **setup)
    antithetic = create_graph({**properties, "samplingMethod": "antithetic"}, **setup)
    reference = create_graph({**properties, "samplingMethod": "bsdf", "samplesPerPixel": 16}, **setup)
    rows.append((name, compare([("Naive", naive), ("Antithetic", antithetic)], reference)))
show(rows, "structured_light_blocks.png")

# 6. Arbitrary codes: optimal transport and scale-based maps
rows = []
for seed in [183, 160]:  # a code with a short and one with a long optimal-transport distance
    code = random_code(seed)
    matching = optimal_transport(code)
    ids, intervals = scale_intervals(code)
    distance = mean_distance(code, matching)
    print(f"code {seed}: mean optimal-transport distance {distance:.1f} columns")
    arbitrary = {"pattern": "arbitrary"}
    naive = create_graph({**arbitrary, "samplingMethod": "bsdf"}, code)
    ot = create_graph({**arbitrary, "samplingMethod": "antithetic"}, code, antithetic_index=matching)
    scale = create_graph({**arbitrary, "samplingMethod": "antithetic"}, code,
                         interval_ids=ids, intervals=intervals)
    reference = create_graph({**arbitrary, "samplingMethod": "bsdf", "samplesPerPixel": 16}, code)
    images = compare([("Naive", naive), ("Optimal transport", ot), ("Scale", scale)], reference)
    rows.append((f"Code {seed}\n(distance {distance:.1f})", images))
show(rows, "structured_light_arbitrary.png")

# 7. Plot the two codes and their optimal-transport maps
fig, axes = plt.subplots(2, 2, figsize=(10, 5), gridspec_kw={"height_ratios": [1, 4]})
for column, seed in zip(axes.T, [183, 160]):
    code = random_code(seed)
    matching = optimal_transport(code)
    column[0].imshow(code[None, :256], cmap="gray", aspect="auto", interpolation="nearest")
    column[0].set_title(f"Code {seed}: columns 0 to 255 "
                        f"(distance {mean_distance(code, matching):.1f})", fontsize=10)
    column[0].set_xticks([])
    column[0].set_yticks([])
    column[1].plot(np.arange(COLUMNS), matching, linewidth=0.5)
    column[1].set_xlabel("column $i$")
    column[1].set_ylabel("antithetic column $T(i)$")
fig.tight_layout()
fig.savefig("structured_light_codes.png", dpi=100)
