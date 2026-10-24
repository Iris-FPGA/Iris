#!/usr/bin/env python3
"""Verify the bundled Sapphire SPI receive timing, including its negative control."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT/'iris_ws/ip/SapphireSoc/source/hardware/netlist/EfxSapphireSoc.v').read_text()
# The full generated SoC includes vendor-only syntax unrelated to this test.
# Extract its complete SPI controller verbatim, without changing its logic.
source = source[source.index('module TopLevel ('):]
source = source[:source.index('endmodule')+len('endmodule')]
with tempfile.TemporaryDirectory(prefix='iris-boot-spi-') as tmp:
    folder = Path(tmp)
    core = folder/'spi.v'
    core.write_text(source+'\n')
    for delay in (0,3):
        executable = folder/f'spi-{delay}'
        subprocess.run([os.environ.get('IVERILOG','iverilog'),'-g2012',
                        '-s','tb_style_boot_spi',f'-Ptb_style_boot_spi.LATENCY={delay}',
                        '-o',str(executable),str(ROOT/'tests/video/tb_style_boot_spi.sv'),
                        str(core)],check=True)
        subprocess.run([os.environ.get('VVP','vvp'),str(executable)],check=True)
print('PASS Flash SPI: raw input reproduces DEC02E; 3-clock retiming reads EF6017')
