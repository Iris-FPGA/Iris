#!/usr/bin/env python3
"""RTL regression fixtures are independent scalar Bayer/RGB reference models."""
import os, subprocess, tempfile
import random
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
    # Independent C-style division reference for gemmlowp double rounding.
    rng=random.Random(20261008);quant_in=[];quant_ref=[]
    for j in range(8192):
        cases=[-2147483648,-2147483647,-1073741824,-1025,-1024,-3,-2,-1,0,1,2,3,1024,1025,1073741824,2147483647]
        value=cases[j%len(cases)] if j<2048 else rng.randrange(-2147483648,2147483648)
        mult=[0,1073741824,2147483647,536870912][j%4] if j<2048 else rng.randrange(0,2147483648)
        shift=-(j//4%32);zero=[-128,0,127][j%3];lo,hi=-128,127
        product=value*mult;nudge=(1<<30) if product>=0 else 1-(1<<30)
        num=product+nudge;high=(abs(num)//(1<<31))*(-1 if num<0 else 1)
        divisor=1<<(-shift)
        # Nearest division, ties away from zero. This does not use the RTL
        # mask/remainder implementation or its signed-shift expression.
        rounded=((abs(high)+divisor//2)//divisor)*(-1 if high<0 else 1) if shift else high
        expected=min(hi,max(lo,rounded+zero))
        packed=((value&0xffffffff)<<64)|(mult<<32)|((shift&255)<<24)|((zero&255)<<16)|((lo&255)<<8)|hi
        quant_in.append(packed);quant_ref.append(expected&255)
    qi=tmp/'cnn-quant-in.mem';qr=tmp/'cnn-quant-ref.mem';qe=tmp/'cnn-quant'
    qi.write_text(''.join(f'{v:024x}\n' for v in quant_in));qr.write_text(''.join(f'{v:02x}\n' for v in quant_ref))
    compile_tb('tb_cnn_requant',['tests/video/tb_cnn_requant.sv','iris_ws/src/cnn/iris_stream_conv.v'],qe)
    simulate(qe,[f'+IN={qi}',f'+REF={qr}'])
    stream=tmp/'stream_cnn'
    compile_tb('tb_stream_cnn',['tests/video/tb_stream_cnn.sv','iris_ws/src/cnn/iris_stream_conv.v'],stream)
    simulate(stream,['+DIR='+str(ROOT/'tests/video/fixtures/stream_d2')])
    stream_dma=tmp/'stream_dma'
    compile_tb('tb_stream_cnn_dma',['tests/video/tb_stream_cnn_dma.sv','iris_ws/src/cnn/iris_stream_conv.v','iris_ws/src/cnn/iris_stream_cnn.v'],stream_dma)
    simulate(stream_dma,['+DIR='+str(ROOT/'tests/video/fixtures/stream_d2')])
    stream_integration=tmp/'stream_subsystem'
    run([IV]+(['-B',IVLIB] if IVLIB else [])+['-g2012','-i','-s','tb_stream_subsystem','-o',str(stream_integration),
        'tests/video/tb_stream_subsystem.sv','iris_ws/src/cnn/tinyml_subsystem.v','iris_ws/src/cnn/iris_resize2x.v',
        'iris_ws/src/cnn/iris_stream_conv.v','iris_ws/src/cnn/iris_stream_cnn.v'])
    simulate(stream_integration)
    observer=tmp/'accel_observer'
    compile_tb('tb_accel_observer',['tests/video/tb_accel_observer.sv','iris_ws/src/cnn/tinyml_subsystem.v'],observer);simulate(observer)
    capture=tmp/'style_capture'
    compile_tb('tb_style_capture',['tests/video/tb_style_capture.sv','iris_ws/src/cnn/iris_style_capture.v','iris_ws/src/video/afifo_simple.v'],capture);simulate(capture)
    mux=tmp/'cpu_style_mux'
    compile_tb('tb_cpu_style_mux',['tests/video/tb_cpu_style_mux.sv','iris_ws/src/ddr/axi_cpu_style_mux.v'],mux);simulate(mux)
    for negative in (0,1):
        panels=tmp/f'style_panels_{negative}'
        run([IV]+(['-B',IVLIB] if IVLIB else [])+['-g2012','-s','tb_style_panels',f'-Ptb_style_panels.NEGATIVE={negative}','-o',str(panels),'tests/video/tb_style_panels.sv','iris_ws/src/cnn/iris_style_panels.v','iris_ws/src/cnn/iris_style_dequant.v'])
        simulate(panels)
    preprocess=tmp/'style_preprocess'
    compile_tb('tb_style_preprocess',['tests/video/tb_style_preprocess.sv','iris_ws/src/cnn/iris_style_preprocess.v'],preprocess);simulate(preprocess)
    dequant=tmp/'style_dequant';di=tmp/'dequant-in.mem';dr=tmp/'dequant-ref.mem'
    # Independent IEEE floating point oracle for both exported model scales.
    for scale,q24 in [(1.2273634672164917,20591742),(1.2276244163513184,20596120)]:
        stim=[];ref=[]
        for v in range(1024):
            codes=[v%256,(v*17+43)%256,(v*37+89)%256]
            dummy=(v*71)%256;valid=int(v%9!=0)
            packed=(dummy<<24)|sum((c^128)<<(8*j) for j,c in enumerate(codes))
            rgb=0
            for c in codes:rgb=(rgb<<8)|min(255,int(c*scale+.5))
            stim.append((valid<<32)|packed);ref.append((valid<<24)|rgb)
        di.write_text(''.join(f'{v:09x}\n' for v in stim));dr.write_text(''.join(f'{v:07x}\n' for v in ref))
        run([IV]+(['-B',IVLIB] if IVLIB else [])+['-g2012','-s','tb_style_dequant',
             f'-Ptb_style_dequant.SCALE_Q24={q24}','-o',str(dequant),
             'tests/video/tb_style_dequant.sv','iris_ws/src/cnn/iris_style_dequant.v'])
        simulate(dequant,[f'+IN={di}',f'+REF={dr}'])
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
        u=12.92*z if z<=.0031308 else 1.055*z**(1/2.4)-.055
        return round(255*(u+.16*u*(1-u)*(2*u-1)))
    gains=[128,192,255,256,257,320,448,768]
    for gain in gains:
        for v in range(256):
            channels=[v,(v*3)%256,255-v,255-v,v,(v*7)%256]
            # Include neutral greys at unity, black-offset boundaries and gain precision.
            if gain==256:channels=[v]*6
            codes=[gain,256,1024-gain]*2
            codes=[256]*6 if gain==256 else [min(768,c) for c in codes]
            blacks=[0,(v%5)*4,32] if gain!=256 else [0]*3
            rgb=0;out=0;toned=[]
            sync=((v%7==0)<<2)|((v%13==0)<<1)|(v%5!=0)
            for k,(ch,c) in enumerate(zip(channels,codes)):
                rgb=(rgb<<8)|ch
                toned.append(gamma(min(255,(max(0,ch-blacks[k%3])*c+128)//256)))
            for pixel in [toned[:3],toned[3:]]:
                y=(pixel[0]+2*pixel[1]+pixel[2]+2)//4
                for ch in pixel:out=(out<<8)|max(0,min(255,(5*ch-y+2)//4))
            packed=(sync<<102)|(rgb<<54)|(codes[0]<<44)|(codes[1]<<34)|(codes[2]<<24)|(blacks[0]<<16)|(blacks[1]<<8)|blacks[2]
            sv.append(packed);rv.append((sync<<48)|out)
    a.write_text(''.join(f'{v:027x}\n' for v in sv));b.write_text(''.join(f'{v:013x}\n' for v in rv))
    compile_tb('tb_display',['tests/video/tb_display.sv','iris_ws/src/video/debayer/rgb_display_2px.v'],exe);simulate(exe,[f'+IN={a}',f'+REF={b}'])
    exe=tmp/'osd'
    compile_tb('tb_osd',['tests/video/tb_osd.sv','iris_ws/src/video/osd/osd_video_status.v'],exe);simulate(exe)
    exe=tmp/'style_fps'
    compile_tb('tb_style_fps',['tests/video/tb_style_fps.sv','iris_ws/src/video/osd/osd_video_status.v','iris_ws/src/video/osd/fps_counter.v'],exe);simulate(exe)
    exe=tmp/'banks'
    compile_tb('tb_frame_banks',['tests/video/tb_frame_banks.sv','iris_ws/src/ddr/fb/frame_bank_manager.v'],exe);simulate(exe)
    exe=tmp/'write_commit'
    compile_tb('tb_write_commit',['tests/video/tb_write_commit.sv','iris_ws/src/ddr/fb/ddr_wr_buffer.v','iris_ws/src/ddr/fb/frame_bank_manager.v'],exe);simulate(exe)
    exe=tmp/'ae'
    compile_tb('tb_ae_exposure',['tests/video/tb_ae_exposure.sv','iris_ws/src/mipi/ae_ctrl.v'],exe);simulate(exe)
    exe=tmp/'white_balance'
    compile_tb('tb_white_balance',['tests/video/tb_white_balance.sv','iris_ws/src/video/debayer/awb_ctrl.v','iris_ws/src/video/debayer/awb_stats.v'],exe);simulate(exe)
    exe=tmp/'sensor_telemetry'
    compile_tb('tb_sensor_telemetry',['tests/video/tb_sensor_telemetry.sv','iris_ws/src/video/osd/clock_frequency_meter.v','iris_ws/src/uart/ae_uart_log.v','iris_ws/src/uart/uart_tx.v'],exe);simulate(exe)
    exe=tmp/'sensor_readback'
    compile_tb('tb_sensor_readback',['tests/video/tb_sensor_readback.sv','iris_ws/src/i2c/i2c_subsystem.v'],exe);simulate(exe)
    exe=tmp/'sensor_mode'
    compile_tb('tb_sensor_mode',['tests/video/tb_sensor_mode.sv','iris_ws/src/mipi/sc431hai_i2c_rom.v','iris_ws/src/i2c/i2c_master_reg_set.v'],exe);simulate(exe)
    exe=tmp/'ae_osd'
    compile_tb('tb_ae_osd_address',['tests/video/tb_ae_osd_address.sv','iris_ws/src/video/osd/osd_ae.v'],exe);simulate(exe)

    exe=tmp/'colour_capture'
    compile_tb('tb_colour_capture',['tests/video/tb_colour_capture.sv','iris_ws/src/video/debayer/colour_capture.v','iris_ws/src/uart/uart_tx.v'],exe);simulate(exe)
    exe=tmp/'axi_arbiter'
    compile_tb('tb_axi_ddr_arbiter',['tests/video/tb_axi_ddr_arbiter.sv','iris_ws/src/ddr/axi_ddr_arbiter.v'],exe);simulate(exe)
    exe=tmp/'axi_atype'
    compile_tb('tb_axi_atype_bridge',['tests/video/tb_axi_atype_bridge.sv','iris_ws/src/ddr/axi_atype_bridge.v'],exe);simulate(exe)
    exe=tmp/'axi_atype_serial'
    compile_tb('tb_axi_atype_serial',['tests/video/tb_axi_atype_serial.sv','iris_ws/src/ddr/axi_atype_bridge.v'],exe);simulate(exe)
    exe=tmp/'axi_atype_mode'
    compile_tb('tb_axi_atype_mode',['tests/video/tb_axi_atype_mode.sv','iris_ws/src/ddr/axi_atype_bridge.v'],exe);simulate(exe)
    exe=tmp/'resize2x'
    compile_tb('tb_iris_resize2x',['tests/video/tb_iris_resize2x.sv','iris_ws/src/cnn/iris_resize2x.v'],exe);simulate(exe)
    exe=tmp/'resize_integration'
    run([IV]+(['-B',IVLIB] if IVLIB else [])+['-g2012','-i','-s','tb_tinyml_resize_integration','-o',str(exe),
        'tests/video/tb_tinyml_resize_integration.sv','iris_ws/src/cnn/tinyml_subsystem.v','iris_ws/src/cnn/iris_resize2x.v'])
    simulate(exe)
