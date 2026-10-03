#!/usr/bin/env python3
"""Decode actual HDMI lane symbols; check AVI bytes, BCH, guards and video."""
import os, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
IV=os.environ.get('IVERILOG','iverilog');LIB=os.environ.get('IVERILOG_LIB')
VVP=os.environ.get('VVP','vvp')
def sim(top,sources,path,args=(),params=()):
    subprocess.run([IV]+(['-B',LIB] if LIB else [])+['-g2012','-s',top,'-o',str(path)]+list(params)+sources,check=True,cwd=ROOT)
    subprocess.run([VVP]+(['-M',LIB] if LIB else [])+[str(path)]+list(args),check=True,cwd=ROOT)
TERC=[0x29c,0x263,0x2e4,0x2e2,0x171,0x11e,0x18e,0x13c,0x2cc,0x139,0x19c,0x2c6,0x28e,0x271,0x163,0x2c3]
def decode_video(symbol):
    q=(symbol&255)^(255 if symbol&512 else 0)
    result=q&1
    for k in range(1,8):result|=(((q>>k)^(q>>(k-1))^(0 if symbol&256 else 1))&1)<<k
    return result
def check_bch(word,n):
    # Recompute the syndrome over data AND the appended parity, LSB first.
    state=0
    for k in range(n):
        feedback=(state^(word>>k))&1
        state>>=1
        if feedback:state^=0x83
    assert state==0,f'Bad BCH syndrome: {state:02x}'
with tempfile.TemporaryDirectory(prefix='iris-hdmi420-') as d:
    p=Path(d)
    rgbtrace=p/'rgb.trace'
    sim('tb_rgb_709',['tests/video/tb_rgb_709.sv','iris_ws/src/hdmi/rgb_to_ycbcr709.v'],p/'rgb',[f'+TRACE={rgbtrace}'])
    rgb_samples=rgbtrace.read_text().splitlines()
    assert len(rgb_samples)==1536
    for line in rgb_samples:
        a,b=(int(x,16) for x in line.split())
        r,g,bl=((a>>k)&255 for k in (16,8,0));yy,cb,cr=((b>>k)&255 for k in (16,8,0))
        ref=(16+219*(.2126*r+.7152*g+.0722*bl)/255,
             128+224*(-.114572*r-.385428*g+.5*bl)/255,
             128+224*(.5*r-.454153*g-.045847*bl)/255)
        assert 16<=yy<=235 and 16<=cb<=240 and 16<=cr<=240
        assert all(abs(v-round(w))<=1 for v,w in zip((yy,cb,cr),ref)),(a,b,ref)
        if r==g==bl:assert cb==cr==128,'Neutral white balance changed'
    print('PASS BT709: 1536 grey/primary/yellow/mixed samples vs floating-point standard, limited ranges and neutral colours')
    sim('tb_upscale_420',['tests/video/tb_upscale_420.sv','iris_ws/src/hdmi/upscale_420.v','iris_ws/src/hdmi/rgb_to_ycbcr709.v'],p/'scale')
    sim('tb_video_mode_commit',['tests/video/tb_video_mode_commit.sv','iris_ws/src/hdmi/video_mode_commit.v'],p/'mode')
    sim('tb_sensor_telemetry',['tests/video/tb_sensor_telemetry.sv','iris_ws/src/video/osd/clock_frequency_meter.v','iris_ws/src/uart/ae_uart_log.v','iris_ws/src/uart/uart_tx.v'],p/'telemetry',params=['-Ptb_sensor_telemetry.VIDEO=1'])
    trace=p/'trace'
    sim('tb_hdmi_420_packet',['tests/video/tb_hdmi_420_packet.sv','iris_ws/src/hdmi/hdmi_420_tx.v','iris_ws/src/hdmi/encode.v'],p/'packet',[f'+TRACE={trace}'])
    samples={}
    for line in trace.read_text().splitlines():
        x,y,a,b,c=line.split();samples[int(y),int(x)]=tuple(int(v,16) for v in (a,b,c))
    hdr=0;sub=[0]*4
    for x in range(74,106):
        a,b,c=(TERC.index(v) for v in samples[0,x]);i=x-74
        assert a&3==2 and a&8,'Data-island sync/reserved bit'
        hdr|=((a>>2)&1)<<i
        for k in range(4):sub[k]|=((b>>k)&1)<<(2*i)|((c>>k)&1)<<(2*i+1)
    check_bch(hdr,32)
    for word in sub:check_bch(word,64)
    h=[(hdr>>(8*k))&255 for k in range(3)]
    pb=[(sub[k//7]>>(8*(k%7)))&255 for k in range(28)]
    assert h==[0x82,3,13],h
    assert sum(h+pb[:14])%256==0,'AVI checksum'
    assert pb[1]>>5==3 and pb[2]>>6==2 and pb[4]==95 and pb[5]>>6==0,pb
    assert all(v==0 for v in pb[6:]),'Reserved packet bytes'
    for x in range(64,72):assert samples[0,x][1:]==(0x0ab,0x0ab),'Island preamble'
    for x in [72,73,106,107]:assert samples[0,x]==(0x163,0x133,0x133),'Island guards'
    for x in range(182,190):assert samples[82,x][1:]==(0x0ab,0x354),'Video preamble'
    for x in [190,191]:assert samples[82,x]==(0x2cc,0x133,0x2cc),'Video guards'
    for x in range(192,2112):assert tuple(decode_video(v) for v in samples[82,x])==(128,235,235),f'Video packing {x}'
    print('PASS HDMI420: decoded AVI v3/VIC95/BT709/limited range, checksum and five BCH blocks, TERC4, preambles, guard bands, all 1920 video words')
