"""Deterministic camera trajectory shared by image export, timing, and GT."""

import numpy as np

from common.paths import RELEASE_OUTPUT_PATH


def make_camera_motion(camera, speed, direction=None):
    def vector(value):
        return [float(value.x), float(value.y), float(value.z)]
    position, target = vector(camera.position), vector(camera.target)
    direction = np.asarray(direction if direction is not None else np.subtract(target, position), dtype=float)
    length = np.linalg.norm(direction)
    if direction.shape != (3,) or not np.isfinite(direction).all() or not np.isfinite(length) or length <= 0:
        raise ValueError("Camera movement direction must be a finite nonzero 3D vector")
    if not np.isfinite(speed) or speed < 0:
        raise ValueError("Camera speed must be finite and nonnegative")
    return {"position": position, "target": target,
            "velocity": (speed * (direction / length)).tolist()}


def camera_velocity(motion):
    if "velocity" in motion:
        return np.asarray(motion["velocity"], dtype=float)
    # Existing imported GT records used an unnormalized forward multiplier.
    return motion["forward_step"] * np.subtract(motion["target"], motion["position"])


def camera_motions_match(a, b):
    if a is None or b is None:
        return a is None and b is None
    # Camera properties are float32; ignore only floating-point representation noise.
    return (np.allclose(a["position"], b["position"], rtol=0, atol=1e-6)
            and np.allclose(a["target"], b["target"], rtol=0, atol=1e-6)
            and np.allclose(camera_velocity(a), camera_velocity(b), rtol=1e-6, atol=1e-9))


def sequence_configs_match(a, b):
    a, b = dict(a), dict(b)
    motion_a, motion_b = a.pop("camera_motion", None), b.pop("camera_motion", None)
    return a == b and camera_motions_match(motion_a, motion_b)


def camera_pose(motion, frame):
    position = np.asarray(motion["position"], dtype=float)
    target = np.asarray(motion["target"], dtype=float)
    offset = frame * camera_velocity(motion)
    return (position + offset).tolist(), (target + offset).tolist()


def apply_camera_motion(testbed, motion, frame, graph=None, follow_light=True):
    if motion is None:
        return
    position, target = camera_pose(motion, frame)
    testbed.scene.camera.position = position
    testbed.scene.camera.target = target
    if graph is not None and follow_light:
        direction = np.asarray(target) - position
        direction /= np.linalg.norm(direction)
        graph.get_pass("Laser").update_laser_info(position, direction.tolist())


def sequence_reference_path(scene, camera_motion=None, laser_motion=None):
    folder = "reference_sequence"
    return RELEASE_OUTPUT_PATH / folder / scene.name / f"{scene.gate_width:.4f}"


def validate_sequence_motion(manifest, reference):
    if manifest.get("laser_motion") != reference.get("laser_motion"):
        raise ValueError("Sequence laser trajectories do not match")
    if not camera_motions_match(manifest.get("camera_motion"), reference.get("camera_motion")):
        raise ValueError("Sequence camera trajectories do not match")


def make_laser_motion(scene):
    return {"position": list(scene.light_position), "direction": list(scene.light_direction),
            "velocity": list(scene.laser_velocity), "start_frame": scene.laser_motion_start_frame}


def laser_position(motion, frame):
    return (np.asarray(motion["position"]) + max(0, frame - motion["start_frame"]) *
            np.asarray(motion["velocity"])).tolist()


def apply_sequence_motion(testbed, args, frame, graph=None):
    apply_camera_motion(testbed, getattr(args, "camera_motion", None), frame, graph,
                        follow_light=getattr(args, "light_collocated", True))
    motion = getattr(args, "laser_motion", None)
    if motion is not None and graph is not None:
        graph.get_pass("Laser").update_laser_info(laser_position(motion, frame), motion["direction"])


def configure_sequence_motion(scene, camera, args):
    """Infer motion from scene settings; gate animation is independent of transport."""
    args.light_collocated = scene.light_collocated
    args.camera_motion = (make_camera_motion(camera, scene.camera_speed, scene.camera_direction)
                          if scene.camera_speed > 0 else None)
    moving_light = scene.laser_velocity is not None and any(v != 0 for v in scene.laser_velocity)
    if moving_light and scene.light_collocated:
        raise ValueError("Independent light motion requires light_collocated=false")
    args.laser_motion = make_laser_motion(scene) if moving_light else None


def sequence_light_is_dynamic(scene, args):
    camera = getattr(args, "camera_motion", None)
    light = getattr(args, "laser_motion", None)
    return bool((scene.light_collocated and camera is not None and np.any(camera_velocity(camera)))
                or (light is not None and np.any(light["velocity"])))
