"""Scene configuration independent of Falcor and of any particular experiment."""

from dataclasses import asdict, dataclass
import hashlib
import json
import math
from pathlib import Path


@dataclass
class SceneConfig:
    name: str
    scene_file: str
    resolution: list[int]
    gate_center: float
    gate_width: float
    light_position: list[float]
    light_direction: list[float]
    light_power: list[float]
    light_angle_degrees: float = 0.0
    is_laser: bool = True
    max_bounces: int = 6
    shiftmap_method: str = "local_tangent"

    def validate(self):
        if self.shiftmap_method not in ("no", "local_tangent", "barycentric", "ray_trace", "area_adaptive", "ray_trace_chart"):
            raise ValueError("Unknown shiftmapMethod; use no, local_tangent, barycentric, ray_trace, area_adaptive, or ray_trace_chart")
        if not Path(self.scene_file).is_file():
            raise ValueError(f"Scene not found: {self.scene_file}")
        if len(self.resolution) != 2 or any(type(v) is not int or v <= 0 for v in self.resolution):
            raise ValueError("resolution must contain positive integer width and height")
        for name in ("gate_center", "gate_width"):
            if not math.isfinite(getattr(self, name)) or getattr(self, name) <= 0:
                raise ValueError(f"{name} must be finite and positive")
        for name in ("light_position", "light_direction", "light_power"):
            vector = getattr(self, name)
            if len(vector) != 3 or not all(math.isfinite(v) for v in vector):
                raise ValueError(f"{name} must contain three finite values")
        norm = math.sqrt(sum(v * v for v in self.light_direction))
        if norm == 0:
            raise ValueError("light_direction must not be zero")
        self.light_direction = [v / norm for v in self.light_direction]
        if min(self.light_power) < 0 or max(self.light_power) <= 0:
            raise ValueError("light_power must be nonnegative and not all zero")
        if not math.isfinite(self.light_angle_degrees) or not 0 <= self.light_angle_degrees < 90:
            raise ValueError("light_angle_degrees must be in [0, 90)")
        if type(self.is_laser) is not bool:
            raise ValueError("is_laser must be true or false")
        if type(self.max_bounces) is not int or self.max_bounces < 2:
            raise ValueError("max_bounces must be at least 2; primary direct lighting is excluded")

    def reference_signature(self):
        """Compare physical settings and the scene entry file, independent of checkout path."""
        signature = asdict(self)
        signature.pop("name")
        signature.pop("scene_file")
        signature.pop("shiftmap_method")  # Reuse settings do not change the direct PT reference.
        signature["scene_sha256"] = hashlib.sha256(Path(self.scene_file).read_bytes()).hexdigest()
        return signature


def load_scene_config(path, resolution=None, *, gate_width):
    """Resolve scene settings with the experiment's explicitly supplied gate width."""
    path = Path(path).resolve()
    values = json.loads(path.read_text())
    values["shiftmap_method"] = values.pop("shiftmapMethod", "local_tangent")
    values["gate_width"] = gate_width
    values["scene_file"] = str((path.parent / values["scene_file"]).resolve())
    if resolution is not None:
        values["resolution"] = list(resolution)
    scene = SceneConfig(**values)
    scene.validate()
    return scene
