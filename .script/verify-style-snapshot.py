#!/usr/bin/env python3
"""Independent TensorFlow BUILTIN_REF check of a frozen displayed camera pair."""
import argparse,hashlib,json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw
import tensorflow as tf
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('prefix',type=Path)
p.add_argument('--model',type=Path,default=root/'one_last_kiss_style/models/c448_lowdec_skip_r0_refined_rgba_640_int8.tflite')
a=p.parse_args();prefix=str(a.prefix)
report=json.loads(Path(prefix+'-report.json').read_text())
source=Path(prefix+'-input.bin').read_bytes();actual=Path(prefix+'-output.bin').read_bytes()
assert len(source)==len(actual)==1228800
for key,raw in [('input',source),('output',actual)]:
 assert hashlib.sha256(raw).hexdigest()==report['snapshot_files'][key]['sha256']
x=np.frombuffer(source,np.int8).reshape(1,480,640,4)
assert np.all(x[:,:,:,3]==-128),'dummy input channel changed'
engine=tf.lite.Interpreter(model_path=str(a.model),experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF)
engine.allocate_tensors();i=engine.get_input_details()[0];o=engine.get_output_details()[0]
assert tuple(i['shape'])==(1,480,640,4) and i['quantization']==(1.,-128)
engine.set_tensor(i['index'],x);engine.invoke();golden=engine.get_tensor(o['index'])
y=np.frombuffer(actual,np.int8).reshape(golden.shape)
err=np.abs(y.astype(np.int16)-golden.astype(np.int16))
result={'scope':'one captured input and its frozen displayed output; student model only',
 'tensorflow_version':tf.__version__,'resolver':'BUILTIN_REF','model_sha256':hashlib.sha256(a.model.read_bytes()).hexdigest(),
 'displayed_count':report['snapshot_displayed_count'],'pair':report['snapshot_pair'],
 'input_sha256':hashlib.sha256(source).hexdigest(),'output_sha256':hashlib.sha256(actual).hexdigest(),
 'reference_sha256':hashlib.sha256(golden.tobytes()).hexdigest(),
 'exact':bool(np.array_equal(y,golden)),'different_bytes':int(np.count_nonzero(err)),
 'max_abs_lsb':int(err.max()),'mae_lsb':float(err.mean()),
 'input_rgb_std':float(x[0,:,:,:3].astype(np.float32).std())}
Path(prefix+'-reference.bin').write_bytes(golden.tobytes())
Path(prefix+'-parity.json').write_text(json.dumps(result,indent=2)+'\n')
left=(x[0,:,:,:3].astype(np.int16)+128).astype(np.uint8)
right=np.clip(np.floor((y[0,:,:,:3].astype(np.float64)-o['quantization'][1])*o['quantization'][0]+.5),0,255).astype(np.uint8)
canvas=Image.new('RGB',(1280,510),(20,20,20));canvas.paste(Image.fromarray(left),(0,30));canvas.paste(Image.fromarray(right),(640,30))
draw=ImageDraw.Draw(canvas);draw.text((12,8),'FPGA captured input (same frame)',fill='white');draw.text((652,8),'FPGA neural style output',fill='white')
canvas.save(prefix+'-comparison.png')
print(json.dumps(result,indent=2))
raise SystemExit(0 if result['exact'] else 1)
