"""Scanning NLOS (SNLOS) geometry, independent of Falcor.

Setup (relay wall z = 0): the camera and the laser sit at O and look at C on the wall.
A hidden voxel V is probed with a fixed path length tau = |O - C| + |C - V| + tau_offset:
the laser is aimed at points on the illumination ellipse {W on wall : |O - W| + |W - V| = tau},
and a return W' -> V -> ... is time-gated at the total length 2 * tau, so a filled voxel lights
up the detection ellipse {W' on wall : |O - W'| + |W' - V| = tau} in the camera image.

Ported from experiments_tofrestir/src_snlos/ellipsoid.py (same math and scoring).
"""

from dataclasses import asdict, dataclass

import numpy as np


@dataclass(frozen=True)
class SnlosSetup:
    origin: tuple = (-1.0, 0.0, 4.0)        # O: camera and laser position
    wall_target: tuple = (0.0, 0.0, 0.0)    # C: camera look-at point on the wall z = 0
    voxel_center: tuple = (2.0, 0.0, 4.0)   # center of the square voxel plane (z = voxel_center.z)
    plane_size: float = 1.0
    grid_res: int = 25
    ellipse_samples: int = 16               # laser positions per voxel
    tau_offset: float = 0.5
    frame_height: float = 24.0              # camera film height and focal length (mm)
    focal_length: float = 24.0

    def to_dict(self):
        return asdict(self)

    @property
    def fov_degrees(self):
        return float(np.rad2deg(2.0 * np.arctan(0.5 * self.frame_height / self.focal_length)))

    def voxel_centers(self):
        """(grid_res^2, 3) voxel centers in row-major order: index = y * grid_res + x."""
        half = 0.5 * self.plane_size
        offsets = np.linspace(-half, half, self.grid_res, endpoint=False) + half / self.grid_res
        xx, yy = np.meshgrid(offsets, offsets, indexing="xy")
        center = np.asarray(self.voxel_center, dtype=np.float64)
        voxels = np.stack([center[0] + xx, center[1] + yy, np.full_like(xx, center[2])], axis=-1)
        return voxels.reshape(-1, 3)

    def render_order(self):
        """Column-wise serpentine scan (x-major), matching the prototype's render loop."""
        order = []
        for x in range(self.grid_res):
            ys = range(self.grid_res) if x % 2 == 0 else range(self.grid_res - 1, -1, -1)
            order.extend(y * self.grid_res + x for y in ys)
        return np.asarray(order, dtype=np.int64)

    def path_length(self, voxel):
        """tau: laser -> wall -> voxel length probed for this voxel (half the gated total)."""
        origin, target = np.asarray(self.origin), np.asarray(self.wall_target)
        return float(np.linalg.norm(origin - target) + np.linalg.norm(target - voxel) + self.tau_offset)


def ellipse_points_on_wall(focus_a, focus_b, path_length, n_points, wall_z=0.0, eps=1e-12):
    """Points W on the plane z = wall_z with |W - focus_a| + |W - focus_b| = path_length.

    Raises ValueError when the spheroid does not intersect the plane.
    """
    shift = np.array([0.0, 0.0, wall_z])
    a_point = np.asarray(focus_a, dtype=np.float64) - shift
    b_point = np.asarray(focus_b, dtype=np.float64) - shift
    tau = float(path_length)
    axis = b_point - a_point
    foci_distance = np.linalg.norm(axis)
    if tau < foci_distance - 1e-9:
        raise ValueError(f"path length {tau} is shorter than the focal distance {foci_distance}")
    semi_major = 0.5 * tau
    semi_minor_sq = semi_major ** 2 - (0.5 * foci_distance) ** 2
    if semi_minor_sq <= 0:
        raise ValueError("degenerate spheroid")
    midpoint = 0.5 * (a_point + b_point)
    angles = np.linspace(0.0, 2.0 * np.pi, n_points, endpoint=False)
    if foci_distance < eps:
        if abs(a_point[2]) > semi_major + 1e-9:
            raise ValueError("sphere does not intersect the wall")
        radius = np.sqrt(max(semi_major ** 2 - a_point[2] ** 2, 0.0))
        points = np.stack([a_point[0] + radius * np.cos(angles), a_point[1] + radius * np.sin(angles),
                           np.zeros_like(angles)], axis=1)
        return points + shift

    # Spheroid quadric (X - M)^T A (X - M) = 1 in the frame aligned with the foci.
    z_axis = axis / foci_distance
    helper = np.array([1.0, 0.0, 0.0]) if abs(z_axis[0]) <= 0.9 else np.array([0.0, 1.0, 0.0])
    x_axis = helper - np.dot(helper, z_axis) * z_axis
    x_axis /= np.linalg.norm(x_axis)
    y_axis = np.cross(z_axis, x_axis)
    rotation = np.stack([x_axis, y_axis, z_axis], axis=1)
    quadric = rotation @ np.diag([1 / semi_minor_sq, 1 / semi_minor_sq, 1 / semi_major ** 2]) @ rotation.T

    # Restrict to z = 0: u^T B u + 2 g^T u + k = 0 with u = (x, y).
    quad_xy, quad_xz, quad_zz = quadric[:2, :2], quadric[:2, 2], quadric[2, 2]
    center_xy, center_z = midpoint[:2], midpoint[2]
    g = -(quad_xy @ center_xy) - center_z * quad_xz
    k = center_xy @ quad_xy @ center_xy + 2 * center_z * (quad_xz @ center_xy) + center_z ** 2 * quad_zz - 1.0
    if abs(np.linalg.det(quad_xy)) < eps:
        raise ValueError("degenerate intersection conic")
    ellipse_center = -np.linalg.solve(quad_xy, g)
    k_shifted = k - g @ np.linalg.solve(quad_xy, g)
    if k_shifted >= -1e-9:
        raise ValueError("no intersection with the wall for this path length")
    eigenvalues, eigenvectors = np.linalg.eigh(quad_xy / -k_shifted)
    if np.any(eigenvalues <= eps):
        raise ValueError("invalid ellipse")
    radii = 1.0 / np.sqrt(eigenvalues)
    circle = np.stack([radii[0] * np.cos(angles), radii[1] * np.sin(angles)], axis=1)
    uv = ellipse_center[None, :] + circle @ eigenvectors.T
    points = np.column_stack([uv, np.zeros(n_points)])
    return points + shift


class PinholeCamera:
    """Pinhole projection matching the prototype (square pixels; v grows upward, so flip images)."""

    def __init__(self, origin, look_at, fov_degrees, width, height, up=(0.0, 1.0, 0.0)):
        self.origin = np.asarray(origin, dtype=np.float64)
        forward = np.asarray(look_at, dtype=np.float64) - self.origin
        self.forward = forward / np.linalg.norm(forward)
        right = np.cross(self.forward, np.asarray(up, dtype=np.float64))
        self.right = right / np.linalg.norm(right)
        self.up = np.cross(self.right, self.forward)
        self.focal = 0.5 * width / np.tan(0.5 * np.deg2rad(fov_degrees))
        self.cx, self.cy = 0.5 * (width - 1), 0.5 * (height - 1)
        self.width, self.height = width, height

    def project(self, points):
        """(N, 3) world points -> (M, 2) pixel coordinates (u, v) inside the image."""
        relative = np.asarray(points, dtype=np.float64) - self.origin
        depth = relative @ self.forward
        front = depth > 1e-12
        u = self.focal * (relative[front] @ self.right) / depth[front] + self.cx
        v = self.focal * (relative[front] @ self.up) / depth[front] + self.cy
        inside = (u >= 0) & (u < self.width) & (v >= 0) & (v < self.height)
        return np.column_stack([u[inside], v[inside]])


def camera_for(setup, width, height):
    return PinholeCamera(setup.origin, setup.wall_target, setup.fov_degrees, width, height)


def detection_ellipse_pixels(setup, camera, voxel, n_points):
    """Pixel coordinates of the detection ellipse (foci O and V, length tau) for a voxel."""
    try:
        points = ellipse_points_on_wall(setup.origin, voxel, setup.path_length(voxel), n_points)
    except ValueError:
        return np.zeros((0, 2))
    return camera.project(points)


def bilinear(image, uv):
    """Bilinear samples at (u, v); None where the 2x2 footprint leaves the image (as in the prototype)."""
    height, width = image.shape
    u, v = uv[:, 0], uv[:, 1]
    valid = (u <= width - 1) & (v <= height - 1)
    u, v = u[valid], v[valid]
    x0, y0 = np.floor(u).astype(int), np.floor(v).astype(int)
    x1, y1 = np.minimum(x0 + 1, width - 1), np.minimum(y0 + 1, height - 1)
    dx, dy = u - x0, v - y0
    values = ((1 - dx) * (1 - dy) * image[y0, x0] + dx * (1 - dy) * image[y0, x1]
              + (1 - dx) * dy * image[y1, x0] + dx * dy * image[y1, x1])
    return values, valid


def geometric_mean_score(values, eps=1e-6, power=1.0):
    values = np.clip(np.asarray(values, dtype=np.float64), eps, 1.0)
    return float(np.exp(np.mean(np.log(values))) ** power)


def voxel_score(images, ellipse_uv, band_px=3, eps=1e-8):
    """Occupancy score of one voxel from its per-laser-position images (N, H, W), flipped up-down.

    Per image: the fraction of detection-ellipse samples with nonzero radiance. The voxel score is
    their geometric mean squared (prototype: is_grid_filled_from_ellipse_images_v2, power=2).
    The SNR against a surrounding band is kept as a diagnostic only, as in the prototype.
    """
    images = np.asarray(images, dtype=np.float64)
    if len(ellipse_uv) == 0:
        return 0.0, {"per_image_pass": np.zeros(len(images)), "per_image_snr": np.zeros(len(images))}
    height, width = images.shape[1:]
    offsets = np.array([(dx, dy) for dy in range(-band_px, band_px + 1) for dx in range(-band_px, band_px + 1)
                        if (dx, dy) != (0, 0)])
    passes, snrs = [], []
    for image in images:
        values, valid = bilinear(image, ellipse_uv)
        centers = np.rint(ellipse_uv[valid]).astype(int)
        band = centers[:, None, :] + offsets[None, :, :]
        inside = (band[..., 0] >= 0) & (band[..., 0] < width) & (band[..., 1] >= 0) & (band[..., 1] < height)
        band_values = image[band[..., 1][inside], band[..., 0][inside]]
        snrs.append((values.mean() - band_values.mean()) / (band_values.std() + eps) if len(values) else 0.0)
        passes.append(np.count_nonzero(values > 0.0) / len(values) if len(values) else 0.0)
    passes = np.asarray(passes)
    return geometric_mean_score(passes, power=2.0), {"per_image_pass": passes, "per_image_snr": np.asarray(snrs)}


def tone_map_display(image, scale=100.0, limit=1.5):
    """Prototype display mapping for a single-channel render: scale, luminance Reinhard, gamma 2.2."""
    value = np.maximum(image * scale, 0.0)
    return np.clip((value / (1.0 + value / limit)) ** (1.0 / 2.2), 0.0, 1.0)


def paint_points(gray, uv, radius=1, color=(1.0, 0.0, 0.0)):
    """Gray (H, W) in [0, 1] -> RGB with colored dots at pixel coordinates."""
    rgb = np.repeat(gray[..., None], 3, axis=-1)
    height, width = gray.shape
    for u, v in np.rint(uv).astype(int):
        y0, y1 = max(v - radius, 0), min(v + radius + 1, height)
        x0, x1 = max(u - radius, 0), min(u + radius + 1, width)
        if y0 < y1 and x0 < x1:
            rgb[y0:y1, x0:x1] = color
    return rgb
