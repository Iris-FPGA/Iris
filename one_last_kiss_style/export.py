#!/usr/bin/env python3
"""Fold BN and export static 640x480 INT8 candidates, with numeric evidence."""
import hashlib
import argparse
import json
from pathlib import Path
import numpy as np
import torch
import tensorflow as tf
from PIL import Image
from distill import ROOT, CANDIDATES, Student, Teacher, dataset, image

tf.config.threading.set_intra_op_parallelism_threads(4)
tf.config.threading.set_inter_op_parallelism_threads(2)
torch.set_num_threads(4)


class Folded(tf.Module):
    def __init__(self, student, rgba=False):
        super().__init__()
        self.layers = {}
        for name, layer in student.named_modules():
            if hasattr(layer, 'folded'):
                w, b = layer.folded()
                if name == 'enc.0': w = w / 255.0
                if name == 'dec.2': w, b = w * 255.0, b * 255.0
                # The fourth channel is a transport lane with zero weights.
                # RGB inference remains unchanged; four-byte pixels permit
                # direct 128-bit camera DMA without a CPU packing loop.
                if rgba and name == 'enc.0': w = np.pad(w,((0,0),(0,0),(0,1),(0,0)))
                if rgba and name == 'dec.2':
                    w = np.pad(w,((0,0),(0,0),(0,0),(0,1)))
                    b = np.pad(b,(0,1))
                self.layers[name] = (tf.constant(w), tf.constant(b), layer.stride, layer.activation)
        self.residuals = len(student.res)
        self.skip = student.skip
        self.low_decoder = student.low_decoder

    def conv(self, x, name):
        w, b, s, act = self.layers[name]
        x = tf.nn.bias_add(tf.nn.conv2d(x, w, strides=[1,s,s,1], padding='SAME'), b)
        return tf.nn.relu(x) if act else x

    @tf.function
    def __call__(self, x):
        enc=[]
        for k in range(3):
            x = self.conv(x, f'enc.{k}'); enc.append(x)
        for k in range(self.residuals): x = x + self.conv(self.conv(x, f'res.{k}.0'), f'res.{k}.1')
        for k, size in enumerate(([240,320], [480,640])):
            if self.low_decoder: x = self.conv(x, f'dec.{k}')
            x = tf.raw_ops.ResizeNearestNeighbor(images=x, size=size, align_corners=False, half_pixel_centers=False)
            if not self.low_decoder: x = self.conv(x, f'dec.{k}')
            if self.skip: x = x + enc[1-k]
        return self.conv(x, 'dec.2')


def frame(path):
    im = Image.open(path).convert('RGB')
    w,h = im.size
    if w/h > 4/3:
        nw = h*4//3; im=im.crop(((w-nw)//2,0,(w+nw)//2,h))
    else:
        nh = w*3//4; im=im.crop((0,(h-nh)//2,w,(h+nh)//2))
    return np.asarray(im.resize((640,480), Image.Resampling.BILINEAR), dtype=np.float32)[None]


def metrics(a, b):
    a,b = np.clip(a,0,255).astype(np.float64),np.clip(b,0,255).astype(np.float64)
    e = a-b
    # Report PSNR plus global channel-wise SSIM explicitly (not local SSIM).
    axis = (0,1,2)
    mu_a,mu_b=a.mean(axis),b.mean(axis)
    va,vb=a.var(axis),b.var(axis)
    cov=((a-mu_a)*(b-mu_b)).mean(axis)
    ssim=((2*mu_a*mu_b+6.5025)*(2*cov+58.5225))/((mu_a**2+mu_b**2+6.5025)*(va+vb+58.5225))
    from scipy.ndimage import gaussian_filter
    # Standard local Gaussian SSIM, 11x11 window, sigma=1.5, population covariance.
    local=[]
    for c in range(3):
        aa,bb=a[0,:,:,c],b[0,:,:,c]
        ma=gaussian_filter(aa,1.5,truncate=3.5);mb=gaussian_filter(bb,1.5,truncate=3.5)
        va=gaussian_filter(aa*aa,1.5,truncate=3.5)-ma*ma
        vb=gaussian_filter(bb*bb,1.5,truncate=3.5)-mb*mb
        cov=gaussian_filter(aa*bb,1.5,truncate=3.5)-ma*mb
        score=((2*ma*mb+6.5025)*(2*cov+58.5225))/((ma*ma+mb*mb+6.5025)*(va+vb+58.5225))
        local.append(float(score[5:-5,5:-5].mean()))
    return {'mae':float(abs(e).mean()),'psnr_255_db':float(10*np.log10(255**2/max(float((e*e).mean()),1e-15))),
            'local_gaussian_ssim':float(np.mean(local)),
            'global_channel_ssim':float(ssim.mean()),'max_abs':float(abs(e).max())}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--refined',action='store_true');p.add_argument('--candidate',choices=list(CANDIDATES))
    p.add_argument('--rgba',action='store_true',help='four-byte input/output pixels; fourth channel has zero weights')
    args=p.parse_args();suffix='_refined' if args.refined else ''
    splits=dataset(); out=ROOT/'build'
    teacher=Teacher().eval()
    report=[]
    for name,spec in CANDIDATES.items():
        if args.candidate and args.candidate!=name: continue
        student=Student(*spec).eval()
        ckpt=torch.load(out/f'{name}{suffix}.pt',map_location='cpu',weights_only=True)
        artifact=name+suffix+('_rgba' if args.rgba else '')
        student.load_state_dict(ckpt['state_dict'])
        folded=Folded(student,args.rgba)
        channels=4 if args.rgba else 3
        def transport(x):
            return np.pad(x,((0,0),(0,0),(0,0),(0,1))) if args.rgba else x
        x=frame(splits['validation'][0])
        with torch.no_grad(): raw=student(torch.from_numpy(x.transpose(0,3,1,2))).numpy().transpose(0,2,3,1)
        tf_raw=folded(tf.constant(transport(x))).numpy()[...,:3]
        error=float(np.max(abs(tf_raw-raw)))
        if error>.02: raise RuntimeError(f'BN folding parity {name}: {error}')
        signature=tf.TensorSpec([1,480,640,channels],tf.float32,name='pixels')
        converter=tf.lite.TFLiteConverter.from_concrete_functions([folded.__call__.get_concrete_function(signature)],folded)
        converter.optimizations=[tf.lite.Optimize.DEFAULT]
        def calibration():
            for f in splits['calibration']: yield [transport(frame(f))]
            # Endpoints guarantee the deployed uint8 RGB -> INT8 contract.
            yield [transport(np.zeros((1,480,640,3),np.float32))]
            yield [transport(np.full((1,480,640,3),255,np.float32))]
        converter.representative_dataset=calibration
        converter.target_spec.supported_ops=[tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        converter.inference_input_type=tf.int8; converter.inference_output_type=tf.int8
        buf=converter.convert(); (out/f'{artifact}_640_int8.tflite').write_bytes(buf)
        runtime=tf.lite.Interpreter(model_content=buf,experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF)
        runtime.allocate_tensors(); iq,oq=runtime.get_input_details()[0],runtime.get_output_details()[0]
        if iq['quantization'] != (1.0,-128): raise RuntimeError(iq)
        rows=[]
        for k,f in enumerate(splits['validation']):
            x=frame(f); runtime.set_tensor(iq['index'],(transport(x)-128).astype(np.int8));runtime.invoke()
            actual=(runtime.get_tensor(oq['index']).astype(np.float32)-oq['quantization'][1])*oq['quantization'][0]
            if args.rgba and np.max(abs(actual[...,3]))>oq['quantization'][0]/2:
                raise RuntimeError('nonzero fourth output transport channel')
            actual=actual[...,:3]
            with torch.no_grad(): ref=teacher(torch.from_numpy(x.transpose(0,3,1,2))).numpy().transpose(0,2,3,1)
            floating=folded(tf.constant(transport(x))).numpy()[...,:3]
            rows.append({'image':f.name,'teacher_vs_student_int8':metrics(ref,actual),
                         'student_float_vs_int8':metrics(floating,actual)})
            if k<3:
                tiles=np.concatenate((x[0],ref[0],actual[0]),axis=1)
                Image.fromarray(np.round(tiles).clip(0,255).astype(np.uint8)).save(out/f'{artifact}-comparison-{k}.png')
        r={'candidate':name,'training_steps':ckpt['step']+1,'model_bytes':len(buf),'sha256':hashlib.sha256(buf).hexdigest(),
           'input_shape':iq['shape'].tolist(),'output_shape':oq['shape'].tolist(),
           'input_quantization':iq['quantization'],'output_quantization':oq['quantization'],
           'bn_fold_max_abs':error,'per_image':rows,'hardware_proven':False}
        (out/f'{artifact}-evaluation.json').write_text(json.dumps(r,indent=2)+'\n');report.append(r)
        print(name, 'exported',len(buf),'bytes; mean PSNR',np.mean([r['teacher_vs_student_int8']['psnr_255_db'] for r in rows]),flush=True)
    (out/(f'candidates{suffix}'+('_rgba' if args.rgba else '')+'.json')).write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
