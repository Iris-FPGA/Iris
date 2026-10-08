#!/usr/bin/env python3
"""Independent image convolution oracle for the camera-guided display RTL."""
import argparse
import os
import subprocess
import tempfile
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
WEIGHT=[1,4,6,4,1]
DERIVATIVE=[-1,-2,0,2,1]
SCALE=1.2276244163513184

def render(neural, gradient, mode):
    rgb=np.minimum(255,np.floor(neural*SCALE+.5)).astype(np.int32)
    minimum=rgb.min(axis=-1)
    if mode==0:return rgb
    if mode==1:return np.maximum(0,rgb-np.maximum(0,239-minimum)[...,None]*4)
    threshold,gain,cap=(40,4,160) if mode==3 else (32,2,128)
    ink=np.clip((gradient-threshold)*gain,0,cap)
    base=255-((255-minimum+2)//4)
    return np.maximum(0,np.minimum(255,base[...,None]+rgb-minimum[...,None])-ink[...,None])

def gradient_image(grey, negative=False):
    h,w=grey.shape
    gx=np.zeros_like(grey,dtype=np.int32);gy=gx.copy()
    for dy in range(-2,3):
        rows=np.clip(np.arange(h)+dy,0,h-1)
        if negative:rows=np.where(rows==10,np.arange(h),rows)
        for dx in range(-2,3):
            cols=np.clip(np.arange(w)+dx,0,w-1)
            values=grey[rows[:,None],cols[None,:]]
            gx+=values*WEIGHT[dy+2]*DERIVATIVE[dx+2]
            gy+=values*DERIVATIVE[dy+2]*WEIGHT[dx+2]
    return (np.abs(gx)+np.abs(gy)+8)//16

def compile_tb(name, files, dest, params=()):
    cmd=[os.environ.get('IVERILOG','iverilog')]
    if os.environ.get('IVERILOG_LIB'):cmd+=['-B',os.environ['IVERILOG_LIB']]
    subprocess.run(cmd+['-g2012','-s',name,*params,'-o',str(dest),*files],cwd=ROOT,check=True)

def simulate(dest, args):
    cmd=[os.environ.get('VVP','vvp')]
    if os.environ.get('IVERILOG_LIB'):cmd+=['-M',os.environ['IVERILOG_LIB']]
    subprocess.run(cmd+[str(dest),*args],cwd=ROOT,check=True)

def unit(tmp):
    rng=np.random.default_rng(20261008);stim=[];ref=[]
    for j in range(256):
        mode=j//64
        grey=rng.integers(0,256,(5,64),dtype=np.int32)
        if j%16==0:grey[:]=255
        if j%16==1:grey[:]=0
        if j%16==2:grey[:,:32]=16;grey[:,32:]=240
        if j%16==3:grey[:2]=0;grey[2:]=255
        if j%16==4:grey[:]=128;grey[2,31]=0
        neural=rng.integers(0,256,(64,3),dtype=np.int32)
        gx=np.zeros(64,dtype=np.int32);gy=gx.copy()
        for dy in range(5):
            for dx in range(-2,3):
                values=grey[dy,np.clip(np.arange(64)+dx,0,63)]
                gx+=values*WEIGHT[dy]*DERIVATIVE[dx+2]
                gy+=values*DERIVATIVE[dy]*WEIGHT[dx+2]
        expected=render(neural,(np.abs(gx)+np.abs(gy)+8)//16,mode)
        for x in range(0,64,2):
            rows=sum(int(grey[y,x+k])<<(y*16+k*8) for y in range(5) for k in range(2))
            rgba=sum(int(neural[x+k,c]^128)<<(k*32+c*8) for k in range(2) for c in range(3))|(128<<24)|(128<<56)
            stim.append((1<<148)|(int(x==0)<<147)|(int(x==62)<<146)|(mode<<144)|(rows<<64)|rgba)
            rgb=0
            for v in expected[x:x+2].flat:rgb=(rgb<<8)|int(v)
            ref.append((1<<48)|rgb)
        for _ in range(8):stim.append(mode<<144);ref.append(0)
    a=tmp/'contour-in.mem';b=tmp/'contour-ref.mem';exe=tmp/'contour'
    a.write_text(''.join(f'{v:038x}\n' for v in stim));b.write_text(''.join(f'{v:013x}\n' for v in ref))
    compile_tb('tb_style_contour',['tests/video/tb_style_contour.sv','iris_ws/src/cnn/iris_style_contour.v','iris_ws/src/cnn/iris_style_dequant.v'],exe)
    simulate(exe,[f'+IN={a}',f'+REF={b}',f'+COUNT={len(stim)}'])

def panels(tmp,negative,first,second):
    images=[];y=np.arange(480)[:,None];x=np.arange(640)[None,:]
    for pair,mode in enumerate([first,second]):
        source=np.stack([(y*3+x*7+c*43+pair*23)%256 for c in range(3)],axis=-1)
        neural=(source+31)%256
        grey=(source[:,:,0]+2*source[:,:,1]+source[:,:,2]+2)//4
        images.append(render(neural,gradient_image(grey,negative and pair==0),mode))
    expected=tmp/f'panel-{negative}-{first}-{second}.mem'
    expected.write_text(''.join(f'{int(r):02x}{int(g):02x}{int(b):02x}\n' for image in images for r,g,b in image.reshape(-1,3)))
    exe=tmp/f'panel-{negative}-{first}-{second}'
    compile_tb('tb_style_panels',['tests/video/tb_style_panels.sv','iris_ws/src/cnn/iris_style_contour_panels.v','iris_ws/src/cnn/iris_style_contour.v','iris_ws/src/cnn/iris_style_dequant.v'],exe,
        ['-DTEST_CONTOUR','-Ptb_style_panels.CONTOUR=1','-Ptb_style_panels.VISIBILITY=1',f'-Ptb_style_panels.NEGATIVE={negative}',f'-Ptb_style_panels.FIRST_MODE={first}',f'-Ptb_style_panels.SECOND_MODE={second}'])
    simulate(exe,[f'+CONTOUR_REF={expected}'])

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--panels',action='store_true');p.add_argument('--negative',type=int,choices=[0,1]);a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='iris-contour-tests-') as directory:
        tmp=Path(directory);unit(tmp)
        if a.panels:
            if a.negative is not None:panels(tmp,a.negative,2,3)
            else:
                for case in [(0,2,3),(0,3,0),(1,2,1)]:panels(tmp,*case)
