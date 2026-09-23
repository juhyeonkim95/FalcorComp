Edit `OUTPUT_PATH` in [`output_config.py`](output_config.py) once for all release experiments.
Release outputs are stored under `$OUTPUT_PATH/`.

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

Exp2 reuse statistics (naive vs ours, no PT/GT; rebuild the render pass first):

```bash
bash experiments/tof_restir_release/scripts/run_exp2_offline_rendering_with_spatial_reuse_statistics.sh
```

Saves separate counter NPYs, mapping-distance NPYs, RGB images, `statistics.csv` per gate, and
`actual_reuse_success_rate.png`/`.svg` in `outputs/exp2_offline_rendering_with_spatial_reuse_statistics/`.
Rate = total actual successes / total eligible reuse attempts (including naive/identity maps).
Visibility and gate failures count as failures; this measures candidate support, not reservoir selection.
Replot with `python experiments/tof_restir_release/src/plots/plot_exp2_spatial_reuse_statistics.py <output-directory>`.

Exp3: print a scene table for **ours** (Cornell diffuse dragon, veach-ajar, kitchen, bedroom, staircase).
Gate centers: `17.337084`, `19`, `17`, `15`, `24`; gate widths are in the shell script.
Set `light_collocated: true` to use the camera position and viewing direction for the light.
Veach-ajar/staircase use lasers; kitchen/bedroom use point lights.

```bash
bash experiments/tof_restir_release/scripts/run_exp3_offline_rendering_with_newton_statistics_by_scene.sh
```

Saves `table.csv` and `table.txt` under `outputs/exp3_offline_rendering_with_newton_statistics_by_scene/`.
Average steps and success rates use eligible reuse attempts; identity shortcuts count as zero-step mapping successes.
Add scenes in `scenes/exp3/` and the shell script's `experiments` list.

Exp4: Cornell box, diffuse dragon, veach-ajar, kitchen, bedroom, staircase; horizontal `(1,0)` / vertical `(0,1)` / `avg_grad`:

```bash
bash experiments/tof_restir_release/scripts/run_exp4_offline_rendering_with_gauge_comparison.sh
```

Prints errors and saves `errors.csv`, images, and timings in `outputs/exp4_offline_rendering_with_gauge_comparison/<scene>/`.
Warm-up is excluded from the sample budget; compatible saved GT is reused.

With `debugNewtonIterations=true`, RGB is preserved. `newtonStatistics` is uint4
(mapping successes, actual successes, attempts, iteration sum); `mappingDistance`
is float2 (summed `|xi_prime-xi|`, summed `|p(xi_prime)-p(xi)|`). Distances cover
successful solves before visibility, with zero for identity maps. Exp2/3 save sums
and means per mapping success; exp3 includes the means in its table. Rebuild the pass.

Exp4 also prints mean coordinate/world mapping distances and saves their sums,
means, and mapping-success counts in `checkpoints.csv` and `errors.csv`.
Warm-up is excluded; reported rendering time includes diagnostic shader work but
excludes buffer readback and CPU aggregation.

Exp5: PT / naive / ours × direct / ellipsoid / ellipsoid_mis:

```bash
bash experiments/tof_restir_release/scripts/run_exp5_offline_rendering_with_initial_sampling_comparison.sh
```

Edit each `run_scene` line for scene-specific `frames`, `spp`, or `seconds` checkpoints
(frames use 32 SPP). Scene/light settings are in `scenes/exp5/`. Warm-up is excluded;
compatible GT is reused, otherwise a direct-PT reference is rendered.
Rendering saves images, GT, and checkpoint timing/SPP data. The plotting script recalculates
`errors.csv` against the current GT and saves
RMSE/relative-MSE/MAPE plots against both
actual SPP and measured time in `plots/` (PNG + SVG). Colors identify renderers;
line styles and markers identify sampling methods. Curves use actual checkpoints without interpolation.
Plot without rendering. Edit `output_dir` and `sampling_methods` in the shell script;
defaults show direct + ellipsoid_mis:

```bash
bash experiments/tof_restir_release/scripts/plot_exp5_initial_sampling_comparison.sh
```

Results are separated automatically into `equal_spp/<scene>/` and `equal_time/<scene>/`.
Use `frames`/`spp` or `seconds` in the rendering shell script. Both modes share a single
GT at `$OUTPUT_PATH/reference/<scene_name>/<gate_width>/reference.npy` across all offline experiments. Plotting processes both;
edit `budget_modes` to select just one.


Exp5 Bistro uses the scene's default camera. Its point light follows this camera;
gate center is `40`.

Exp6: shrink mapping, initial sampling only (40 settings, 32 frames × 32 SPP).

```bash
bash experiments/tof_restir_release/scripts/run_exp6_offline_rendering_with_shrink_mapping.sh
bash experiments/tof_restir_release/scripts/plot_exp6_shrink_mapping.sh
```

Edit settings in the shell scripts. Plotting recalculates MAPE and saves CSV plus
PNG/SVG curves over gate multiplier, colored by rough-sample ratio. Compatible GT
is reused. Ratio `0.00` uses only original-gate samples; ratio `1.00` uses only
wide-gate samples, shrunk to the original gate.

All offline rendering shares GT in `$OUTPUT_PATH/reference/<scene_name>/<gate_width>/`
(e.g. `cornell-box-dragon-diffuse/0.0100/`). Physical settings are checked before reuse.

Exp7: unified PT / naive / ours sequences (gate, camera, and light motion).

```bash
bash experiments/tof_restir_release/scripts/run_exp7_online_rendering_equal_time.sh
bash experiments/tof_restir_release/scripts/evaluate_exp7_sequence.sh
```

Edit per-scene budgets/reuse settings in the rendering shell script and grid frames
in the evaluation script. All scene configs are in `scenes/exp7/`.
- Set `gate_center` for a fixed gate, or `gate_min`/`gate_max` for an endpoint-exclusive sweep.
- `camera_speed` is world units/frame; optional `camera_direction` defaults to the initial forward direction.
- `light_collocated: true` makes the light follow the camera. Otherwise `laser_velocity` moves the light independently.
- `laser_motion_start_frame` preserves delayed motion when needed (NLOS uses 1).

ReSTIR automatically enables dynamic suffix reevaluation when the light moves.
Camera-only motion with a fixed light reuses static suffix lighting. Geometry/materials stay fixed.
Timing-only calibration adjusts PT/naive SPP to ours, then exports images/videos.
Evaluation separately saves errors and image grids. Outputs: `$OUTPUT_PATH/exp7_online_rendering_equal_time/<scene>/`.
All sequence GT shares `$OUTPUT_PATH/reference_sequence/<scene>/<gate_width>/` and is reused when settings match.

Exp8 — Cornell histogram comparison (PT / Epanechnikov KDE / triangle approximation):
```bash
bash experiments/tof_restir_release/scripts/run_exp8_offline_histogram_comparison.sh
bash experiments/tof_restir_release/scripts/evaluate_exp8_histogram_comparison.sh
```
Edit SPP, bins, and KDE bandwidth ratio in the render shell; pixel coordinates in the evaluation shell.
Defaults: 256×256, 64 bins over [16.75, 18.03), 64 spp, GT 1024 spp, pixel (192,132).
Saves H×W×B red-channel NPY arrays; evaluation saves pixel curves, errors, PNG and SVG.
GT is cached in `$OUTPUT_PATH/reference_histogram/`. Triangle approximation ignores SPP.

Application 1 — scanning NLOS (SNLOS): PT / naive reuse / ours at equal time.
```bash
bash experiments/tof_restir_release/scripts/run_application_1_snlos_rendering.sh
bash experiments/tof_restir_release/scripts/run_application_1_snlos_reconstruction.sh
```
The camera and laser sit at O = (-1, 0, 4) facing the relay wall z = 0; a 25×25 voxel grid
covers the hidden plane around (2, 0, 4). Voxels are scanned in a column-wise serpentine; for
each voxel V the gate is 2τ with τ = |O−C| + |C−V| + 0.5, and the laser visits 16 points on
the illumination ellipse (|O−W| + |W−V| = τ), one frame each. Initial samples use ellipsoidal
connection without MIS; naive and ours use temporal reuse across these frames (the laser
moves, so the scene is dynamic) plus spatial reuse (1 iteration, 3 neighbors, radius 5).
PT and naive SPP are calibrated so their mean frame time matches ours at 32 SPP (exp7
procedure, timed on the first 50 voxels). Hidden objects: `scenes/application_1/`.

Rendering saves per-voxel radiance stacks and `plots_rendering/`: frames with the voxel's
detection ellipse in red, a selected-voxel figure, and MP4s of the scan (per method and side
by side). Reconstruction scores each voxel by the fraction of nonzero detection-ellipse samples
per laser position (squared geometric mean) and saves `reconstruction/`: score maps (NPY/CSV),
final images, and MP4s revealing the voxels in scan order. Outputs:
`$OUTPUT_PATH/application_1_snlos/<object>/`. The SNLOS scenes are read from
`experiments/scene/nlos-snlos/`.
