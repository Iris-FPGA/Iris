#!/usr/bin/env python3
"""Generate the static firmware fixture and its TFLite integer reference."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import tflite_runtime
from tflite_runtime.interpreter import Interpreter, OpResolverType

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--model', type=Path, required=True)
p.add_argument('--output', type=Path, required=True, help='output filename prefix')
a = p.parse_args()
engine = Interpreter(model_path=str(a.model),
                     experimental_op_resolver_type=OpResolverType.BUILTIN_REF)
engine.allocate_tensors()
i, o = engine.get_input_details()[0], engine.get_output_details()[0]
batch, height, width, channels = map(int, i['shape'])
if batch != 1 or channels not in (3, 4) or i['dtype'] != np.int8 or i['quantization'] != (1., -128):
    p.error('expected batch-one RGB/RGBA INT8 input with scale 1 and zero point -128')
y, x = np.indices((height, width))
pixels = np.full((1, height, width, channels), -128, dtype=np.int8)
pixels[0, :, :, 0] = (256 * x // width - 128).astype(np.int8)
pixels[0, :, :, 1] = (256 * y // height - 128).astype(np.int8)
pixels[0, :, :, 2] = np.where(((x // 16) ^ (y // 16)) & 1, 127, -128).astype(np.int8)
engine.set_tensor(i['index'], pixels)
engine.invoke()
reference = engine.get_tensor(o['index'])
prefix = str(a.output)
a.output.parent.mkdir(parents=True, exist_ok=True)
files = {}
for label, tensor in [('input', pixels), ('golden', reference)]:
    raw = tensor.tobytes()
    path = Path(prefix + '-' + label + '.bin')
    path.write_bytes(raw)
    files[label] = {'path': str(path), 'bytes': len(raw),
                    'sha256': hashlib.sha256(raw).hexdigest()}
fnv = 0x811c9dc5
for value in reference.tobytes():
    fnv = ((fnv ^ value) * 0x01000193) & 0xffffffff
report = {'scope': 'software reference for the deterministic static firmware fixture',
          'runtime': 'tflite-runtime', 'runtime_version': tflite_runtime.__version__,
          'resolver': 'BUILTIN_REF',
          'model_sha256': hashlib.sha256(a.model.read_bytes()).hexdigest(),
          'input_shape': i['shape'].tolist(), 'output_shape': o['shape'].tolist(),
          'input_quantization': i['quantization'], 'output_quantization': o['quantization'],
          'output_fnv1a': f'{fnv:08x}', 'files': files,
          'hardware_execution_verified': False}
Path(prefix + '-reference.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
