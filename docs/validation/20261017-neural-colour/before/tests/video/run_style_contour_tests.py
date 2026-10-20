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
DEFAULTS=dict(SOURCE_MIX_Q2=3,SATURATION_Q2=5,COLOUR_BITS=5,
              NORMAL_THRESHOLD=20,NORMAL_INK_GAIN=2,NORMAL_INK_CAP=128,
              STRONG_THRESHOLD=40,STRONG_INK_GAIN=4,STRONG_INK_CAP=160)

def render(neural, gradient, mode, source, **overrides):
    config=DEFAULTS|overrides
    rgb=np.minimum(255,np.floor(neural*SCALE+.5)).astype(np.int32)
    minimum=rgb.min(axis=-1)
    if mode==0:return rgb
    if mode==1:return np.maximum(0,rgb-np.maximum(0,239-minimum)[...,None]*4)
    mix=config['SOURCE_MIX_Q2']
    rgb=(mix*source+(4-mix)*rgb+2)//4
    luma=(rgb[...,0]+2*rgb[...,1]+rgb[...,2]+2)//4
    rgb=np.clip(luma[...,None]+((rgb-luma[...,None])*config['SATURATION_Q2']+2)//4,0,255)
    bits=config['COLOUR_BITS']
    if bits<8:
        step=1<<(8-bits)
        rgb=np.where((rgb==0)|(rgb==255),rgb,(rgb//step)*step+step//2)
    prefix='STRONG' if mode==3 else 'NORMAL'
    threshold,gain,cap=(config[f'{prefix}_{suffix}'] for suffix in ('THRESHOLD','INK_GAIN','INK_CAP'))
    ink=np.clip((gradient-threshold)*gain,0,cap)
    return np.maximum(0,rgb-ink[...,None])

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

def unit(tmp,**overrides):
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
        source=rng.integers(0,256,(64,3),dtype=np.int32)
        if j%16 in (5,6):
            # A monochrome/white neural tensor must still produce distinct
            # red, green, blue, cyan, magenta and yellow camera patches.
            grey[:]=128;neural[:]=200 if j%16==5 else 255
            source[:]=np.tile(np.array([[255,0,0],[0,255,0],[0,0,255],
                [0,255,255],[255,0,255],[255,255,0],[0,0,0],[255,255,255]]),(8,1))
        if j%16==7:
            grey[:]=128;source[:]=rng.integers(0,256,(64,1));neural[:]=source
        if j%16==8:
            # Hit the slope/cap boundary for the two edge presets.
            grey[:,:32]=0;grey[:,32:]=80
        gx=np.zeros(64,dtype=np.int32);gy=gx.copy()
        for dy in range(5):
            for dx in range(-2,3):
                values=grey[dy,np.clip(np.arange(64)+dx,0,63)]
                gx+=values*WEIGHT[dy]*DERIVATIVE[dx+2]
                gy+=values*DERIVATIVE[dy]*WEIGHT[dx+2]
        expected=render(neural,(np.abs(gx)+np.abs(gy)+8)//16,mode,source,**overrides)
        if not overrides and mode>=2 and j%16 in (5,6):
            assert np.all(np.argmax(expected[:3],axis=1)==np.arange(3))
            assert np.all(np.ptp(expected[:3],axis=1)>150),'camera colour lost'
        for x in range(0,64,2):
            rows=sum(int(grey[y,x+k])<<(y*16+k*8) for y in range(5) for k in range(2))
            rgba=sum(int(neural[x+k,c]^128)<<(k*32+c*8) for k in range(2) for c in range(3))|(128<<24)|(128<<56)
            source_rgb=0
            for value in source[x:x+2].flat:source_rgb=(source_rgb<<8)|int(value)
            stim.append((((1<<148)|(int(x==0)<<147)|(int(x==62)<<146)|(mode<<144)|(rows<<64)|rgba)<<48)|source_rgb)
            rgb=0
            for v in expected[x:x+2].flat:rgb=(rgb<<8)|int(v)
            ref.append((1<<48)|rgb)
        for _ in range(8):stim.append(mode<<192);ref.append(0)
    a=tmp/'contour-in.mem';b=tmp/'contour-ref.mem';exe=tmp/'contour'
    a.write_text(''.join(f'{v:050x}\n' for v in stim));b.write_text(''.join(f'{v:013x}\n' for v in ref))
    compile_tb('tb_style_contour',['tests/video/tb_style_contour.sv','iris_ws/src/cnn/iris_style_contour.v','iris_ws/src/cnn/iris_style_dequant.v'],exe,
               [f'-Ptb_style_contour.{key}={value}' for key,value in overrides.items()])
    simulate(exe,[f'+IN={a}',f'+REF={b}',f'+COUNT={len(stim)}'])

def panels(tmp,negative,first,second,first_bank=0,second_bank=1,native_camera=1):
    images=[];y=np.arange(480)[:,None];x=np.arange(640)[None,:]
    for pair,mode in zip((first_bank,second_bank),(first,second)):
        source=np.stack([(y*3+x*7+c*43+pair*23)%256 for c in range(3)],axis=-1)
        neural=(source+31)%256
        grey=(source[:,:,0]+2*source[:,:,1]+source[:,:,2]+2)//4
        images.append(render(neural,gradient_image(grey,negative and pair==first_bank),mode,source))
    expected=tmp/f'panel-{negative}-{first}-{second}.mem'
    expected.write_text(''.join(f'{int(r):02x}{int(g):02x}{int(b):02x}\n' for image in images for r,g,b in image.reshape(-1,3)))
    exe=tmp/f'panel-{negative}-{first}-{second}'
    compile_tb('tb_style_panels',['tests/video/tb_style_panels.sv','iris_ws/src/cnn/iris_style_contour_panels.v','iris_ws/src/cnn/iris_style_split_scaler.v','iris_ws/src/cnn/iris_style_contour.v','iris_ws/src/cnn/iris_style_dequant.v'],exe,
        ['-DTEST_CONTOUR','-Ptb_style_panels.CONTOUR=1','-Ptb_style_panels.VISIBILITY=1',f'-Ptb_style_panels.NEGATIVE={negative}',f'-Ptb_style_panels.FIRST_MODE={first}',f'-Ptb_style_panels.SECOND_MODE={second}',f'-Ptb_style_panels.FIRST_BANK={first_bank}',f'-Ptb_style_panels.SECOND_BANK={second_bank}',f'-Ptb_style_panels.NATIVE_CAMERA={native_camera}'])
    simulate(exe,[f'+CONTOUR_REF={expected}'])

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--panels',action='store_true');p.add_argument('--negative',type=int,choices=[0,1]);a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='iris-contour-tests-') as directory:
        tmp=Path(directory);unit(tmp)
        unit(tmp,SOURCE_MIX_Q2=0,SATURATION_Q2=4,COLOUR_BITS=8)
        unit(tmp,SOURCE_MIX_Q2=4,SATURATION_Q2=8,COLOUR_BITS=1,
             NORMAL_THRESHOLD=64,NORMAL_INK_GAIN=4,NORMAL_INK_CAP=96,
             STRONG_THRESHOLD=96,STRONG_INK_GAIN=2,STRONG_INK_CAP=128)
        if a.panels:
            if a.negative is not None:panels(tmp,a.negative,2,3)
            else:
                for case in [(0,2,3),(0,3,0),(1,2,1)]:panels(tmp,*case)
