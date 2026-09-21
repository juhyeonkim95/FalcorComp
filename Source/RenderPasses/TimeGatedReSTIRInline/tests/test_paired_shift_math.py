"""Independent double-precision checks of the static planar shift equations.

Run with: python Source/RenderPasses/TimeGatedReSTIRInline/tests/test_paired_shift_math.py
Requires NumPy. These verify the math, not Slang compilation or ray visibility.
"""
import unittest
import numpy as np

R = np.array([[0., -1.], [1., 0.]])


def potential(u, focus, y):
    length, gradient, hessian = 0., np.zeros(2), np.zeros((2, 2))
    for p in (focus, y):
        d = np.r_[u, 0.] - p
        r = np.linalg.norm(d)
        length += r
        gradient += d[:2] / r
        hessian += np.eye(2) / r - np.outer(d[:2], d[:2]) / r**3
    return length, gradient, hessian


def constraints(u, v, source, target, y, offset, scale):
    ls, gs, hs = potential(u, source, y)
    lt, gt, ht = potential(v, target, y)
    gauge = R @ ((scale * gs + gt) / 2)
    delta = v - u
    residual = np.array([lt - scale * ls - offset, gauge @ delta])
    du = np.vstack([-scale * gs, -gauge - .5 * scale * hs @ R @ delta])
    dv = np.vstack([gt, gauge - .5 * ht @ R @ delta])
    return residual, du, dv


def solve(u, source, target, y, offset, scale=1.):
    v = u.copy()
    for _ in range(50):
        residual, du, dv = constraints(u, v, source, target, y, offset, scale)
        if np.linalg.norm(residual) < 1e-12:
            return v, abs(np.linalg.det(du) / np.linalg.det(dv))
        step = np.linalg.solve(dv, residual)
        alpha = 1.
        for _ in range(16):
            trial = v - alpha * step
            r, _, _ = constraints(u, trial, source, target, y, offset, scale)
            if np.linalg.norm(r) < np.linalg.norm(residual):
                v = trial
                break
            alpha *= .5
        else:
            raise AssertionError('Newton line search failed')
    raise AssertionError('Newton did not converge')


class PairedShiftTests(unittest.TestCase):
    def setUp(self):
        self.source = np.array([-.3, .2, 1.])
        self.target = np.array([.2, .4, 1.])
        self.y = np.array([.9, -.6, 1.2])
        self.u = np.array([.1, .2])

    def test_previous_counterexample_round_trip(self):
        v, j = solve(self.u, self.source, self.target, self.y, .05)
        u, ji = solve(v, self.target, self.source, self.y, -.05)
        np.testing.assert_allclose(u, self.u, atol=1e-9)
        self.assertAlmostEqual(j * ji, 1., places=9)

    def test_jacobian_against_finite_differences(self):
        for scale in (1., 1.2):
            # Keep the transformed length near the original for this test.
            ls = potential(self.u, self.source, self.y)[0]
            offset = .05 + (1. - scale) * ls
            v, j = solve(self.u, self.source, self.target, self.y, offset, scale)
            for eps in (1e-4, 1e-5, 1e-6):
                columns = []
                for axis in np.eye(2):
                    plus = solve(self.u + eps * axis, self.source, self.target, self.y, offset, scale)[0]
                    minus = solve(self.u - eps * axis, self.source, self.target, self.y, offset, scale)[0]
                    columns.append((plus - minus) / (2 * eps))
                numeric = abs(np.linalg.det(np.column_stack(columns)))
                np.testing.assert_allclose(j, numeric, rtol=1e-6)
            back, ji = solve(v, self.target, self.source, self.y, -offset / scale, 1. / scale)
            np.testing.assert_allclose(back, self.u, atol=1e-9)
            self.assertAlmostEqual(j * ji, 1., places=8)

    def test_pairwise_partition_nonconstant_targets(self):
        for offset in (-.01, .01, .05):
            v, j = solve(self.u, self.source, self.target, self.y, offset)
            back, ji = solve(v, self.target, self.source, self.y, -offset)
            hs = lambda x: 1. + np.dot(x, x)
            ht = lambda x: 2. + np.exp(x[0])
            source_mass, target_mass = 11., 3. / 5.
            neighbor = source_mass * hs(self.u) / (source_mass * hs(self.u) + target_mass * ht(v) * j)
            canonical = target_mass * ht(v) / (target_mass * ht(v) + source_mass * hs(back) * ji)
            self.assertAlmostEqual(neighbor + canonical, 1., places=9)

    def test_identity(self):
        v, j = solve(self.u, self.source, self.source, self.y, 0.)
        np.testing.assert_array_equal(v, self.u)
        self.assertAlmostEqual(j, 1.)


if __name__ == '__main__':
    unittest.main()
