"""GPU regression for histogram temporal reuse (static geometry and light, moving camera).

Build the histogram pass and source bin/setpath.sh before running.
Checks finite output, histogram/color consistency, that history is actually reused,
that temporal-only reuse matches the no-reuse mean, and that a moving camera stays valid.

Each render runs in its own process with a single render graph: replacing the render graph
within one process can crash the Vulkan driver, as the old graph's ray-tracing objects are
freed while frames in flight still refer to them.
"""
from pathlib import Path
import argparse
import math
import subprocess
import sys
import tempfile
import numpy as np

SCENE = Path(__file__).resolve().parents[4] / 'docs_falcorcomp/src/tutorials/scenes/cornell-box/scene-v4-nolight.pbrt'
TIME_RANGE = (14., 30., 32)

# Render stages: frames, temporal reuse, spatial reuse iterations, moving camera.
STAGES = {
    'first_off': (2, False, 0, False),
    'first_on': (2, True, 0, False),
    'mean_off': (256, False, 0, False),
    'mean_on': (256, True, 0, False),
    'moving_spatial0': (32, True, 0, True),
    'moving_spatial1': (32, True, 1, True),
    'static_single': (1, False, 0, False),
}


def render(frames, temporal, spatial, move):
    """Renders one stage with one render graph; returns the per-frame histograms."""
    import falcor
    falcor.Logger.verbosity = falcor.Logger.Level.Error
    f = falcor.Testbed(create_window=False)
    f.load_scene(str(SCENE))
    f.resize_frame_buffer(33, 25)
    camera = f.scene.camera
    camera.aspectRatio = 33 / 25
    camera.apertureRadius = 0
    f.clock.pause()
    # Copy: camera.position returns a live reference.
    position = falcor.float3(camera.position.x, camera.position.y, camera.position.z)
    target = falcor.float3(camera.target.x, camera.target.y, camera.target.z)

    g = f.create_render_graph('temporal')
    g.create_pass('V', 'VBufferRT', {'samplePattern': 'Center', 'sampleCount': 1})
    g.create_pass('L', 'LaserLight', {'laserPosition': [0., 1.7, 6.8], 'laserDirection': [0., 0., -1.],
                                      'laserPower': [170., 120., 40.], 'laserAngle': 0.})
    g.create_pass('P', 'TransientHistogramReSTIRInline', {
        'samplesPerPixel': 4, 'timeMin': TIME_RANGE[0], 'timeMax': TIME_RANGE[1], 'timeBin': TIME_RANGE[2],
        'histogramFilter': 'box', 'useSingleChannel': True, 'maxBounces': 4,
        'spatialReuseIteration': spatial, 'spatialReuseNeighborCount': 3, 'spatialReuseGatherRadius': 6.,
        'shiftmapMethod': 'local_tangent', 'gaugeMode': 'avg_grad',
        'useTemporalReuse': temporal, 'temporalHistoryLength': 20.})
    for a, b in [('V.vbuffer', 'P.vbuffer'), ('V.viewW', 'P.viewW'), ('V.mvec', 'P.mvec'),
                 ('L', 'P')]:
        g.add_edge(a, b)
    g.mark_output('P.histogram')
    g.mark_output('P.color')
    f.render_graph = g
    unit = (TIME_RANGE[1] - TIME_RANGE[0]) / TIME_RANGE[2]
    histograms = []
    for frame in range(frames):
        if move:
            offset = 0.15 * math.sin(2 * math.pi * frame / 16)
            camera.position = falcor.float3(position.x + offset, position.y + 0.5 * offset, position.z)
            camera.target = falcor.float3(target.x + offset, target.y + 0.5 * offset, target.z)
        f.frame()
        h = g.get_output('P.histogram').to_numpy().astype(np.float64).squeeze()
        color = g.get_output('P.color').to_numpy()[..., 0]
        assert np.isfinite(h).all() and (h >= 0).all()
        np.testing.assert_allclose(h.sum(axis=0) * unit, color, rtol=1e-4, atol=1e-5)
        assert h.max() > 0
        histograms.append(h)
    return np.array(histograms)


def run_stages(directory):
    """Runs every stage in a separate process and loads the histograms it saved."""
    results = {}
    for name in STAGES:
        path = Path(directory) / f'{name}.npy'
        process = subprocess.run([sys.executable, __file__, '--stage', name, '--output', str(path)],
                                 capture_output=True, text=True)
        if process.returncode != 0:
            sys.stderr.write(process.stdout + process.stderr)
            raise RuntimeError(f'Stage {name} failed with exit code {process.returncode}.')
        results[name] = np.load(path)
    return results


def main():
    with tempfile.TemporaryDirectory() as directory:
        r = run_stages(directory)

    # The first frame has no history; later frames must actually reuse it.
    off, on = r['first_off'], r['first_on']
    np.testing.assert_array_equal(on[0], off[0])
    assert not np.allclose(on[1], off[1])
    print('Passed first-frame identity and history reuse', flush=True)

    # Temporal-only reuse is unbiased: compare per-frame totals over a static sequence.
    off_total = r['mean_off'].sum(axis=(1, 2, 3))
    on_total = r['mean_on'].sum(axis=(1, 2, 3))
    batch = lambda t: t.reshape(8, -1).mean(axis=1)
    error = np.hypot(batch(off_total).std(), batch(on_total).std()) / np.sqrt(8)
    z = (on_total.mean() - off_total.mean()) / error
    assert abs(z) < 4., z
    print(f'Passed temporal-only mean (on/off {on_total.mean() / off_total.mean():.4f}, z {z:+.2f})', flush=True)

    # A moving camera reprojects through motion vectors, with and without spatial reuse.
    covered = (r['static_single'].sum(axis=0) > 0).sum()
    for name in ('moving_spatial0', 'moving_spatial1'):
        assert (r[name].sum(axis=0) > 0).sum() > 0.5 * covered
    print('Passed moving camera', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=list(STAGES))
    parser.add_argument('--output')
    args = parser.parse_args()
    if args.stage:
        np.save(args.output, render(*STAGES[args.stage]))
    else:
        main()
