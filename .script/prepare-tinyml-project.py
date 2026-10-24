#!/usr/bin/env python3
"""Copy the video project for debugger-loaded static or live RGB TinyML."""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--parameters', type=Path, required=True,
               help='directory produced by gen-tinyml-model.py')
p.add_argument('--output', type=Path, required=True,
               help='new project directory; must not already exist')
p.add_argument('--live-rgb', action='store_true', help='128x128 RGB camera + full-HD live/AI split')
p.add_argument('--burst-dma', action='store_true', help='enable the optional Iris tensor burst backend; requires --live-rgb')
p.add_argument('--rain-backend', action='store_true', help='experimental 8x8 row-cached Conv and pipelined Add; requires --live-rgb')
a = p.parse_args()
if a.burst_dma and not a.live_rgb:
    p.error('--burst-dma requires --live-rgb')
if a.rain_backend and not a.live_rgb:
    p.error('--rain-backend requires --live-rgb')
source = root / 'iris_ws'
output = a.output.resolve()
parameters = a.parameters.resolve()
manifest = json.loads((parameters / 'manifest.json').read_text())
config = parameters / 'tinyml_core0_define.v'
if hashlib.sha256(config.read_bytes()).hexdigest() != manifest['outputs'][config.name]:
    p.error('generated accelerator configuration differs from its manifest')
if output.exists() or output == source or source in output.parents:
    p.error('output must be a new directory outside the source project')
shutil.copytree(source, output,
                ignore=shutil.ignore_patterns('outflow', 'work_*', 'iris_ws.pt.sdc'))
project = output / 'iris_ws.xml'
xml = project.read_text()
for name in ('ENABLE_STYLE_DEMO', 'ENABLE_STREAM_CNN',
             'ENABLE_STYLE_VISIBILITY', 'ENABLE_STYLE_CONTOUR', 'ENABLE_TINYML_RGB',
             'ENABLE_TENSOR_BURST', 'ENABLE_RAIN_BACKEND'):
    enabled = a.live_rgb and name in ('ENABLE_STYLE_DEMO', 'ENABLE_TINYML_RGB')
    if name=='ENABLE_TENSOR_BURST': enabled=a.burst_dma
    if name=='ENABLE_RAIN_BACKEND': enabled=a.rain_backend
    xml, count = re.subn(r'(<efx:dynparam name="' + name + r'" value=")[^"]+("\s*/>)',
                        r'\g<1>' + str(int(enabled)) + r'\2', xml)
    if count != 1:
        raise RuntimeError('missing or repeated project parameter: ' + name)
project.write_text(xml)
shutil.copyfile(config, output / 'src/cnn/tinyml_core0_define.generated.v')

# JAL x0,0: wait in OCR until OpenOCD loads the matching ELF into DDR.
# This project must not start the embedded stream-CNN firmware on reset.
ram = bytes.fromhex('6f000000') + bytes(16380)
for base in (output / 'ip/SapphireSoc',
             output / 'ip/SapphireSoc/source/hardware/netlist'):
    for lane in range(4):
        target = base / f'EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol{lane}.bin'
        target.write_text(''.join(f'{value:08b}\n' for value in ram[lane::4]))

def hex_record(address, kind, data):
    record = bytes([len(data), address >> 8, address & 255, kind]) + data
    return ':' + (record + bytes([-sum(record) & 255])).hex().upper() + '\n'

boot_hex = hex_record(0, 4, bytes.fromhex('f900'))
boot_hex += hex_record(0, 0, ram[:4]) + hex_record(0, 1, b'')
(output / 'ref_files/bootloader_16MB/SapphireSoc/bootloader.hex').write_text(boot_hex)
result = {'scope': ('live camera + complete 128x128 RGB TinyML; 1920x1080 HDMI split' if a.live_rgb else
                    'static TinyML; debugger-loaded ELF; camera HDMI only'),
          'source_project': str(source), 'project': str(output),
          'model_sha256': manifest['model_sha256'],
          'accelerator_sha256': manifest['outputs'][config.name],
          'in_parallel': 8 if a.rain_backend else manifest['in_parallel'],
          'out_parallel': 8 if a.rain_backend else manifest['out_parallel'],
          'cache_depth_override': manifest.get('cache_depth_override'),
          'add_mode_override': manifest.get('add_mode_override'),
          'live_rgb': a.live_rgb,
          'tensor_burst_dma': a.burst_dma,
          'rain_row_backend': a.rain_backend,
          'tensor_resize_channels': [16,32] if a.burst_dma else [4,8,16,32],
          'tensor_copy_channels': [3,16,32] if a.burst_dma else [3,4,8,16,32],
          'source_sha256': {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                            for name in ('src/top.v','src/cnn/tinyml_subsystem.v',
                                         'src/cnn/iris_resize2x.v','src/cnn/iris_style_capture.v',
                                         'src/cnn/iris_tinyml_video.v','src/cnn/iris_style_demo.v',
                                         'src/cnn/iris_rain_conv.v','src/cnn/iris_rain_add.v',
                                         'src/cnn/iris_rain_backend.v')},
          'reset_behavior': 'OCR JAL x0,0; load ELF at 0x00800000 with OpenOCD',
          'hardware_execution_verified': False}
(output / 'tinyml-project.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
