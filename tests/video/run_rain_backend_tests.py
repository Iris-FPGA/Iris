#!/usr/bin/env python3
"""Verify every original-model Conv/Add with independent BUILTIN_REF tensors.

Run using the venv containing tflite, numpy and tflite-runtime. IVERILOG,
IVERILOG_LIB and VVP select the installed simulator. This is RTL validation,
not proof of FPGA timing or fresh HDMI throughput.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--model', type=Path, default=ROOT/'one_last_kiss_style/models/rain-princess-cropped_style_int8.tflite')
p.add_argument('--output', type=Path, required=True)
p.add_argument('--backend-only', action='store_true', help='skip core tests when only DMA/control changed')
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, str(ROOT/'.script/compile-rain-backend.py'), str(a.model), str(a.output/'fixtures'), '--fixtures'], check=True)
sources = ['iris_ws/src/cnn/'+name+'.v' for name in ('iris_stream_conv','iris_rain_conv','iris_rain_add','iris_rain_backend')]
manifest = json.loads((a.output/'fixtures/rain-backend.json').read_text())
reports = []
iv = [os.environ.get('IVERILOG', 'iverilog')]
vv = [os.environ.get('VVP', 'vvp')]
if os.environ.get('IVERILOG_LIB'):
    iv += ['-B', os.environ['IVERILOG_LIB']]
    vv += ['-M', os.environ['IVERILOG_LIB']]
with tempfile.TemporaryDirectory(prefix='iris-rain-tests-') as directory:
    tmp = Path(directory)
    for tb in (('tb_rain_backend',) if a.backend_only else ('tb_rain_conv', 'tb_rain_backend')):
        exe = tmp/tb
        subprocess.run(iv+['-g2012','-s',tb,'-o',str(exe),f'tests/video/{tb}.sv']+sources, cwd=ROOT, check=True)
        nodes = [(str(r['node']), []) for r in manifest['layers']]
        if tb=='tb_rain_backend':
            nodes += [(path.name, ['+ADD']) for path in sorted((a.output/'fixtures').glob('add-*'))]
        for node, flags in nodes:
            if tb=='tb_rain_backend' and node=='0':flags=flags+['+BACKPRESSURE']
            if tb=='tb_rain_backend' and node=='22':flags=flags+['+FAULTS']
            fixture = (a.output/'fixtures'/node).resolve()
            result = subprocess.run(vv+[str(exe), '+DIR='+str(fixture)]+flags, cwd=ROOT,
                                    capture_output=True, text=True, timeout=180)
            print(result.stdout, end='', flush=True)
            (a.output/f'{tb}-{node}.log').write_text(result.stdout+result.stderr)
            result.check_returncode()
            reports.append(dict(testbench=tb, node=node, passed=True,
                                cycles=[int(c) for c in re.findall(r'cycles=(\d+)', result.stdout)]))
report = dict(model_sha256=manifest['model_sha256'], model_changed=False,
              tests=reports, hardware_execution_verified=False)
(a.output/'rtl-results.json').write_text(json.dumps(report,indent=2)+'\n')
