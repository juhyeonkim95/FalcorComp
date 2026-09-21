"""Run the actual Slang solver on the GPU, checking derivatives and failure cases.

Source the build's bin/setpath.sh and build TimeGatedReSTIRInline before running.
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
    compute = falcor.ComputePass(device, file=Path(__file__).with_name("NewtonSolverTests.cs.slang"), cs_entry="main")
    compute.globals.results = output
    compute.execute(threads_x=1)
    device.wait()
    rows = output.to_numpy().view(np.float32).reshape(8, 4)
    assert np.isfinite(rows).all(), rows
    for index, name in [(0, "constant plane"), (1, "average-gradient plane"), (6, "barycentric")]:
        jacobian, finite_difference, failures, _ = rows[index]
        assert failures == 0, (name, rows[index])
        np.testing.assert_allclose(jacobian, finite_difference, rtol=2e-3, atol=2e-4)
        print(name, "Jacobian", jacobian, "finite difference", finite_difference)
    assert rows[2, 2] == 0 and max(rows[2, :2]) <= .003374713, rows[2]
    assert rows[3, 0] != 0 and rows[3, 1] == 0, rows[3]
    assert rows[4, 0] != 0 and rows[4, 1] == 0, rows[4]
    assert rows[5, 0] == 0, rows[5]
    assert rows[7, 2] == 0 and rows[7, 0] < 1e-5, rows[7]
    np.testing.assert_allclose(rows[7, 1], 1., rtol=2e-4)
    print("Newton solver GPU regression checks passed.")


if __name__ == "__main__":
    main()
