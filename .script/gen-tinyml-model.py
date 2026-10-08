#!/usr/bin/env python3
"""Use the pinned official Efinix Generator methods headlessly, without editing it.

Run with Efinity's bundled Python (PyQt6), QT_QPA_PLATFORM=offscreen.
Output is staged; this script does not replace the active model or FPGA config.
"""
import argparse,hashlib,importlib,json,os,re,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('model',type=Path);p.add_argument('output',type=Path)
p.add_argument('--in-parallel',type=int,default=4);p.add_argument('--out-parallel',type=int,default=4)
p.add_argument('--cache',choices=['ENABLE','DISABLE'],help='explicit official TinyML cache mode for controlled hardware comparisons')
a=p.parse_args();model=a.model.resolve();out=a.output.resolve();vendor=root.parent/'tinyml'
revision=subprocess.check_output(['git','-C',str(vendor),'rev-parse','HEAD'],text=True).strip()
if revision!='96886fa0c73e25e6218db7d0863f84677cf65138':raise SystemExit('Unexpected official TinyML revision')
generator=vendor/'tools/tinyml_generator';binary=generator/'bin/tflite'
analysis=subprocess.run([str(binary),str(model),str(a.in_parallel),str(a.out_parallel),'128'],capture_output=True,text=True,check=True)
if 'conv_depthw_std_cnt_dth:' not in analysis.stderr:raise SystemExit('Analyzer did not emit a configuration')
out.mkdir(parents=True,exist_ok=True);(out/'analyzer.log').write_text(analysis.stdout+analysis.stderr)
os.environ['QT_QPA_PLATFORM']='offscreen'
plugins=Path(sys.executable).resolve().parents[1]/'lib/plugins/platforms'
if plugins.is_dir(): os.environ.setdefault('QT_QPA_PLATFORM_PLUGIN_PATH',str(plugins))
os.chdir(generator);sys.path.insert(0,str(generator))
mod=importlib.import_module('tinyml_generator');mod.app=mod.QApplication([]);w=mod.Widget()
for name,value in [('CONV_DEPTHW_STD_IN_PARALLEL',a.in_parallel),('CONV_DEPTHW_STD_OUT_PARALLEL',a.out_parallel)]:
    widget=w.findChild(mod.QObject,name)
    if widget is None:raise RuntimeError('Missing generator setting '+name)
    widget.setValue(value)
w.model_file=str(model);w.parse_model()
if a.cache:
    def setting(items,name):
        for key,value in items.items():
            if key==name:return value.get('qval')
            found=setting(value.get('children',{}),name)
            if found is not None:return found
        return None
    widget=setting(mod.params,'TINYML_CACHE')
    if widget is None or widget.findText(a.cache)<0:raise RuntimeError('Missing official cache setting')
    widget.setCurrentIndex(widget.findText(a.cache))
w.op_path=str(out);w.dump_params(mod.params);w.dump_model()
cache_match=re.search(r'`define\s+TML_C0_TINYML_CACHE\s+"(ENABLE|DISABLE)"',(out/'tinyml_core0_define.v').read_text())
if not cache_match or (a.cache and cache_match[1]!=a.cache):raise RuntimeError('Generated cache mode differs from requested setting')
(out/'generator-summary.txt').write_text(w.E.toPlainText())
manifest={'official_revision':revision,'generator_sha256':hashlib.sha256((generator/'tinyml_generator.py').read_bytes()).hexdigest(),
          'model_sha256':hashlib.sha256(model.read_bytes()).hexdigest(),'model_bytes':model.stat().st_size,
          'in_parallel':a.in_parallel,'out_parallel':a.out_parallel,'axi_bits':128,
          'cache_override':a.cache,
          'generated_cache_mode':cache_match[1],
          'hardware_execution_verified':False,
          'outputs':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(out.glob('*')) if f.suffix in ['.v','.h','.cc']}}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest,indent=2))
