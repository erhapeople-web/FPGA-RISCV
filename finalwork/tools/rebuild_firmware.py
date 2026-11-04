"""Re-run the original build script from a private source copy; frozen ROM stays intact."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,importlib.util,json,shutil
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser();p.add_argument('--toolchain-bin',type=Path,required=True);a=p.parse_args()
    frozen=ROOT/'firmware/coremark';original=json.loads((frozen/'build_report.json').read_text(encoding='utf8'))
    gcc=a.toolchain_bin/'riscv32-unknown-elf-gcc.exe'
    if sha(gcc)!=original['compiler_driver_sha256']:raise ValueError('Exact GCC15.2 compiler bytes required for identical firmware')
    scratch=ROOT/'build'/('firmware_'+datetime.now().strftime('%Y%m%d_%H%M%S'));shutil.copytree(frozen,scratch)
    spec=importlib.util.spec_from_file_location('original_exact_coremark_builder',scratch/'build_preparation.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);module.GCC=gcc
    origins=json.loads((scratch/'source_origins.json').read_text(encoding='utf8'))
    aliases={Path(row['source']).resolve():scratch/name for name,row in origins['origins'].items()}
    def local_sha(path):
        path=Path(path).resolve();return sha(aliases.get(path,path))
    module.sha=local_sha;module.main()
    report=json.loads((scratch/'build_report.json').read_text(encoding='utf8'))
    identity=json.loads((ROOT/'identity.json').read_text(encoding='utf8'))
    assert report['source_id']==identity['source_id']
    pairs={'firmware.bin':ROOT/'src/firmware/production.bin','firmware.hex':ROOT/'src/firmware/production.hex',
           'firmware_init.vh':ROOT/'src/firmware/firmware_init.vh','firmware.elf':ROOT/'firmware/coremark.elf'}
    hashes={}
    for name,frozen_path in pairs.items():
        new=Path(report['artifacts'][name]['path']);assert sha(new)==sha(frozen_path),name;hashes[name]=sha(new)
    result=dict(passed=True,all_four_artifacts_byte_identical=True,source_id=report['source_id'],work=str(scratch),files=hashes,hardware_access=False,benchmark_executed=False,frozen_runtime_files_replaced=False)
    (scratch/'reproduction_result.json').write_text(json.dumps(result,indent=2),encoding='utf8')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
