"""GPU finite-difference checks for the Cartesian chart's derivatives and area measure.

Build TimeGatedReSTIRInline and source bin/setpath.sh before running.
"""
from pathlib import Path

import falcor
import numpy as np


def main():
    testbed = falcor.Testbed(create_window=False)
    device = testbed.device
    output = device.create_structured_buffer(
        struct_size=16, element_count=8,
        bind_flags=falcor.ResourceBindFlags.ShaderResource | falcor.ResourceBindFlags.UnorderedAccess,
    )
    compute = falcor.ComputePass(device, file=Path(__file__).with_name("CartesianRayChartTests.cs.slang"), cs_entry="main")
    compute.globals.results = output
    compute.execute(threads_x=4)
    device.wait()
    rows = output.to_numpy().view(np.float32).reshape(4, 2, 4)
    assert np.isfinite(rows).all(), rows
    assert np.all(rows[:, 0, :3] < 2e-4), rows
    assert np.all(rows[:, 0, 3] == 1), rows
    assert np.all(rows[:, 1, 2] < 1e-6), rows
    assert np.all(rows[:, 1, 3] == 0), rows
    np.testing.assert_allclose(rows[:, 1, 0], rows[:, 1, 1], rtol=2e-3)
    print("Cartesian chart GPU checks passed: center/pole, derivatives, solid angle, surface area, horizon rejection.")


if __name__ == "__main__":
    main()
