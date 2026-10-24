#!/usr/bin/env python3
"""Reproducible synthetic noise comparison; these are not camera measurements."""
import argparse
import json
from pathlib import Path
import numpy as np
from run_style_contour_tests import gradient_image


def median_image(image):
    padded=np.pad(image,((1,1),(1,1),(0,0)),mode="edge")
    return np.partition(np.stack([padded[y:y+480,x:x+640] for y in range(3) for x in range(3)]),4,axis=0)[4]


def compare():
    rng=np.random.default_rng(20261016)
    clean=np.empty((1080,1920,3),dtype=np.uint8)
    clean[:]=[128,144,160]
    clean[:,960:]=[192,176,160]
    clean[330:750,1150:1450]=[48,64,80]
    y=(np.arange(480)*9//4)[:,None]
    x=(240+np.arange(640)*9//4)[None,:]
    reference=clean[y,x].astype(np.int32)
    # Interior masks exclude real edges so that contrast is not scored as noise.
    flat=np.broadcast_to((x<850)&(x>350)&(y>100)&(y<950),(480,640))
    results={"scope":"synthetic RGB fixtures only; not real-camera quality acceptance","seed":20261016,"cases":{}}
    for name,sigma,impulse in [("salt_pepper",0,0.02),("random",18,0),("mixed",18,0.02)]:
        noisy=np.clip(np.rint(clean.astype(np.float64)+rng.normal(0,sigma,clean.shape)),0,255).astype(np.uint8)
        mask=rng.random((1080,1920))<impulse
        values=rng.integers(0,2,(1080,1920),dtype=np.uint8)*255
        noisy[mask]=values[mask,None]
        point=noisy[y,x]
        gaussian=np.zeros((480,640,3),dtype=np.int32)
        for dy in range(-1,2):
            for dx in range(-1,2):
                gaussian+=noisy[np.clip(y+dy,0,1079),x+dx].astype(np.int32)*(2 if dy==0 else 1)*(2 if dx==0 else 1)
        gaussian=(gaussian+8)//16
        median=median_image(point).astype(np.int32)
        measurements={}
        for method,image in [("point",point),("gaussian_source_3x3",gaussian),("median_tensor_3x3",median)]:
            error=image.astype(np.int32)-reference
            grey=(image[:,:,0].astype(np.int32)+2*image[:,:,1].astype(np.int32)+image[:,:,2].astype(np.int32)+2)//4
            grad=gradient_image(grey)
            measurements[method]={"flat_rmse":float(np.sqrt(np.mean(error[flat]**2))),"flat_pixels_error_over_32":int(np.count_nonzero(np.max(np.abs(error),axis=-1)[flat]>32)),"contour_threshold":32,"flat_false_contour_fraction":float(np.mean(grad[flat]>32)),"image_mae":float(np.abs(error).mean())}
        if impulse:
            assert measurements["median_tensor_3x3"]["flat_rmse"]<measurements["gaussian_source_3x3"]["flat_rmse"]
        assert measurements["median_tensor_3x3"]["flat_false_contour_fraction"]<measurements["gaussian_source_3x3"]["flat_false_contour_fraction"]
        if name=="salt_pepper":
            assert measurements["median_tensor_3x3"]["flat_pixels_error_over_32"]<measurements["gaussian_source_3x3"]["flat_pixels_error_over_32"]
        results["cases"][name]=measurements
    clean_median=median_image(reference.astype(np.uint8)).astype(np.int32)
    assert np.array_equal(clean_median[:,315:325],reference[:,315:325])
    results["clean_step_edge_preserved"]=True
    return results


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output",type=Path)
    args=parser.parse_args()
    result=compare()
    text=json.dumps(result,indent=2)+"\n"
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(text)
    print(text,end="")
