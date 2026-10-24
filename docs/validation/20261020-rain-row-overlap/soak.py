import hashlib,json,os,re,select,socket,statistics,termios,time
from pathlib import Path

out=Path('/mnt/mydata/Iris/dev/fastnst/docs/validation/20261020-rain-row-overlap')
fd=os.open('/dev/serial/by-id/usb-FTDI_Quad_RS232-HS-if02-port0',os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
attr=termios.tcgetattr(fd);attr[0]=attr[1]=attr[3]=0
attr[2]=termios.CS8|termios.CLOCAL|termios.CREAD;attr[4]=attr[5]=termios.B115200
attr[6][termios.VMIN]=attr[6][termios.VTIME]=0
termios.tcsetattr(fd,termios.TCSANOW,attr);termios.tcflush(fd,termios.TCIFLUSH)
pattern=re.compile(rb'IRIS LIVE frame=(\d+) pair=(\d+) Invoke_ticks=(\d+) displayed=(\d+) captures=(\d+) underflow=(\d+) readerr=(\d+) rejects=(\d+) period_ticks=(\d+)')
raw=bytearray();pending=bytearray();frames=[];uart_gaps=[];total_frames=0;begin=time.monotonic()
try:
    while len(frames)<3600 and time.monotonic()-begin<180:
        if select.select([fd],[],[],.25)[0]:
            data=os.read(fd,65536);raw.extend(data);pending.extend(data)
            while b'\n' in pending:
                line,_,rest=pending.partition(b'\n');pending=bytearray(rest)
                if b'IRIS STOP:' in line:raise RuntimeError(line)
                m=pattern.search(line)
                if m:
                    f=list(map(int,m.groups()));total_frames+=1
                    if frames and f[0]!=frames[-1][0]+1:
                        uart_gaps.append([frames[-1][0],f[0]])
                        frames=[]
                    frames.append(f)
    periods=[f[8] for f in frames];invokes=[f[2] for f in frames]
    report=dict(frames=len(frames),total_uart_frames=total_frames,initial_uart_gaps=uart_gaps,
        first_sequence=frames[0][0],last_sequence=frames[-1][0],
        consecutive_sequences=all(b[0]==a[0]+1 for a,b in zip(frames,frames[1:])),
        fresh_fps=1e8/statistics.mean(periods),period_ticks_min=min(periods),period_ticks_max=max(periods),
        period_ticks_mean=statistics.mean(periods),invoke_ticks_median=statistics.median(invokes),
        invoke_ticks_max=max(invokes),underflow=max(f[5] for f in frames),readerr=max(f[6] for f in frames),
        rejects=max(f[7] for f in frames),elapsed_seconds=time.monotonic()-begin,
        measurement='100 MHz CLINT between VS-acknowledged new complete frame commits; UART receipt timing unused',
        cpu_reloaded=False,flash_written=False)
    # Freeze the CPU only while dumping the matching displayed input/output.
    with socket.create_connection(('localhost',6666),timeout=60) as connection:
        def tcl(command):
            connection.sendall(command.encode()+b'\x1a');data=bytearray()
            while b'\x1a' not in data:
                chunk=connection.recv(65536)
                if not chunk:raise RuntimeError('OpenOCD disconnected')
                data.extend(chunk)
            return data.decode(errors='replace').rstrip('\x1a')
        tcl('halt')
        try:
            registers=[int(v,16) for line in tcl('mdw 0xf8100000 23').splitlines()
                       if re.match(r'^0x[0-9a-f]+:',line) for v in line.split(':',1)[1].split()]
            if not registers[19]&4:raise RuntimeError('no displayed pair')
            pair=registers[19]&3;report['dump_pair']=pair;report['apb_registers']=registers;report['files']={}
            for label,base in [('input',(0x3000000,0x3200000,0x3800000)[pair]),('output',(0x3400000,0x3600000,0x3a00000)[pair])]:
                path=out/('soak-'+label+'.bin');tcl('dump_image {'+str(path)+'} '+hex(base)+' 49152')
                if path.stat().st_size!=49152:raise RuntimeError('incomplete dump')
                report['files'][label]=dict(path=str(path),bytes=49152,sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        finally:tcl('resume');report['cpu_left_running']=True
    report['passed']=len(frames)>=3600 and report['consecutive_sequences'] and report['fresh_fps']>=30 and not (report['underflow'] or report['readerr'] or report['rejects'])
    (out/'soak-report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2),flush=True)
    if not report['passed']:raise RuntimeError('soak acceptance failed')
finally:
    os.close(fd);(out/'soak-uart.log').write_bytes(raw)
