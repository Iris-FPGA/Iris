#!/usr/bin/env python3
"""Distill shallow CNNs for a line-buffer implementation (no Add/skip graph).

Uses the existing fixed COCO train/calibration/validation split. Full-frame
teacher targets establish phase before aligned crop training. Checkpoints,
teacher cache and reports go under ignored build/stream; the deployed model
and earlier checkpoints are never overwritten.
"""
import argparse
import hashlib
import inspect
import json
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from PIL import Image

from distill import ROOT, MODEL, Teacher, dataset, validate_teacher

CANDIDATES = {'micro4_d1': 1, 'micro4_d2': 2, 'micro4_d4': 4}

class StreamConv(nn.Module):
    def __init__(self, cin, cout, kernel=3, stride=1, dilation=1, activation=True, bn=True):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, kernel, stride=stride, dilation=dilation, bias=True)
        self.bn = nn.BatchNorm2d(cout) if bn else nn.Identity()
        self.kernel, self.stride, self.dilation = kernel, stride, dilation
        self.activation = activation

    def forward(self, x):
        h, w = x.shape[-2:]
        k = (self.kernel - 1) * self.dilation + 1
        ph = max(0, ((h+self.stride-1)//self.stride-1)*self.stride+k-h)
        pw = max(0, ((w+self.stride-1)//self.stride-1)*self.stride+k-w)
        x = self.bn(self.conv(F.pad(x, (pw//2, pw-pw//2, ph//2, ph-ph//2))))
        return F.relu(x) if self.activation else x

    def folded(self):
        w, b = self.conv.weight.detach(), self.conv.bias.detach()
        if isinstance(self.bn, nn.BatchNorm2d):
            scale = self.bn.weight.detach() / torch.sqrt(self.bn.running_var + self.bn.eps)
            w = w * scale[:, None, None, None]
            b = (b-self.bn.running_mean) * scale + self.bn.bias.detach()
        return w.cpu().numpy().transpose(2, 3, 1, 0), b.cpu().numpy()

class StreamStudent(nn.Module):
    def __init__(self, dilation=1):
        super().__init__()
        self.layers = nn.ModuleList([StreamConv(3, 4, stride=2),
                                     StreamConv(4, 4, dilation=dilation),
                                     StreamConv(4, 3, kernel=1, bn=False, activation=False)])

    def forward(self, rgb):
        x = rgb / 255.0
        for layer in self.layers:
            x = layer(x)
        return F.interpolate(x, size=rgb.shape[-2:], mode='nearest') * 255.0

def frame(path):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    if w*3 > h*4:
        nw = h*4//3
        im = im.crop(((w-nw)//2, 0, (w+nw)//2, h))
    else:
        nh = w*3//4
        im = im.crop((0, (h-nh)//2, w, (h+nh)//2))
    a = np.asarray(im.resize((640,480), Image.Resampling.BILINEAR), dtype=np.float32)
    return torch.from_numpy(a.transpose(2,0,1).copy())

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--steps', type=int, default=6000)
    p.add_argument('--batch', type=int, default=8)
    p.add_argument('--device', default='cuda')
    p.add_argument('--resume', action='store_true')
    p.add_argument('--candidate', choices=list(CANDIDATES))
    a = p.parse_args()
    torch.set_num_threads(4)
    torch.manual_seed(20261008)
    rng = random.Random(20261008)
    out = ROOT/'build/stream'
    out.mkdir(parents=True, exist_ok=True)
    splits = dataset()
    manifest = {'seed': 20261008, 'teacher_sha256': hashlib.sha256(MODEL.read_bytes()).hexdigest(),
                'target': 'existing quantized teacher reconstruction extended to 640x480',
                'splits': {k:[{'name':f.name, 'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in fs] for k,fs in splits.items()}}
    cache_manifest = {'teacher_sha256':manifest['teacher_sha256'],
                      'teacher_source_sha256':hashlib.sha256(inspect.getsource(Teacher).encode()).hexdigest(),
                      'frame_source_sha256':hashlib.sha256(inspect.getsource(frame).encode()).hexdigest(),
                      'train':manifest['splits']['train']}
    cache_manifest_path = out/'target-cache-manifest.json'
    if cache_manifest_path.exists():
        if json.loads(cache_manifest_path.read_text()) != cache_manifest:
            raise RuntimeError('Teacher target cache provenance changed; use a separate cache directory')
    elif any(out.glob('*-target.npy')):
        raise RuntimeError('Existing teacher cache has no provenance manifest')
    else:
        cache_manifest_path.write_text(json.dumps(cache_manifest,indent=2)+'\n')
    (out/'data-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    teacher = Teacher().to(a.device).eval()
    validate_teacher(teacher, a.device, out)
    pairs = []
    for k, path in enumerate(splits['train']):
        x = frame(path).to(a.device)[None]
        cache = out/(path.stem+'-target.npy')
        if cache.exists():
            y = torch.from_numpy(np.load(cache)).to(a.device)
        else:
            with torch.no_grad(): y = teacher(x).clamp(0,255)[0]
            np.save(cache, y.cpu().numpy().astype(np.float32))
        # Cached targets are bound to the fixed manifest in this directory.
        pairs.append((x[0], y))
        if k%10 == 0: print('teacher train pairs',k,flush=True)
    del teacher
    models, opts, start = {}, {}, 0
    for name, dilation in CANDIDATES.items():
        if a.candidate and a.candidate != name: continue
        model = StreamStudent(dilation).to(a.device)
        if a.resume:
            old = torch.load(out/(name+'.pt'),map_location=a.device,weights_only=True)
            if old['teacher_sha256'] != manifest['teacher_sha256']: raise RuntimeError('teacher changed')
            model.load_state_dict(old['state_dict'])
            start = old['step']+1
        models[name] = model
        opts[name] = torch.optim.Adam(model.parameters(),lr=7e-4)
    begin = time.monotonic()
    for step in range(start, start+a.steps):
        xs, ys = [], []
        for _ in range(a.batch):
            x,y = rng.choice(pairs)
            top,left = rng.randrange(0,480-192+1,4),rng.randrange(0,640-192+1,4)
            x,y = x[:,top:top+192,left:left+192],y[:,top:top+192,left:left+192]
            if rng.random()<.5: x,y = x.flip(-1),y.flip(-1)
            xs.append(x);ys.append(y)
        x,y = torch.stack(xs),torch.stack(ys)/255
        weight = 1+3*(1-y.mean(1,keepdim=True))
        losses = {}
        for name, model in models.items():
            opt = opts[name]
            # Reduce LR for final contour refinement.
            for group in opt.param_groups: group['lr'] = 7e-4 if step-start<a.steps*.7 else 2e-4
            opt.zero_grad(set_to_none=True)
            pred = model(x)/255
            # Crop edges have different context than full-frame targets.
            pp, yy, ww = pred[:,:,8:-8,8:-8],y[:,:,8:-8,8:-8],weight[:,:,8:-8,8:-8]
            loss = ((pp-yy).abs()*ww).mean()
            for axis in (-1,-2):
                loss += .6*F.l1_loss(torch.diff(pp,dim=axis),torch.diff(yy,dim=axis))
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(),1)
            opt.step()
            losses[name] = float(loss.detach())
        if step%100 == 0:
            print(json.dumps({'step':step,'elapsed_s':round(time.monotonic()-begin,2),'loss':losses}),flush=True)
        if (step+1)%500 == 0 or step==start+a.steps-1:
            for name, model in models.items():
                torch.save({'state_dict':model.state_dict(),'candidate':name,'dilation':CANDIDATES[name],
                            'step':step,'teacher_sha256':manifest['teacher_sha256'],
                            'data_manifest_sha256':hashlib.sha256((out/'data-manifest.json').read_bytes()).hexdigest()},out/(name+'.pt'))

if __name__=='__main__':
    main()
