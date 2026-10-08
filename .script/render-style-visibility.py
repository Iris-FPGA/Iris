#!/usr/bin/env python3
"""Render an honest display preview from an exported, unmodified CNN output.

This is an offline reference for RTL postprocessing; it does not infer pixels or
send them to the FPGA. The model and raw neural parity remain separate.
"""
import argparse,hashlib,json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('prefix',type=Path,help='hardware UART snapshot prefix')
p.add_argument('--mode',type=int,choices=range(4),default=2)
p.add_argument('--contour',action='store_true',help='camera-guided, smoothed main contours (display ABI 2)')
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();prefix=str(a.prefix)
report=json.loads(Path(prefix+'-report.json').read_text())
raw={k:Path(prefix+'-'+k+'.bin').read_bytes() for k in ('input','output')}
for k,b in raw.items():
 assert len(b)==1228800 and hashlib.sha256(b).hexdigest()==report['snapshot_files'][k]['sha256']
source=np.frombuffer(raw['input'],np.int8).reshape(480,640,4).astype(np.int16)[:,:,:3]+128
neural=np.frombuffer(raw['output'],np.int8).reshape(480,640,4).astype(np.int16)[:,:,:3]+128
filtered=neural.copy()
if a.mode>=2 and not a.contour:
 # Min over (x,y), (x-1,y), (x,y+1), (x-1,y+1), with clamped borders.
 filtered=np.minimum(filtered,np.concatenate([neural[1:],neural[-1:]],axis=0))
 filtered=np.minimum(filtered,np.concatenate([filtered[:,:1],filtered[:,:-1]],axis=1))
scale=1.2276244163513184
original=np.clip(np.floor(neural*scale+.5),0,255).astype(np.uint8)
visible=np.clip(np.floor(filtered*scale+.5),0,255).astype(np.int16)
if a.contour and a.mode>=2:
 grey=(source[:,:,0]+2*source[:,:,1]+source[:,:,2]+2)//4
 padded=np.pad(grey,2,mode='edge').astype(np.int32)
 gx=np.zeros((480,640),np.int32);gy=gx.copy()
 weight=[1,4,6,4,1];derivative=[-1,-2,0,2,1]
 for y in range(5):
  for x in range(5):
   cell=padded[y:y+480,x:x+640]
   gx+=cell*weight[y]*derivative[x];gy+=cell*derivative[y]*weight[x]
 gradient=(np.abs(gx)+np.abs(gy)+8)//16
 threshold,gain,cap=(40,4,160) if a.mode==3 else (32,2,128)
 ink=np.clip((gradient-threshold)*gain,0,cap)
 minimum=visible.min(axis=2)
 base=255-((255-minimum+2)//4)
 visible=np.maximum(0,np.minimum(255,base[:,:,None]+visible-minimum[:,:,None])-ink[:,:,None])
elif a.mode:
 floor,gain=(20,8) if a.mode==3 else (16,4)
 ink=np.maximum(0,255-visible.min(axis=2)-floor)*gain
 visible=np.clip(visible-ink[:,:,None],0,255)
visible=visible.astype(np.uint8)
canvas=Image.new('RGB',(1920,510),(20,20,20));d=ImageDraw.Draw(canvas)
for i,(label,rgb) in enumerate([('Captured input',source.astype(np.uint8)),('Raw CNN display',original),(f'Display enhancement mode {a.mode}',visible)]):
 d.text((i*640+12,8),label,fill='white');canvas.paste(Image.fromarray(rgb),(i*640,30))
a.output.parent.mkdir(parents=True,exist_ok=True);canvas.save(a.output)
result={'scope':'offline display reference; raw CNN unmodified','raw_output_sha256':hashlib.sha256(raw['output']).hexdigest(),'mode':a.mode,'contour_guidance':a.contour,'thicken_kernel':[2,2] if a.mode>=2 and not a.contour else [1,1],'scale':scale,'preview':str(a.output)}
if a.contour and a.mode>=2:result.update(gradient_kernel='Gaussian3 convolved with Sobel3, 5x5',threshold=threshold,gain=gain,ink_cap=cap)
a.output.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
