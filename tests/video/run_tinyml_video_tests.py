#!/usr/bin/env python3
"""Independent crop/byte, quantization and full-HD split raster oracles."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
iv=os.environ.get('IVERILOG','iverilog')
vvp=os.environ.get('VVP','vvp')
lib=os.environ.get('IVERILOG_LIB')
with tempfile.TemporaryDirectory(prefix='iris-tinyml-video-') as d:
    tmp=Path(d)
    # IEEE floating point model export; no RTL fixed-point arithmetic here.
    scale=2.283437490463257
    ref=tmp/'quant.mem'
    ref.write_text(''.join(f'{min(255,max(0,int(((q if q<128 else q-256)+89)*scale+.5))):02x}\n' for q in range(256)))
    for tb,src in [
        ('tb_iris_resize2x',['iris_ws/src/cnn/iris_resize2x.v']),
        ('tb_style_fractional',['iris_ws/src/video/osd/osd_video_status.v']),
        ('tb_tinyml_capture',['iris_ws/src/cnn/iris_tinyml_video.v','iris_ws/src/cnn/iris_style_capture.v','iris_ws/src/video/afifo_simple.v']),
        ('tb_tinyml_panels',['iris_ws/src/cnn/iris_tinyml_video.v','iris_ws/src/cnn/iris_style_dequant.v'])]:
        for burst,rgb,chunk in ([(0,0,2),(1,0,2),(1,1,2),(1,0,8),(1,1,8)] if tb=='tb_iris_resize2x' else [(None,None,None)]):
            exe=tmp/(tb+str(burst)+str(rgb)+str(chunk))
            params=[] if burst is None else [f'-P{tb}.BURST_DMA={burst}',f'-P{tb}.RGB_MODEL_ONLY={rgb}',f'-P{tb}.CHUNK_BEATS={chunk}']
            subprocess.run([iv]+(['-B',lib] if lib else [])+['-g2012','-s',tb]+params+['-o',str(exe),f'tests/video/{tb}.sv']+src,cwd=ROOT,check=True)
            subprocess.run([vvp]+(['-M',lib] if lib else [])+[str(exe),f'+REF={ref}'],cwd=ROOT,check=True)
