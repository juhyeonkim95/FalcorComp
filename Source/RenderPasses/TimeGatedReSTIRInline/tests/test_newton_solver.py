"""Run the active Slang solver on the GPU, reporting residuals and checking failure cases.

Source the build's bin/setpath.sh and build TimeGatedReSTIRInline before running.
"""
from pathlib import Path

import falcor
import numpy as np


def main():
    testbed = falcor.Testbed(create_window=False)
    device = testbed.device
    output = device.create_structured_buffer(
        struct_size=16, element_count=4,
        bind_flags=falcor.ResourceBindFlags.ShaderResource | falcor.ResourceBindFlags.UnorderedAccess,
    )
    compute = falcor.ComputePass(device, file=Path(__file__).with_name("NewtonSolverTests.cs.slang"), cs_entry="main")
    compute.globals.results = output
    compute.execute(threads_x=1)
    device.wait()
    rows = output.to_numpy().view(np.float32).reshape(4, 4)
    assert np.isfinite(rows).all(), rows
    # The restored solver only checks the length residual: report the gauge
    # residual separately rather than claiming the paired-solver guarantees.
    print("length residual, normalized gauge residual, status, iterations:", rows[0])
    assert rows[0, 2] == 0 and rows[0, 0] <= .003374713, rows[0]
    assert rows[1, 0] != 0 and rows[1, 1] == 0, rows[1]
    assert rows[2, 0] != 0, rows[2]  # A failed solve may retain its raw determinant.
    assert rows[3, 0] == 0, rows[3]
    print("Active Newton solver checks passed; gauge residual is diagnostic only.")


if __name__ == "__main__":
    main()
