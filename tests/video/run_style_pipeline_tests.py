#!/usr/bin/env python3
"""Triple-bank ownership, DMA parity and full-frame split display checks."""
import argparse
import tempfile
from pathlib import Path

from run_style_contour_tests import ROOT, compile_tb, panels, simulate
from run_style_preprocess_tests import check_preprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--display', action='store_true', help='include full 1080p pixel checks')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='iris-pipeline-tests-') as directory:
    tmp = Path(directory)
    check_preprocess(tmp)
    exe = tmp / 'leases'
    compile_tb('tb_style_pipeline', ['tests/video/tb_style_pipeline.sv',
        'iris_ws/src/cnn/iris_style_demo.v'], exe, ['-i'])
    simulate(exe, [])
    exe = tmp / 'capture'
    compile_tb('tb_style_capture', ['tests/video/tb_style_capture.sv',
        'iris_ws/src/cnn/iris_style_capture.v', 'iris_ws/src/video/afifo_simple.v'], exe)
    simulate(exe, [])
    for bank in range(3):
        exe = tmp / f'dma-{bank}'
        compile_tb('tb_stream_cnn_dma', ['tests/video/tb_stream_cnn_dma.sv',
            'iris_ws/src/cnn/iris_stream_conv.v', 'iris_ws/src/cnn/iris_stream_cnn.v'],
            exe, [f'-Ptb_stream_cnn_dma.BANK={bank}'])
        simulate(exe, ['+DIR=' + str(ROOT / 'tests/video/fixtures/stream_d2')])
    if args.display:
        exe = tmp / 'split-third-bank'
        compile_tb('tb_style_panels', ['tests/video/tb_style_panels.sv',
            'iris_ws/src/cnn/iris_style_panels.v', 'iris_ws/src/cnn/iris_style_split_scaler.v',
            'iris_ws/src/cnn/iris_style_dequant.v', 'iris_ws/src/cnn/iris_style_ink.v'],
            exe, ['-Ptb_style_panels.FIRST_BANK=2', '-Ptb_style_panels.SECOND_BANK=0'])
        simulate(exe, [])
        panels(tmp, 1, 2, 1, first_bank=0, second_bank=2)
