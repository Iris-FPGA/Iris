#!/usr/bin/env python3
"""Compare a matched camera input/output dump with TFLite BUILTIN_REF."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import tflite_runtime
from tflite_runtime.interpreter import Interpreter, OpResolverType
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--model',type=Path,required=True)
p.add_argument('--input',type=Path,required=True)
p.add_argument('--actual',type=Path,required=True)
p.add_argument('--output',type=Path,required=True,help='report filename prefix')
a=p.parse_args()
engine=Interpreter(model_path=str(a.model),experimental_op_resolver_type=OpResolverType.BUILTIN_REF)
engine.allocate_tensors();i=engine.get_input_details()[0];o=engine.get_output_details()[0]
raw=a.input.read_bytes();actual=a.actual.read_bytes()
if i['dtype']!=np.int8 or len(raw)!=int(np.prod(i['shape'])):p.error('input tensor contract mismatch')
engine.set_tensor(i['index'],np.frombuffer(raw,dtype=np.int8).reshape(i['shape']))
engine.invoke();golden=engine.get_tensor(o['index'])
if len(actual)!=golden.size:p.error('output length mismatch')
error=np.abs(np.frombuffer(actual,dtype=np.int8).astype(np.int16)-golden.ravel().astype(np.int16))
a.output.parent.mkdir(parents=True,exist_ok=True)
Path(str(a.output)+'-golden.bin').write_bytes(golden.tobytes())
def sha(data):return hashlib.sha256(data).hexdigest()
report={'model_sha256':sha(a.model.read_bytes()),'input_sha256':sha(raw),
        'output_sha256':sha(actual),'golden_sha256':sha(golden.tobytes()),
        'runtime_version':tflite_runtime.__version__,'resolver':'BUILTIN_REF',
        'exact':bool(np.all(error==0)),'different_bytes':int(np.count_nonzero(error)),
        'max_abs_lsb':int(error.max()),'mae_lsb':float(error.mean()),
        'input_quantization':i['quantization'],'output_quantization':o['quantization'],
        'input_unique_codes':int(np.unique(np.frombuffer(raw,dtype=np.uint8)).size)}
# Diagnostic raster uses actual board output, dequantized with model metadata.
h,w=int(i['shape'][1]),int(i['shape'][2])
original=np.frombuffer(raw,dtype=np.int8).reshape(h,w,3).astype(np.int16)+128
scale,zp=o['quantization']
styled=np.clip(np.floor((np.frombuffer(actual,dtype=np.int8).reshape(h,w,3).astype(np.int16)-zp)*scale+.5),0,255).astype(np.uint8)
split=np.concatenate((original[:,:w//2].astype(np.uint8),styled[:,w//2:]),axis=1)
for label,raster in [('original',original.astype(np.uint8)),('styled',styled),('split',split)]:
    Path(str(a.output)+'-'+label+'.ppm').write_bytes(f'P6\n{w} {h}\n255\n'.encode()+raster.tobytes())
Path(str(a.output)+'-parity.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
raise SystemExit(0 if report['exact'] else 1)
