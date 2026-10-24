#!/usr/bin/env python3
"""Native camera filtering checked against full-image integer convolution."""
import argparse
import tempfile
from pathlib import Path
import numpy as np
from run_style_contour_tests import compile_tb, simulate


def check(tmp, full=False):
    w,h,ht,vt=(1920,1080,1100,1125) if full else (20,10,20,15)
    rng=np.random.default_rng(20261016)
    images=[rng.integers(0,256,(h,w,3),dtype=np.int32)]
    if not full:
        images += [np.full((h,w,3),255,dtype=np.int32),np.zeros((h,w,3),np.int32)]
        edge=np.zeros((h,w,3),np.int32);edge[:,w//2:]=255;edge[0,0]=[255,0,128];edge[-1,-1]=[0,255,128];images.append(edge)
    stimuli=[];refs=[]
    for image in images:
        padded=np.pad(image,((1,1),(1,1),(0,0)),mode='edge')
        ref=(sum(wy*wx*padded[y:y+h,x:x+w] for y,wy in enumerate((1,2,1)) for x,wx in enumerate((1,2,1)))+8)//16
        for pair in ref.reshape(-1,6):refs.append(''.join(f'{c:02x}' for c in pair))
        # Include vertical blanking before and after each full active image.
        for y in range(vt):
            for x in range(ht):
                de=3<=y<h+3 and 4<=x<w//2+4
                rgb=image[y-3,(x-4)*2:(x-4)*2+2].reshape(-1) if de else [0]*6
                value=(int(x<2)<<50)|(int(y<1)<<49)|(int(de)<<48)
                value|=sum(int(c)<<(8*(5-j)) for j,c in enumerate(rgb))
                stimuli.append(f'{value:013x}')
    a=tmp/'camera-in.mem';b=tmp/'camera-ref.mem';exe=tmp/'camera'
    a.write_text('\n'.join(stimuli)+'\n');b.write_text('\n'.join(refs)+'\n')
    compile_tb('tb_camera_denoise',['tests/video/tb_camera_denoise.sv','iris_ws/src/video/debayer/camera_denoise_2px.v'],exe,
               [f'-Ptb_camera_denoise.W={w}',f'-Ptb_camera_denoise.H={h}',f'-Ptb_camera_denoise.HT={ht}',f'-Ptb_camera_denoise.COUNT={len(stimuli)}',f'-Ptb_camera_denoise.PIXELS={len(refs)}'])
    simulate(exe,[f'+IN={a}',f'+REF={b}'])


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--full',action='store_true');args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='iris-camera-denoise-') as directory:check(Path(directory),args.full)
