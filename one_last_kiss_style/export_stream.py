#!/usr/bin/env python3
"""Export and evaluate independently held-out, shallow RGBA INT8 CNNs."""
import argparse
import hashlib
import json
import numpy as np
import torch
import tensorflow as tf
from PIL import Image
from distill import ROOT, MODEL, Teacher, dataset
from stream_student import CANDIDATES, StreamStudent, frame
from export import metrics

tf.config.threading.set_intra_op_parallelism_threads(4)
tf.config.threading.set_inter_op_parallelism_threads(2)
torch.set_num_threads(4)

class FoldedStream(tf.Module):
    def __init__(self, student):
        super().__init__()
        self.layers = []
        for i, layer in enumerate(student.layers):
            w, b = layer.folded()
            if i == 0:
                w = np.pad(w/255.0,((0,0),(0,0),(0,1),(0,0)))
            if i == 2:
                w = np.pad(w*255.0,((0,0),(0,0),(0,0),(0,1)))
                b = np.pad(b*255.0,(0,1))
            self.layers.append((tf.constant(w),tf.constant(b),layer.stride,layer.dilation))

    @tf.function
    def __call__(self, x):
        for w,b,s,d in self.layers:
            x = tf.nn.bias_add(tf.nn.conv2d(x,w,strides=[1,s,s,1],padding='SAME',dilations=[1,d,d,1]),b)
            x = tf.nn.relu(x)
        return tf.raw_ops.ResizeNearestNeighbor(images=x,size=[480,640],align_corners=False,half_pixel_centers=False)

def transport(x):
    return np.pad(x,((0,0),(0,0),(0,0),(0,1)))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate',choices=list(CANDIDATES))
    a=p.parse_args()
    out=ROOT/'build/stream';splits=dataset();teacher=Teacher().eval()
    reports=[]
    for name,d in CANDIDATES.items():
        if a.candidate and a.candidate!=name:continue
        ckpt=torch.load(out/(name+'.pt'),map_location='cpu',weights_only=True)
        if ckpt['teacher_sha256']!=hashlib.sha256(MODEL.read_bytes()).hexdigest():raise RuntimeError('teacher changed')
        student=StreamStudent(d).eval();student.load_state_dict(ckpt['state_dict'])
        folded=FoldedStream(student)
        xx=frame(splits['validation'][0])[None]
        x=xx.numpy().transpose(0,2,3,1)
        with torch.no_grad():raw=student(xx).clamp(min=0).numpy().transpose(0,2,3,1)
        floating=folded(tf.constant(transport(x))).numpy()[...,:3]
        fold_error=float(abs(raw-floating).max())
        if fold_error>.02:raise RuntimeError(('fold mismatch',fold_error))
        spec=tf.TensorSpec([1,480,640,4],tf.float32,name='pixels')
        cv=tf.lite.TFLiteConverter.from_concrete_functions([folded.__call__.get_concrete_function(spec)],folded)
        cv.optimizations=[tf.lite.Optimize.DEFAULT]
        def calibrate():
            for f in splits['calibration']:
                yield [transport(frame(f)[None].numpy().transpose(0,2,3,1))]
            yield [np.zeros((1,480,640,4),np.float32)]
            yield [transport(np.full((1,480,640,3),255,np.float32))]
        cv.representative_dataset=calibrate
        cv.target_spec.supported_ops=[tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        cv.inference_input_type=tf.int8;cv.inference_output_type=tf.int8
        buf=cv.convert();model_path=out/(name+'_rgba_640_int8.tflite');model_path.write_bytes(buf)
        rt=tf.lite.Interpreter(model_content=buf,experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF)
        rt.allocate_tensors();iq,oq=rt.get_input_details()[0],rt.get_output_details()[0]
        if iq['quantization']!=(1.,-128) or oq['quantization'][1]!=-128:raise RuntimeError('transport quantizer differs')
        rows=[]
        for k,f in enumerate(splits['validation']):
            xx=frame(f)[None];x=xx.numpy().transpose(0,2,3,1)
            rt.set_tensor(iq['index'],(transport(x)-128).astype(np.int8));rt.invoke()
            actual=(rt.get_tensor(oq['index']).astype(np.float32)+128)*oq['quantization'][0]
            if np.any(actual[...,3]!=0):raise RuntimeError('dummy channel not zero')
            actual=actual[...,:3]
            with torch.no_grad():reference=teacher(xx).numpy().transpose(0,2,3,1)
            fl=folded(tf.constant(transport(x))).numpy()[...,:3]
            rows.append({'image':f.name,'teacher_vs_int8':metrics(reference,actual),'float_vs_int8':metrics(fl,actual)})
            if k<3:
                tiles=np.concatenate((x[0],reference[0],actual[0]),axis=1)
                Image.fromarray(np.round(tiles).clip(0,255).astype(np.uint8)).save(out/(name+f'-comparison-{k}.png'))
        report={'candidate':name,'steps':ckpt['step']+1,'model_sha256':hashlib.sha256(buf).hexdigest(),'model_bytes':len(buf),
                'model_path':str(model_path),'checkpoint_sha256':hashlib.sha256((out/(name+'.pt')).read_bytes()).hexdigest(),
                'teacher_sha256':ckpt['teacher_sha256'],'data_manifest_sha256':ckpt['data_manifest_sha256'],
                'bn_fold_max_abs':fold_error,'input_quantization':iq['quantization'],'output_quantization':oq['quantization'],
                'mean_psnr_db':float(np.mean([r['teacher_vs_int8']['psnr_255_db'] for r in rows])),
                'mean_local_ssim':float(np.mean([r['teacher_vs_int8']['local_gaussian_ssim'] for r in rows])),
                'per_image':rows,'hardware_proven':False}
        (out/(name+'-evaluation.json')).write_text(json.dumps(report,indent=2)+'\n');reports.append(report)
        print(name,report['mean_psnr_db'],report['mean_local_ssim'],flush=True)
    (out/'evaluations.json').write_text(json.dumps(reports,indent=2)+'\n')

if __name__=='__main__':main()
