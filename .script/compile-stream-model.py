#!/usr/bin/env python3
"""Validate a three-Conv C4 graph; emit CI parameters and independent oracles.

The software reference uses integer convolution and gemmlowp double-rounding.
Compare every native layer with TF BUILTIN_REF before accepting parameters.
"""
import argparse,hashlib,json,math
from pathlib import Path
import numpy as np
import tflite

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('model',type=Path);p.add_argument('output',type=Path)
p.add_argument('--input',type=Path)
p.add_argument('--width',type=int,default=16);p.add_argument('--height',type=int,default=12)
p.add_argument('--verify-tflite',action='store_true')
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
blob=a.model.read_bytes();m=tflite.Model.GetRootAsModel(blob,0);g=m.Subgraphs(0)
layers=[]
for index in range(3):
    op=g.Operators(index)
    if m.OperatorCodes(op.OpcodeIndex()).BuiltinCode()!=tflite.BuiltinOperator.CONV_2D:raise ValueError('expected three Convs')
    ids=list(map(int,op.InputsAsNumpy()));out=int(op.Outputs(0))
    ti,tw,tb,to=[g.Tensors(j) for j in ids+[out]]
    ws=list(map(int,tw.ShapeAsNumpy()))
    if ws[0]!=4 or ws[-1]!=4 or ws[1]!=ws[2] or ws[1] not in (1,3):raise ValueError('unsupported shape')
    w=np.frombuffer(m.Buffers(tw.Buffer()).DataAsNumpy().tobytes(),np.int8).reshape(ws)
    bias=np.frombuffer(m.Buffers(tb.Buffer()).DataAsNumpy().tobytes(),np.int32).copy()
    qi,qw,qo=ti.Quantization(),tw.Quantization(),to.Quantization()
    if np.any(qw.ZeroPointAsNumpy()!=0) or qw.ScaleLength()!=4:raise ValueError('weight quantization')
    opts=tflite.Conv2DOptions();opts.Init(op.BuiltinOptions().Bytes,op.BuiltinOptions().Pos)
    if opts.Padding()!=tflite.Padding.SAME or opts.StrideW()!=opts.StrideH() or opts.DilationWFactor()!=opts.DilationHFactor():raise ValueError('unsupported convolution')
    if opts.FusedActivationFunction()!=tflite.ActivationFunctionType.RELU:raise ValueError('expected fused ReLU')
    mult=[];shifts=[]
    for oc in range(4):
        sig,exp=math.frexp(float(qi.Scale(0))*float(qw.Scale(oc))/float(qo.Scale(0)))
        fixed=int(math.floor(sig*(1<<31)+.5))
        if fixed==(1<<31):fixed//=2;exp+=1
        # Match TFLite QuantizeMultiplier: tiny scales flush to zero.
        if exp < -31: fixed,exp=0,0
        if not (-31<=exp<=0):raise ValueError('hardware contract requires nonpositive quantized shift')
        mult.append(fixed);shifts.append(exp)
    params=[]
    # One tap contains out-channel-major, input-channel-minor signed bytes.
    taps=np.zeros((9,4,4),np.int8)
    for ky in range(ws[1]):
        for kx in range(ws[2]):taps[ky*ws[2]+kx]=w[:,ky,kx,:]
    for tap in taps:
        raw=tap.tobytes()
        params.extend(int.from_bytes(raw[j:j+4],'little') for j in range(0,16,4))
    iz,oz=int(qi.ZeroPoint(0)),int(qo.ZeroPoint(0))
    params.extend([int(x)&0xffffffff for x in bias]+mult+[int(x)&0xffffffff for x in shifts]+[iz&0xff,oz&0xff,oz&0xff,127])
    layers.append({'node':index,'tensor_in':ids[0],'tensor_out':out,'weights':w,'bias':bias,'multiplier':np.array(mult,np.int64),
                   'shift':np.array(shifts,np.int64),'kernel':ws[1],'stride':opts.StrideH(),'dilation':opts.DilationHFactor(),
                   'input_zero':iz,'output_zero':oz,'output_scale':float(qo.Scale(0)),'parameters':params})
last=g.Operators(3)
if g.OperatorsLength()!=4 or m.OperatorCodes(last.OpcodeIndex()).BuiltinCode()!=tflite.BuiltinOperator.RESIZE_NEAREST_NEIGHBOR:raise ValueError('expected final NN2x')
if [r['stride'] for r in layers]!=[2,1,1] or [r['kernel'] for r in layers]!=[3,3,1]:raise ValueError('unexpected pipeline')
if layers[0]['dilation']!=1 or layers[2]['dilation']!=1 or layers[1]['dilation'] not in (1,2,4):raise ValueError('unsupported dilation')

def conv(x,r):
    h,w=x.shape[:2];s,d,k=r['stride'],r['dilation'],r['kernel'];oh,ow=(h+s-1)//s,(w+s-1)//s
    ph=max(0,(oh-1)*s+(k-1)*d+1-h);pw=max(0,(ow-1)*s+(k-1)*d+1-w)
    centered=np.pad(x.astype(np.int64)-r['input_zero'],((ph//2,ph-ph//2),(pw//2,pw-pw//2),(0,0)))
    acc=np.broadcast_to(r['bias'],(oh,ow,4)).astype(np.int64).copy()
    for ky in range(k):
        for kx in range(k):
            tile=centered[ky*d:ky*d+oh*s:s,kx*d:kx*d+ow*s:s]
            acc+=np.einsum('hwc,oc->hwo',tile,r['weights'][:,ky,kx,:].astype(np.int64))
    high=(acc*r['multiplier']+(1<<30))>>31
    rs=-r['shift'];mask=(1<<rs)-1
    rounded=(high>>rs)+((high&mask)>((mask>>1)+(high<0)))
    return np.clip(rounded+r['output_zero'],r['output_zero'],127).astype(np.int8)

def save_mem(name,x):
    raw=x.tobytes();(a.output/name).write_text(''.join(f'{int.from_bytes(raw[j:j+4],"little"):08x}\n' for j in range(0,len(raw),4)))

if a.input:
    x=np.frombuffer(a.input.read_bytes(),np.int8).reshape(a.height,a.width,4)
else:
    x=np.random.default_rng(20261008).integers(-128,128,(a.height,a.width,4),dtype=np.int8);x[...,3]=-128
save_mem('input.mem',x);params=[v for r in layers for v in r['parameters']]
(a.output/'parameters.mem').write_text(''.join(f'{v:08x}\n' for v in params))
results=[];native=x.copy()
for r in layers:
    native=conv(native,r);results.append(native.copy());save_mem('output-'+str(r['node'])+'.mem',native)
save_mem('output-low.mem',native)
expanded=np.repeat(np.repeat(native,2,0),2,1)
raw=expanded.tobytes()
(a.output/'output-full.mem').write_text(''.join(f'{int.from_bytes(raw[j:j+16],"little"):032x}\n' for j in range(0,len(raw),16)))
(a.output/'reference.bin').write_bytes(expanded.tobytes())
parity=[]
if a.verify_tflite:
    if (a.height,a.width)!=(480,640):raise ValueError('native TFLite verification needs 640x480')
    import tensorflow as tf
    tf.config.threading.set_intra_op_parallelism_threads(4)
    rt=tf.lite.Interpreter(model_content=blob,experimental_preserve_all_tensors=True,
                          experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF)
    rt.allocate_tensors();rt.set_tensor(int(g.Inputs(0)),x[None]);rt.invoke()
    for r,y in zip(layers,results):
        actual=rt.get_tensor(r['tensor_out'])[0]
        different=int(np.count_nonzero(actual!=y));max_err=int(np.max(abs(actual.astype(np.int16)-y.astype(np.int16))))
        parity.append({'node':r['node'],'different_bytes':different,'max_lsb':max_err})
        if different:raise RuntimeError(('integer reference disagrees with BUILTIN_REF',parity))
    if not np.array_equal(expanded,rt.get_tensor(int(g.Outputs(0)))[0]):raise RuntimeError('final resize differs')
compact=[{k:(v.tolist() if isinstance(v,np.ndarray) else v) for k,v in r.items() if k!='weights'} for r in layers]
report={'model_sha256':hashlib.sha256(blob).hexdigest(),'input_sha256':hashlib.sha256(x.tobytes()).hexdigest(),
        'reference_sha256':hashlib.sha256(expanded.tobytes()).hexdigest(),'shape':[a.height,a.width,4],
        'layers':compact,'tflite_layer_parity':parity,'hardware_proven':False}
(a.output/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
(a.output/'stream_model.h').write_text('#pragma once\n#include <stdint.h>\nstatic const uint32_t iris_cnn_parameters[3][52]={\n'+
    ',\n'.join('{'+','.join(f'0x{v:08x}u' for v in r['parameters'])+'}' for r in layers)+'\n};\n')
print(json.dumps({k:v for k,v in report.items() if k!='layers'},indent=2))
