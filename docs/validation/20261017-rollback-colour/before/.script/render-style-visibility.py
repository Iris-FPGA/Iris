#!/usr/bin/env python3
"""Render an honest display preview from an exported, unmodified CNN output.

This is an offline reference for RTL postprocessing; it does not infer pixels or
send them to the FPGA. The model and raw neural parity remain separate.
"""
import argparse,hashlib,json,re
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('prefix',type=Path,help='hardware UART snapshot prefix')
p.add_argument('--mode',type=int,choices=range(4),default=2)
p.add_argument('--contour',action='store_true',help='camera-guided, smoothed main contours (display ABI 2)')
p.add_argument('--saturation-q2',type=int,choices=range(4,17),help='CNN colour gain in quarters: 4=1x, 8=2x, 12=3x, 16=4x')
p.add_argument('--threshold',type=int,help='gradient threshold for the selected mode')
p.add_argument('--ink-gain',type=int,help='gradient gain above threshold')
p.add_argument('--ink-cap',type=int,help='maximum outline darkening, 0..255')
p.add_argument('--compare',action='store_true',help='include the previous pale contour renderer')
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
 # Read the synthesis defaults so editing the RTL also changes this preview.
 rtl=(Path(__file__).resolve().parents[1]/'iris_ws/src/cnn/iris_style_contour.v').read_text()
 def default(name):
  match=re.search(r'\bparameter\s+'+name+r'\s*=\s*(\d+)',rtl)
  if not match:raise ValueError('cannot read integer RTL parameter '+name)
  return int(match[1])
 preset='STRONG' if a.mode==3 else 'NORMAL'
 threshold=a.threshold if a.threshold is not None else default(preset+'_THRESHOLD')
 gain=a.ink_gain if a.ink_gain is not None else default(preset+'_INK_GAIN')
 cap=a.ink_cap if a.ink_cap is not None else default(preset+'_INK_CAP')
 saturation=a.saturation_q2 if a.saturation_q2 is not None else default('SATURATION_Q2')
 if threshold<0 or gain<0 or not 0<=cap<=255:p.error('threshold/gain must be nonnegative; ink-cap must be in 0..255')
 ink=np.clip((gradient-threshold)*gain,0,cap)
 old_threshold,old_gain,old_cap,old_cutoff=(40,4,160,80) if a.mode==3 else (20,2,128,96)
 old_ink=np.where(gradient<=old_threshold,0,np.where(gradient>=old_cutoff,old_cap,(gradient-old_threshold)*old_gain))
 minimum=visible.min(axis=2).astype(np.int32)
 base=255-((255-minimum+2)//4)
 previous=np.maximum(0,np.minimum(255,base[:,:,None]+visible-minimum[:,:,None])-old_ink[:,:,None]).astype(np.uint8)
 visible=visible.astype(np.int32)
 maximum=visible.max(axis=2)
 visible=np.maximum(0,maximum[:,:,None]-((maximum[:,:,None]-visible)*saturation+2)//4)
 # Bound the common darkening before subtracting: no per-channel black
 # clipping, so differences in the CNN strokes survive the contour overlay.
 visible-=np.minimum(ink,visible.min(axis=2))[:,:,None]
elif a.mode:
 floor,gain=(20,8) if a.mode==3 else (16,4)
 ink=np.maximum(0,255-visible.min(axis=2)-floor)*gain
 if a.contour:ink=np.minimum(ink,visible.min(axis=2))
 visible=np.clip(visible-ink[:,:,None],0,255)
visible=visible.astype(np.uint8)
panels=[('Captured input',source.astype(np.uint8)),('Raw CNN display',original)]
if a.compare and a.contour and a.mode>=2:panels.append(('Previous contour display',previous))
panels.append((f'Display enhancement mode {a.mode}',visible))
canvas=Image.new('RGB',(640*len(panels),510),(20,20,20));d=ImageDraw.Draw(canvas)
for i,(label,rgb) in enumerate(panels):
 d.text((i*640+12,8),label,fill='white');canvas.paste(Image.fromarray(rgb),(i*640,30))
a.output.parent.mkdir(parents=True,exist_ok=True);canvas.save(a.output)
result={'scope':'offline display reference; raw CNN unmodified','raw_output_sha256':hashlib.sha256(raw['output']).hexdigest(),'mode':a.mode,'contour_guidance':a.contour,'thicken_kernel':[2,2] if a.mode>=2 and not a.contour else [1,1],'scale':scale,'preview':str(a.output)}
if a.contour and a.mode>=2:
 result.update(gradient_kernel='Gaussian3 convolved with Sobel3, 5x5',threshold=threshold,gain=gain,ink_cap=cap,
               colour_source='CNN only',saturation_q2=saturation,colour_quantization=False,
               raw_mean_chroma=float(np.ptp(original.astype(np.int16),axis=2).mean()),
               previous_mean_chroma=float(np.ptp(previous.astype(np.int16),axis=2).mean()),
               visible_mean_chroma=float(np.ptp(visible.astype(np.int16),axis=2).mean()),
               pixels_with_chroma_loss=int(np.count_nonzero(np.ptp(visible.astype(np.int16),axis=2)<np.ptp(original.astype(np.int16),axis=2))))
a.output.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
