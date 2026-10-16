#!/usr/bin/env python3
"""Full-frame split display checks against scalar pixel/image references."""
import argparse
import tempfile
from pathlib import Path

from run_style_contour_tests import compile_tb, panels, simulate, unit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--group", choices=("all", "ink", "contour"), default="all")
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="iris-split-tests-") as directory:
    tmp = Path(directory)
    cases = ((0, 0), (1, 0), (0, 1), (1, 1)) if args.group == "all" else (
        ((0, 1), (1, 1)) if args.group == "ink" else ())
    for negative, visibility in cases:
        exe = tmp / f"split-{negative}-{visibility}"
        compile_tb("tb_style_panels", [
            "tests/video/tb_style_panels.sv",
            "iris_ws/src/cnn/iris_style_panels.v",
            "iris_ws/src/cnn/iris_style_split_scaler.v",
            "iris_ws/src/cnn/iris_style_dequant.v",
            "iris_ws/src/cnn/iris_style_ink.v",
        ], exe, [f"-Ptb_style_panels.NEGATIVE={negative}",
                 f"-Ptb_style_panels.VISIBILITY={visibility}"])
        simulate(exe, [])
    if args.group in ("all", "contour"):
        unit(tmp)
        for case in ((0, 2, 3), (0, 3, 0), (1, 2, 1)):
            panels(tmp, *case)
