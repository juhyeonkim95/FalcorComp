# FalcorComp

<p align="center">
  <img src="assets/logo.png" alt="FalcorComp Logo" width="320">
</p>

<p align="center">
<b>Computational Imaging Renderers Built on <a href="https://github.com/NVIDIAGameWorks/Falcor">Falcor</a></b>
</p>


## Overview

FalcorComp is a collection of rendering algorithms for computational imaging built on top of <a href="https://github.com/NVIDIAGameWorks/Falcor">NVIDIA Falcor</a> renderer.

Rather than serving as a general-purpose rendering framework, this repository provides implementations of specialized Monte Carlo renderers developed for computational imaging research. The current focus is on active sensing modalities such as Time-of-Flight, event cameras, and structured light.


## Implemented Renderers

FalcorComp currently includes implementations of the following renderers:

- **"ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling"**  
  **SIGGRAPH 2026 (ACM TOG)**  
  [[Project Page]](https://juhyeonkim95.github.io/project-pages/tof_restir/) | [[README]](README-ToFReSTIR.md)

- **"Difference-aware Filtering for Event Camera Simulation"**  
  **EGSR 2026 (Computer Graphics Forum)**  
  [[Project Page]](https://juhyeonkim95.github.io/project-pages/event_svgf/) | README (TBD)

- **"Geometric Antithetic Sampling for Spatiotemporally Modulated Light"**  
  Project Page (TBD) | README (TBD)

For implementation details, usage instructions, and examples, please refer to the corresponding project page or README for each renderer.

## Compilation

Please refer to the original Falcor repository ([link](https://github.com/nvidiagameworks/falcor)) for build instructions. We have tested the code working on **Ubuntu 22.04.5 LTS**.


## Acknowledgments

FalcorComp is built upon the open-source rendering framework <a href="https://github.com/NVIDIAGameWorks/Falcor">NVIDIA Falcor</a>. We thank the NVIDIA Research team and Falcor contributors for making their rendering infrastructure publicly available.



## Citation

If you find FalcorComp useful in your research, please consider citing the corresponding paper(s):

```bibtex
% ToF ReSTIR
@article{kim2026tof,
  title={ToF ReSTIR: Time-of-Flight Rendering with Spatio-temporal Reservoir Resampling},
  author={Kim, Juhyeon and Jarosz, Wojciech and Pediredla, Adithya},
  journal={ACM Transactions on Graphics (TOG)},
  volume={45},
  number={4},
  pages={1--18},
  year={2026},
  publisher={ACM New York, NY, USA}
}

% Difference-aware Filtering for Event Camera Simulation
@inproceedings{kim2026difference,
  title={Difference-aware Filtering for Event Camera Simulation},
  author={Kim, Juhyeon and Jarosz, Wojciech and Pediredla, Adithya},
  booktitle={Computer graphics forum},
  volume={45},
  number={4},
  year={2026},
  organization={Eurographics/John Wiley \& Sons}
}

% Geometric Antithetic Sampling for Spatiotemporally Modulated Light
(TBD)
```
