#!/usr/bin/env python3
"""RTL regression fixtures are independent scalar Bayer/RGB reference models."""
import os, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
IV=os.environ.get('IVERILOG','iverilog')
VVP=os.environ.get('VVP','vvp')
IVLIB=os.environ.get('IVERILOG_LIB')
W,H,HT,VT=16,8,12,12

def run(cmd): subprocess.run(cmd,check=True,cwd=ROOT)
def compile_tb(name,sources,out):
    run([IV]+(['-B',IVLIB] if IVLIB else [])+['-g2012','-s',name,'-o',str(out)]+sources)
def simulate(exe,args=()): run([VVP]+(['-M',IVLIB] if IVLIB else [])+[str(exe)]+list(args))

def fixture(kind,tmp,bggr=False):
    if kind=='colour':
        image=[[(180,97,41) for x in range(W)] for y in range(H)]
    elif kind=='ramp':
        image=[[(30+7*x+2*y,50+5*x+3*y,70+3*x+4*y) for x in range(W)] for y in range(H)]
    else:
        image=[[(255 if (x//4+y//2)%2 else 0,)*3 for x in range(W)] for y in range(H)]
    raw=[[image[y][x][(2 if bggr else 0) if y%2==0 and x%2==0 else (0 if bggr else 2) if y%2==1 and x%2==1 else 1] for x in range(W)] for y in range(H)]
    def cell(x,y):
        if x<0:x=1
        if x>=W:x=W-2
        if y<0:y=1
        if y>=H:y=H-2
        return raw[y][x]
    def avg(coords):return (sum(cell(x,y) for x,y in coords)+len(coords)//2)//len(coords)
    def rgb(x,y):
        horiz=[(x-1,y),(x+1,y)];vert=[(x,y-1),(x,y+1)]
        cross=horiz+vert;diag=[(x-1,y-1),(x+1,y-1),(x-1,y+1),(x+1,y+1)]
        if y%2==0 and x%2==0:return (cell(x,y),avg(cross),avg(diag))
        if y%2 and x%2:return (avg(diag),avg(cross),cell(x,y))
        if y%2==0:return (avg(horiz),cell(x,y),avg(vert))
        return (avg(vert),cell(x,y),avg(horiz))
    stim=[]
    for y in range(VT):
        for x in range(HT):
            hs=x<1;vs=y<1;de=2<=y<2+H and 2<=x<2+W//2
            pair=0
            if de:pair=(raw[y-2][2*(x-2)]<<8)|raw[y-2][2*(x-2)+1]
            stim.append((int(hs)<<18)|(int(vs)<<17)|(int(de)<<16)|pair)
    expected=[]
    for y in range(H):
        for x in range(0,W,2):
            value=0
            for c in ((rgb(x,y)[::-1]+rgb(x+1,y)[::-1]) if bggr else (rgb(x,y)+rgb(x+1,y))):value=(value<<8)|c
            expected.append(value)
    a=tmp/(kind+'_in.mem');b=tmp/(kind+'_ref.mem')
    a.write_text(''.join(f'{v:05x}\n' for v in stim));b.write_text(''.join(f'{v:012x}\n' for v in expected))
    return [f'+IN={a}',f'+REF={b}']
with tempfile.TemporaryDirectory(prefix='iris-video-tests-') as d:
    tmp=Path(d);exe=tmp/'debayer'
    compile_tb('tb_debayer',['tests/video/tb_debayer.sv','iris_ws/src/video/debayer/debayer_top_2to1.v'],exe)
    for kind in ['colour','ramp','edges']:
        print('Checking',kind,flush=True);simulate(exe,fixture(kind,tmp))
    exe=tmp/'bggr'
    run([IV]+(['-B',IVLIB] if IVLIB else [])+['-g2012','-s','tb_debayer','-Ptb_debayer.BGGR=1','-o',str(exe),'tests/video/tb_debayer.sv','iris_ws/src/video/debayer/debayer_top_2to1.v'])
    for kind in ['colour','ramp','edges']:simulate(exe,fixture(kind,tmp,True))
    exe=tmp/'size'
    compile_tb('tb_size_meter',['tests/video/tb_size_meter.sv','iris_ws/src/video/osd/video_size_meter.v'],exe);simulate(exe)
    exe=tmp/'display';a=tmp/'display_in.mem';b=tmp/'display_ref.mem';sv=[];rv=[]
    def gamma(v):
        z=v/255
        return round(255*(12.92*z if z<=.0031308 else 1.055*z**(1/2.4)-.055))
    for gain in range(2,8):
        for v in range(256):
            channels=[v,(v*3)%256,255-v,255-v,v,(v*7)%256]
            codes=[gain,4,9-gain,gain,4,9-gain];rgb=0;out=0
            sync=((v%7==0)<<2)|((v%13==0)<<1)|(v%5!=0)
            for ch,c in zip(channels,codes):rgb=(rgb<<8)|ch;out=(out<<8)|gamma(min(255,(ch*c+2)//4))
            packed=(sync<<57)|(rgb<<9)|(gain<<6)|(4<<3)|(9-gain)
            sv.append(packed);rv.append((sync<<48)|out)
    a.write_text(''.join(f'{v:015x}\n' for v in sv));b.write_text(''.join(f'{v:013x}\n' for v in rv))
    compile_tb('tb_display',['tests/video/tb_display.sv','iris_ws/src/video/debayer/rgb_display_2px.v'],exe);simulate(exe,[f'+IN={a}',f'+REF={b}'])
    exe=tmp/'osd'
    compile_tb('tb_osd',['tests/video/tb_osd.sv','iris_ws/src/video/osd/osd_video_status.v'],exe);simulate(exe)
    exe=tmp/'banks'
    compile_tb('tb_frame_banks',['tests/video/tb_frame_banks.sv','iris_ws/src/ddr/fb/frame_bank_manager.v'],exe);simulate(exe)
    exe=tmp/'write_commit'
    compile_tb('tb_write_commit',['tests/video/tb_write_commit.sv','iris_ws/src/ddr/fb/ddr_wr_buffer.v','iris_ws/src/ddr/fb/frame_bank_manager.v'],exe);simulate(exe)
    exe=tmp/'ae'
    compile_tb('tb_ae_exposure',['tests/video/tb_ae_exposure.sv','iris_ws/src/mipi/ae_ctrl.v'],exe);simulate(exe)
