#!/usr/bin/env python3
"""Check RAW denoise against separate Bayer planes and an independent median."""
import argparse
import json
import tempfile
from pathlib import Path

import numpy as np
from run_style_contour_tests import compile_tb, simulate


def reference(raw, impulse=24, smooth=12):
    """Work in the four Bayer planes; never interpolate between colours."""
    result = np.empty_like(raw)
    for py in range(2):
        for px in range(2):
            plane = raw[py::2, px::2].astype(np.int32)
            p = np.pad(plane, 1, mode='edge')
            n, s, w, e = p[:-2, 1:-1], p[2:, 1:-1], p[1:-1, :-2], p[1:-1, 2:]
            median = np.median(np.stack([plane, n, s, w, e]), axis=0).astype(np.int32)
            guide = np.where(np.abs(plane-median) > impulse, median, plane)
            total = guide*4 + 4
            for neighbour in (n, s, w, e):
                total += np.clip(neighbour, np.maximum(0, guide-smooth), guide+smooth)
            result[py::2, px::2] = total//8
    return result


def source_reference(raw):
    """BGGR bilinear interpolation with same-colour reflected borders."""
    h,w=raw.shape
    rgb=np.empty((h,w,3),dtype=np.int32)
    def sample(y,x):
        y=1 if y<0 else h-2 if y>=h else y
        x=1 if x<0 else w-2 if x>=w else x
        return int(raw[y,x])
    for y in range(h):
        for x in range(w):
            c=sample(y,x)
            horizontal=(sample(y,x-1)+sample(y,x+1)+1)//2
            vertical=(sample(y-1,x)+sample(y+1,x)+1)//2
            cross=(sample(y,x-1)+sample(y,x+1)+sample(y-1,x)+sample(y+1,x)+2)//4
            diagonal=(sample(y-1,x-1)+sample(y-1,x+1)+sample(y+1,x-1)+sample(y+1,x+1)+2)//4
            rgb[y,x]=((diagonal,cross,c) if (y%2,x%2)==(0,0) else
                      (c,cross,diagonal) if (y%2,x%2)==(1,1) else
                      (vertical,c,horizontal) if y%2==0 else (horizontal,c,vertical))
    p=np.pad(rgb,((1,1),(1,1),(0,0)),mode='edge')
    return (sum(wy*wx*p[y:y+h,x:x+w] for y,wy in enumerate((1,2,1))
                for x,wx in enumerate((1,2,1)))+8)//16


def check(tmp, full=False, source=False):
    w, h, ht, vt = (1920, 1080, 1100, 1125) if full else (24, 12, 20, 20)
    rng = np.random.default_rng(20261017)
    images = [rng.integers(0, 256, (h, w), dtype=np.int32)]
    if not full:
        # Different fixed Bayer colours catch accidental cross-colour mixing.
        constant = np.tile(np.array([[21, 75], [138, 243]]), (h//2, w//2))
        edge = constant.copy()
        edge[:, w//2:] = 255-edge[:, w//2:]
        impulses = constant.copy()
        impulses[4:6, 6:8] = 255
        impulses[8:10, 16:18] = 0
        images += [constant, np.zeros((h,w), np.int32), np.full((h,w), 255, np.int32), edge, impulses]
    expected = np.concatenate([(source_reference(reference(image)) if source else reference(image))
                               .reshape(-1, 6 if source else 2) for image in images])
    ref_path, in_path, exe = tmp/'raw-ref.mem', tmp/'raw-in.mem', tmp/'raw'
    ref_path.write_text(''.join(''.join(f'{int(c):02x}' for c in pair)+'\n' for pair in expected))
    count = 0
    # Stream fixtures to avoid allocating a full-frame Python string list.
    with in_path.open('w') as output:
        for image in images:
            for y in range(vt):
                for x in range(ht):
                    de = 3 <= y < h+3 and 4 <= x < w//2+4
                    pair = image[y-3, (x-4)*2:(x-4)*2+2] if de else (0,0)
                    value = (int(x<2)<<18)|(int(y<1)<<17)|(int(de)<<16)|(int(pair[0])<<8)|int(pair[1])
                    output.write(f'{value:05x}\n')
                    count += 1
    compile_tb('tb_camera_raw_denoise', ['tests/video/tb_camera_raw_denoise.sv',
        'iris_ws/src/video/debayer/camera_raw_denoise_2px.v',
        'iris_ws/src/video/debayer/debayer_top_2to1.v','iris_ws/src/video/debayer/camera_denoise_2px.v'], exe,
        [f'-Ptb_camera_raw_denoise.W={w}', f'-Ptb_camera_raw_denoise.H={h}',
         f'-Ptb_camera_raw_denoise.HT={ht}', f'-Ptb_camera_raw_denoise.COUNT={count}',
         f'-Ptb_camera_raw_denoise.PIXELS={len(expected)}',f'-Ptb_camera_raw_denoise.SOURCE={int(source)}'])
    simulate(exe, [f'+IN={in_path}', f'+REF={ref_path}'])


def metrics():
    """Synthetic spatial-noise evidence, not a claim about the real sensor."""
    rng = np.random.default_rng(5916)
    clean = np.full((256,384), 100, np.int32)
    noisy = np.clip(np.rint(clean+rng.normal(0,8,clean.shape)),0,255).astype(np.int32)
    impulses = rng.random(clean.shape) < .003
    noisy[impulses] = rng.choice([0,255], int(impulses.sum()))
    filtered = reference(noisy)
    flat_rmse = lambda a: float(np.sqrt(np.mean((a.astype(float)-clean)**2)))
    edge = np.full_like(clean, 40);edge[:,192:]=180
    result = reference(edge)
    assert np.array_equal(reference(np.tile(np.array([[21,75],[138,243]]),(128,192))),
                          np.tile(np.array([[21,75],[138,243]]),(128,192)))
    assert np.max(np.abs(result-edge)) <= 2
    return {'scope':'synthetic RAW cross-filter, no real-camera quality acceptance',
            'raw_rmse_before':flat_rmse(noisy),'raw_rmse_after':flat_rmse(filtered),
            'outliers_over_32_before':int(np.sum(np.abs(noisy-clean)>32)),
            'outliers_over_32_after':int(np.sum(np.abs(filtered-clean)>32)),
            'clean_step_max_bias':int(np.max(np.abs(result-edge)))}


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--full',action='store_true')
    p.add_argument('--source',action='store_true',help='check RAW filter, BGGR demosaic and RGB Gaussian together')
    p.add_argument('--metrics',type=Path)
    args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='iris-raw-denoise-') as directory:
        check(Path(directory),args.full,args.source)
    result=metrics()
    if args.metrics:
        args.metrics.parent.mkdir(parents=True,exist_ok=True)
        args.metrics.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
