#!/usr/bin/env python3
"""Exercise the physical-key and service paths through the reconfiguration FSM."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='iris-switch-') as directory:
    exe = str(Path(directory)/'switch')
    subprocess.run(['iverilog', '-g2012', '-s', 'tb_style_switch', '-o', exe,
                    'tests/video/tb_style_switch.sv', 'iris_ws/src/iris_style_switch.v'],
                   cwd=root, check=True)
    subprocess.run(['vvp', exe], check=True)
