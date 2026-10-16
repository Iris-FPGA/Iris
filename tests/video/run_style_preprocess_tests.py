#!/usr/bin/env python3
"""Check point, source Gaussian, median and cascaded tensor denoising."""
import argparse
import tempfile
import numpy as np
from pathlib import Path

from run_style_contour_tests import compile_tb, simulate


def median_fixture(tmp, smooth=False):
    y=(np.arange(480,dtype=np.int32)*9//4)[:,None]
    x=(240+np.arange(640,dtype=np.int32)*9//4)[None,:]
    images=[]
    for pattern in range(8):
        if pattern==0:
            channels=[np.broadcast_to(x,(480,640)),np.broadcast_to(y,(480,640)),x+y]
        elif pattern==1:
            channels=[(x*73+y*151)^(x*y*17),(x*191+y*13)^(x*y*31),(x*43+y*97)^(x*y*7)]
        elif pattern==2:channels=[np.full((480,640),255)]*3
        elif pattern==3:channels=[np.zeros((480,640),dtype=np.int32)]*3
        elif pattern==4:channels=[np.where((x==960)&(y==540),255,0)]*3
        elif pattern==5:
            channels=[np.broadcast_to(np.where(x<960,0,255),(480,640)),np.broadcast_to(np.where(y<540,0,255),(480,640)),np.where((x+y)%2,0,255)]
        elif pattern==6:
            channels=[np.where(((x*73+y*151)^(x*y*17))%13==0,np.where((x+y)%2,255,0),128)]*3
        else:
            channels=[112+v%33 for v in [(x*73+y*151)^(x*y*17),(x*191+y*13)^(x*y*31),(x*43+y*97)^(x*y*7)]]
        source=np.stack(channels,axis=-1).astype(np.uint8)
        padded=np.pad(source,((1,1),(1,1),(0,0)),mode='edge')
        # Full 2D order statistic, independent of the RTL's 19-comparator network.
        neighbours=np.stack([padded[dy:dy+480,dx:dx+640] for dy in range(3) for dx in range(3)])
        result=np.partition(neighbours,4,axis=0)[4]
        if smooth:
            for _ in range(2):
                padded=np.pad(result.astype(np.int32),((1,1),(1,1),(0,0)),mode='edge')
                # Independent full 2D convolution; round once per stage.
                result=(sum(wy*wx*padded[dy:dy+480,dx:dx+640]
                            for dy,wy in enumerate((1,2,1))
                            for dx,wx in enumerate((1,2,1)))+8)//16
        images.append(result)
    ref=tmp/('cascade-ref.mem' if smooth else 'median-ref.mem')
    ref.write_text(''.join(f'{r:02x}{g:02x}{b:02x}\n' for image in images for r,g,b in image.reshape(-1,3)))
    return ref


def check_preprocess(tmp, median_only=False, smooth_only=False):
    cases=[(0,1,1)] if smooth_only else [(0,1,0)] if median_only else [(0,0,0),(1,0,0),(0,1,0),(0,1,1)]
    for enabled,median,smooth in cases:
        exe = tmp / f'preprocess-{enabled}-{median}-{smooth}'
        compile_tb('tb_style_preprocess', [
            'tests/video/tb_style_preprocess.sv',
            'iris_ws/src/cnn/iris_style_preprocess.v',
        ], exe, [f'-Ptb_style_preprocess.GAUSSIAN={enabled}',f'-Ptb_style_preprocess.MEDIAN={median}',f'-Ptb_style_preprocess.SMOOTH={smooth}'])
        simulate(exe, [f'+MEDIAN_REF={median_fixture(tmp,smooth=bool(smooth))}'] if median else [])


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cascade-only',action='store_true')
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='iris-preprocess-tests-') as directory:
        check_preprocess(Path(directory),smooth_only=args.cascade_only)
