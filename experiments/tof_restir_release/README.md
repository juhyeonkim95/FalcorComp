# Offline experiments: PT vs naive vs ours

Code: `src/`, plots: `src/plots/`, launchers: `scripts/`, configs: `scenes/exp1/` and `scenes/exp2/`, results: `outputs/`.

From the repository root, with Falcor built:

```bash
source build/GCC_11.3.0x86_64-linux-gnu/bin/setpath.sh
python -m pip install -r experiments/tof_restir_release/requirements.txt

# Experiment 1: equal time across methods for each scene.
bash experiments/tof_restir_release/scripts/run_exp1_offline_rendering_with_spatial_reuse_equal_time.sh

# Experiment 2: diffuse dragon, 3 seconds per method, varying gate width.
bash experiments/tof_restir_release/scripts/run_exp2_offline_rendering_with_spatial_reuse_gate_width_sweep.sh
```

Edit scene/light settings and `shiftmapMethod` for **ours** in each experiment's
scene JSON; **naive** always uses `"no"`. Gate widths and time budgets are in the
shell scripts. Both experiments use direct sampling and spatial reuse only.
Set `"shiftmapMethod": "ray_trace_chart"` for the non-polar Cartesian chart
in the fixed next-vertex frame; `"ray_trace"` keeps the polar parameterization.

Results go to `outputs/exp1_offline_rendering_with_spatial_reuse_equal_time/` or
`outputs/exp2_offline_rendering_with_spatial_reuse_gate_width_sweep/` without timestamps.
Each scene/gate saves images, timings, a 262,144-SPP direct PT reference, and
`errors.csv`. Reference rendering shows progress and ETA. Reruns clear old comparison images and tables, reuse compatible saved GT, and
regenerate GT if its settings differ. To force fresh GT, use `--regenerate-reference`
with the Python entry point. `--reference-spp` applies when generating GT.

Experiment 2 plots RMSE, relative MSE, and grayscale MAPE (fraction) with logarithmic axes for both linear NPY and display RGB PNG inputs. Display-domain plots end in `_png.png`; tables are `errors_npy.csv` and `errors_png.csv`. Replot with:

```bash
python experiments/tof_restir_release/src/plots/plot_exp2_offline_rendering_with_spatial_reuse_gate_width_sweep.py <experiment-output-directory>
```

For equal SPP, use `src/offline_rendering_with_spatial_reuse_comparison.py`
with `--scene`, `--gate-width`, `--spp 32 64 128 256`, and `--output`.
