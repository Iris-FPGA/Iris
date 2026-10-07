"""Apply documented Sapphire CLI options absent from its Standard-mode GUI.

The Java generator and encrypted CPU modules are unchanged. Efinity's own
combine_rtl performs IP UUID rewriting. Only the small integration wrapper
adapts the removed memory clock/reset ports to a single system clock.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


def apply_options(project, name):
    ip = project / 'ip' / name
    options_file = ip / 'iris_generator_options.json'
    if not options_file.exists():
        return
    options = json.loads(options_file.read_text())
    if set(options) != {'single_memory_clock', 'low_area'} or not 0 <= options['low_area'] <= 10:
        raise ValueError('Unsupported Sapphire CLI options')
    # Caller must connect memory and system to the same clock; this project's
    # tinyml_subsystem does so. Do not apply this option to a multi-clock SoC.
    settings = json.loads((ip / 'settings.json').read_text())['conf']
    if settings['SOC_MODE'] != '0' or settings['Cache'] != "1'b1":
        raise ValueError('Iris CLI adaptation requires cached Standard CPU')
    root = Path(os.environ['EFINITY_HOME']) / 'ipm/ip/efx_soc/efx_soc'
    jar = root / 'generator/EfxSapphireSoc.jar'
    args = shlex.split((ip / 'source/soc_config').read_text())
    extra = ['--lowArea', str(options['low_area'])]
    if options['single_memory_clock']:
        extra += ['--noDdrAClock']
    from efx_ipmgr.builder import combine_rtl
    with tempfile.TemporaryDirectory(prefix='iris-sapphire-cli-') as temporary:
        work = Path(temporary)
        (work / 'bsp/efinix/EfxSapphireSoc').mkdir(parents=True)
        (work / 'hardware/netlist').mkdir(parents=True)
        command = ['java', '-cp', str(jar), 'saxon.board.efinix.EfxSapphireSoc'] + args + extra
        subprocess.run(command, cwd=work, check=True)
        generated = work / 'hardware/netlist'
        plain = (generated / 'EfxSapphireSoc.v').read_text()
        required = ('cpu0_customInstruction_cmd_valid', 'cpu0_customInstruction_rsp_valid')
        if not all(port in plain for port in required):
            raise ValueError('Official generator removed required custom interface')
        if options['single_memory_clock'] and re.search(r'input\s+wire\s+io_memoryClk\b', plain):
            raise ValueError('Official single-clock option was not applied')
        for platform in ('efinity', 'modelsim', 'aldec', 'ncsim', 'synopsys'):
            target = ip / 'source/hardware/netlist' / ('source_' + platform)
            target.mkdir(parents=True, exist_ok=True)
            # Same licensed encrypted-module append as official soc_gen.py.
            encrypted = ''.join((root / ('source_' + platform) / module).read_text()
                                for module in ('EfxCPUSp1.v', 'EfxCPUSp2.v'))
            (target / 'EfxSapphireSoc.v').write_text(plain + '\n' + encrypted)
        combined_source = ip / 'source/hardware/netlist/source_efinity/EfxSapphireSoc.v'
        shutil.copy2(combined_source, ip / 'source/hardware/netlist/EfxSapphireSoc.v')
        current = (ip / (name + '.v')).read_text()
        prefix = current[:current.index('endmodule') + len('endmodule')]
        suffix = re.search(r'`define IP_UUID _([a-f0-9]+)', prefix)[1]
        if options['single_memory_clock']:
            for port in ('io_memoryClk', 'io_memoryReset'):
                prefix = re.sub(r'^\s*\.' + port + r'\s*\([^\n]+\),?\s*\n', '', prefix, flags=re.M)
            prefix = prefix.replace('`IP_MODULE_NAME(EfxSapphireSoc)u_EfxSapphireSoc',
                                    'assign io_memoryReset = io_systemReset;\n'
                                    '`IP_MODULE_NAME(EfxSapphireSoc)u_EfxSapphireSoc')
        _, rtl, sv = combine_rtl([{'name': str(combined_source), 'fileType': 'verilogSource'}], suffix, 'v')
        (ip / (name + '.v')).write_text(prefix + '\n\n' + rtl + sv)
        for artifact in generated.glob('*.bin'):
            shutil.copy2(artifact, ip / artifact.name)
            shutil.copy2(artifact, ip / 'source/hardware/netlist' / artifact.name)
        shutil.copy2(generated / 'EfxSapphireSoc_io_cd.rpt', ip / 'source/hardware/netlist/EfxSapphireSoc_io_cd.rpt')
        for artifact in (work / 'bsp/efinix/EfxSapphireSoc/include').iterdir():
            if artifact.is_file():
                shutil.copy2(artifact, project / 'embedded_sw' / name / 'bsp/efinix/EfxSapphireSoc/include' / artifact.name)
        shutil.copy2(work / 'cpu0.yaml', project / 'embedded_sw' / name / 'cpu0.yaml')
        # Preserve the complete reproducible command, including GUI-absent flags.
        (ip / 'source/soc_config').write_text('\n'.join(shlex.join([arg]) for arg in args + extra) + '\n')
        manifest = {'options': options, 'official_jar_sha256': hashlib.sha256(jar.read_bytes()).hexdigest(),
                    'command': command, 'netlist_sha256': hashlib.sha256(plain.encode()).hexdigest(),
                    'wrapper_adaptation': 'single-clock reset alias; official combine_rtl UUID rewriting',
                    'generated_ip_sha256': hashlib.sha256((ip / (name + '.v')).read_bytes()).hexdigest()}
        (ip / 'iris_generator_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print('[gen] applied official CLI options:', extra)
