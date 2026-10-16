#!/usr/bin/env python3
"""Sensor exposure encoding and closed-loop low-noise gain recovery."""
import tempfile
from pathlib import Path
from run_style_contour_tests import compile_tb,simulate

with tempfile.TemporaryDirectory(prefix='iris-camera-ae-') as directory:
    for top in ('tb_ae_exposure','tb_ae_gain_recovery'):
        exe=Path(directory)/top
        compile_tb(top,[f'tests/video/{top}.sv','iris_ws/src/mipi/ae_ctrl.v'],exe)
        simulate(exe, [])
