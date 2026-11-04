"""Verify the frozen package, then bind the unchanged board runtime locally."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def read(path):return json.loads(Path(path).read_text(encoding='utf8'))
def inside(name):
    p=(ROOT/name).resolve()
    if not p.is_relative_to(ROOT) or not p.is_file() or p.is_symlink():raise ValueError('Missing/escaped package file: '+name)
    return p

def verify_files():
    manifest=read(ROOT/'CHECKSUMS.json')
    for name,row in manifest['files'].items():
        p=inside(name)
        if p.stat().st_size!=row['size'] or sha(p)!=row['sha256']:raise ValueError('Package file changed: '+name)
    baseline=read(inside('qualification/baseline_gate.json'))
    if baseline['passed'] is not True:raise ValueError('Baseline qualification is not passed')
    for name,digest in baseline['proof_hashes'].items():
        if sha(inside(name))!=digest or read(inside(name))['passed'] is not True:raise ValueError('Retained qualification changed: '+name)
    identity=read(inside('identity.json'))
    if sha(inside('pds/firmware_init.vh'))!=sha(inside('src/firmware/firmware_init.vh')):
        raise ValueError('PDS ROM initialization copy differs from qualified ROM')
    for folder,section in [('src','all_source_files'),('constraints','constraints'),('pds','scripts')]:
        for name,digest in identity[section].items():
            # impl.tcl is an old generated output, not an active build input.
            if folder=='pds' and name not in {'build.tcl','report.tcl','bitstream.tcl'}:continue
            if sha(inside(folder+'/'+name))!=digest:raise ValueError('Qualified hardware input changed: '+folder+'/'+name)
    for key,name in [('firmware_sha256','src/firmware/production.bin'),('firmware_elf_sha256','firmware/camera.elf'),
                     ('bitstream_sha256','bitstream/test_ddr.sbit'),('model_sha256','data/model.bin'),('ops_sha256','data/ops.bin')]:
        if sha(inside(name))!=identity[key]:raise ValueError('Qualified artifact changed: '+name)
    return dict(passed=True,immutable_files=len(manifest['files']),hardware_access=False,display_seconds=8)

def board_module():
    spec=importlib.util.spec_from_file_location('portable_unchanged_board',ROOT/'tools/run_ai_camera_board.py')
    board=importlib.util.module_from_spec(spec);spec.loader.exec_module(board);return board

def check_path():
    text=str(ROOT)
    if len(text)>120 or any(c.isspace() or ord(c)>127 for c in text):
        raise ValueError('Native PDS download tools require a short ASCII path without spaces. Extract the entire folder to e.g. E:\\J5_CAMERA_8S')
    return dict(passed=True,path=text,hardware_access=False)

def normalized_dependencies(mapping,root):
    result={}
    for name,digest in mapping.items():
        path=Path(name).resolve()
        key='package/'+path.relative_to(root).as_posix() if path.is_relative_to(root) else 'pds/'+path.name
        if key in result:raise ValueError('Duplicate dependency role: '+key)
        result[key]=digest
    return result

def bind():
    check_path()
    verify_files()
    for run in (ROOT/'runs').glob('*'):
        if (run/'WATCHDOG_READY').exists() and not (run/'wrapper_result.json').exists():
            raise RuntimeError('An unfinished board session exists; use STOP and verify cleanup first: '+str(run))
    import psutil,serial
    if psutil.__version__!='7.2.2' or serial.VERSION!='3.5':raise RuntimeError('Run setup.ps1 to install the bundled pinned dependencies')
    board=board_module();baseline=read(ROOT/'qualification/baseline_gate.json')
    for name in board.source_closure(ROOT):
        if sha(inside(name))!=baseline['source_hashes'][name]:raise ValueError('Active qualified source differs: '+name)
    actual=board.runtime_dependencies()
    expected=normalized_dependencies(baseline['dependency_hashes'],Path(baseline['candidate_root']).resolve())
    if normalized_dependencies(actual,ROOT)!=expected:raise ValueError('PDS/native runtime differs from qualified tool bytes')
    source_names=set(board.source_closure(ROOT))
    for folder in ['host','tools','firmware/source','data','runtime','vendor']:
        source_names|={p.relative_to(ROOT).as_posix() for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    source_names|={'environment.ps1','setup.ps1','run.ps1','check.ps1','stop.ps1','build_fpga.ps1','build_firmware.ps1',
                   'qualification/baseline_gate.json','bitstream/test_ddr.sbit','pds/firmware_init.vh'}
    gate=dict(schema=board.SCHEMA,scope=board.SCOPE,passed=True,candidate_root=str(ROOT),
        source_hashes={n:sha(inside(n)) for n in sorted(source_names)},
        proof_hashes=baseline['proof_hashes'],required_proofs=baseline['required_proofs'],
        dependency_hashes=actual,bitstream=baseline['bitstream'],
        identity_sha256=sha(ROOT/'identity.json'),routed_db_sha256=baseline['routed_db_sha256'],
        qualification_reused_from=baseline['candidate_root'],
        qualification_scope='Exact unchanged RTL/ROM/model/bitstream/board-controller bytes; retained executed hardware proofs; local path/dependency binding only',
        baseline_gate_sha256=sha(ROOT/'qualification/baseline_gate.json'),
        authorization='User requested a complete runnable eight-second package; SRAM-only single-frame workflow, original protection/STOP/watchdog/cleanup retained')
    board.write_json(ROOT/'evidence/BOARD_GATE.json',gate)
    _,binding=board.qualified()
    return dict(passed=True,candidate_root=str(ROOT),gate_sha256=binding['gate_sha256'],hardware_access=False)

def main():
    p=argparse.ArgumentParser();p.add_argument('--bind',action='store_true');p.add_argument('--check-path',action='store_true');args=p.parse_args()
    print(json.dumps(check_path() if args.check_path else bind() if args.bind else verify_files(),ensure_ascii=False,indent=2))
if __name__=='__main__':main()
