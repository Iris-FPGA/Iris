#!/usr/bin/env python3
"""Refine candidates against full-resolution teacher targets and contour loss.

Training images only. Validation and calibration splits remain excluded.
"""
import argparse,json,random,hashlib
import numpy as np
import torch
from torch.nn import functional as F
from distill import ROOT,MODEL,CANDIDATES,Student,Teacher,dataset
from PIL import Image

def frame(path):
    im=Image.open(path).convert('RGB'); w,h=im.size
    if w*3>h*4:
        nw=h*4//3; im=im.crop(((w-nw)//2,0,(w+nw)//2,h))
    else:
        nh=w*3//4; im=im.crop((0,(h-nh)//2,w,(h+nh)//2))
    return torch.from_numpy(np.asarray(im.resize((640,480),Image.Resampling.BILINEAR),dtype=np.float32).transpose(2,0,1).copy())

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--steps',type=int,default=5000);p.add_argument('--batch',type=int,default=4)
    p.add_argument('--candidate',choices=list(CANDIDATES));p.add_argument('--init');a=p.parse_args()
    torch.set_num_threads(4);torch.manual_seed(20261008);rng=random.Random(20261008)
    teacher=Teacher().cuda().eval();pairs=[];out=ROOT/'build'
    for k,path in enumerate(dataset()['train']):
        x=frame(path).cuda()[None]
        with torch.no_grad():target=teacher(x).clamp(0,255)
        pairs.append((x[0],target[0]))
        if k%10==0:print('full-resolution teacher pairs',k,flush=True)
    del teacher
    models={};opts={};initial={}
    for name,spec in CANDIDATES.items():
        if a.candidate and a.candidate!=name:continue
        # Skip variant shares all trainable tensors with the baseline.
        source=out/a.init if a.init else out/f'{name}.pt'
        if not source.exists():continue
        old=torch.load(source,map_location='cpu',weights_only=True);initial[name]=old['step']+1
        model=Student(*spec).cuda();state=old['state_dict']
        # Replacing the last spatial decoder with a pointwise color head is
        # initialized by summing its taps; this is an initialization only.
        expected=model.state_dict()
        for key,value in list(state.items()):
            if value.shape!=expected[key].shape:
                if value.ndim==4 and expected[key].shape[-2:]==(1,1):
                    state[key]=value.sum((-2,-1),keepdim=True)
                else:raise ValueError(f'incompatible initializer {key}')
        model.load_state_dict(state);models[name]=model
        opts[name]=torch.optim.Adam(model.parameters(),lr=3e-4)
    for step in range(a.steps):
        xs=[];ys=[]
        for b in range(a.batch):
            x,y=rng.choice(pairs);top=rng.randrange(0,480-256+1,4);left=rng.randrange(0,640-256+1,4)
            x=x[:,top:top+256,left:left+256];y=y[:,top:top+256,left:left+256]
            if rng.random()<.5:x=x.flip(-1);y=y.flip(-1)
            xs.append(x);ys.append(y)
        x=torch.stack(xs);y=torch.stack(ys)/255;losses={}
        # Dark contour pixels matter more than the near-white background.
        weight=1+3*(1-y.mean(1,keepdim=True))
        for name,m in models.items():
            opts[name].zero_grad(set_to_none=True);pred=m(x)/255
            loss=((pred-y).abs()*weight).mean()
            for axis in [-1,-2]:
                loss+=.75*F.l1_loss(torch.diff(pred,dim=axis),torch.diff(y,dim=axis))
            loss.backward();torch.nn.utils.clip_grad_norm_(m.parameters(),1);opts[name].step();losses[name]=float(loss)
        if step%100==0:print(json.dumps({'refine_step':step,'loss':losses}),flush=True)
        if (step+1)%500==0 or step==a.steps-1:
            for name,m in models.items():
                torch.save({'state_dict':m.state_dict(),'candidate':name,'step':initial[name]+step,
                            'teacher_sha256':hashlib.sha256(MODEL.read_bytes()).hexdigest(),
                            'refinement':'640x480 teacher targets; 256 aligned crops; weighted contour loss'},out/f'{name}_refined.pt')
if __name__=='__main__':main()
