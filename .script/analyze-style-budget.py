#!/usr/bin/env python3
"""Offline architecture screening, not a measured FPGA throughput result.

Run with .venv-style/bin/python. Layer traffic assumes each activation is read
once; a real implementation must establish reuse and quantify AXI stalls.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import tflite

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('model', type=Path)
p.add_argument('--fps', type=float, default=15)
p.add_argument('--clock-hz', type=int, default=100_000_000)
p.add_argument('--mac-lanes', type=int, default=16)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if a.fps <= 0 or a.clock_hz <= 0 or a.mac_lanes <= 0:
    p.error('fps, clock and lanes must be positive')
b = a.model.read_bytes()
m = tflite.Model.GetRootAsModel(b, 0)
g = m.Subgraphs(0)
rows = []
names = {v: k for k, v in vars(tflite.BuiltinOperator).items()
         if isinstance(v, int)}
sizes = {tflite.TensorType.INT8: 1, tflite.TensorType.INT32: 4}

def shape(index):
    return list(map(int, g.Tensors(index).ShapeAsNumpy()))

def elements(index):
    return math.prod(shape(index))

def byte_count(index):
    ty = g.Tensors(index).Type()
    if ty not in sizes:
        raise ValueError('Budget requires INT8/INT32 tensors')
    return elements(index) * sizes[ty]

for i in range(g.OperatorsLength()):
    op = g.Operators(i)
    kind = m.OperatorCodes(op.OpcodeIndex()).BuiltinCode()
    ins = list(map(int, op.InputsAsNumpy()))
    outs = list(map(int, op.OutputsAsNumpy()))
    activation_ins = [x for x in ins if m.Buffers(g.Tensors(x).Buffer()).DataLength() == 0]
    row = {'node': i, 'kind': names.get(kind, str(kind)),
           'input_shapes': [shape(x) for x in ins],
           'output_shapes': [shape(x) for x in outs],
           'activation_bytes_once_per_layer': sum(byte_count(x) for x in activation_ins + outs)}
    if kind == tflite.BuiltinOperator.CONV_2D:
        row['macs'] = elements(outs[0]) * math.prod(shape(ins[1])[1:])
        opts = tflite.Conv2DOptions()
        opts.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
        row['stride'] = [opts.StrideH(), opts.StrideW()]
        # This is only the logical storage minimum for the input window.
        row['minimum_input_line_bytes'] = ((shape(ins[1])[1] - 1) *
                                           shape(ins[0])[2] * shape(ins[0])[3])
    elif kind == tflite.BuiltinOperator.DEPTHWISE_CONV_2D:
        row['macs'] = elements(outs[0]) * math.prod(shape(ins[1])[1:3])
    elif kind not in (tflite.BuiltinOperator.ADD,
                      tflite.BuiltinOperator.RESIZE_NEAREST_NEIGHBOR):
        raise ValueError('Unsupported budget operator: ' + row['kind'])
    rows.append(row)

macs = sum(r.get('macs', 0) for r in rows)
traffic = sum(r['activation_bytes_once_per_layer'] for r in rows)
ideal_cycles = macs / a.mac_lanes
budget = a.clock_hz / a.fps
report = {'model_sha256': hashlib.sha256(b).hexdigest(), 'model_bytes': len(b),
          'clock_hz': a.clock_hz, 'target_fps': a.fps, 'mac_lanes': a.mac_lanes,
          'macs_per_frame': macs, 'target_cycles_per_frame': budget,
          'ideal_compute_cycles_per_frame': ideal_cycles,
          'ideal_compute_ms': ideal_cycles / a.clock_hz * 1000,
          'cycles_remaining_for_all_overhead': budget - ideal_cycles,
          'activation_bytes_once_per_layer_per_frame': traffic,
          'activation_MB_per_second_at_target': traffic * a.fps / 1e6,
          'rows': rows,
          'hardware_throughput_verified': False,
          'limits': ['MAC roofline excludes lane underutilization, quantization, padding and stalls.',
                     'Traffic excludes weights, capture/display, input/output copies and AXI inefficiency.',
                     'Line storage excludes banking, skips, FIFOs and frame-boundary handling.',
                     'Quality and measured stable fresh-frame throughput require separate validation.']}
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
