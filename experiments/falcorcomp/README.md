# falcorcomp example

Renders an offline time-gated image of the Cornell box with the `falcorcomp` wheel. No Falcor build or `setpath.sh` is needed.

```bash
python3.10 -m venv venv && source venv/bin/activate
pip install falcorcomp-0.1.0-cp310-cp310-linux_x86_64.whl
python render_time_gated_cornell_box.py                # ToF ReSTIR -> output/restir.{exr,png}
python render_time_gated_cornell_box.py --method pt    # path tracing -> output/pt.{exr,png}
```

Options: `--gate-center`, `--gate-width` (path length units), `--spp`, `--spp-per-frame`, `--resolution W H`, `--scene`, `--output`.

The scene is read from `../scene/cornell-box/`. See `packaging/falcorcomp/` for how the wheel is built.
