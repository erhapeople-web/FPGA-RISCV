"""Verify the frozen reproduction package before binding local paths; no devices."""
from pathlib import Path
import argparse,hashlib,importlib.util,json
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):return json.loads(Path(p).read_text(encoding='utf8'))
def inside(name):
    p=(ROOT/name).resolve()
    if not p.is_relative_to(ROOT)or not p.is_file()or p.is_symlink():raise ValueError('Missing/escaped package file: '+str(name))
    return p
def check_path():
    s=str(ROOT)
    if len(s)>100 or any(c.isspace()or ord(c)>127 for c in s):raise ValueError('Extract to a short ASCII path without spaces, e.g. E:\\J5_CM2506')
    return dict(passed=True,path=s,hardware_access=False)
def verify_files():
    m=read(ROOT/'CHECKSUMS.json')
    for name,row in m['files'].items():
        p=inside(name)
        if p.stat().st_size!=row['size']or sha(p)!=row['sha256']:raise ValueError('Frozen package file changed: '+name)
    b=read(inside('qualification/baseline_gate.json'))
    if b['passed']is not True:raise ValueError('Package qualification is not passed')
    for name,h in b['proof_hashes'].items():
        if sha(inside(name))!=h or read(inside(name)).get('passed')is not True:raise ValueError('Retained proof changed: '+name)
    i=read(ROOT/'identity.json');p=read(ROOT/'PACKAGE_IDENTITY.json')
    for name,h in i['all_source_files'].items():
        if sha(inside('src/'+name))!=h:raise ValueError('Original hardware/ROM source changed: '+name)
    if sha(inside('pds/firmware_init.vh'))!=sha(inside('src/firmware/firmware_init.vh')):raise ValueError('PDS ROM mirror differs')
    for name,h in [('bitstream/test_ddr.sbit',p['bitstream_sha256']),('src/firmware/production.bin',p['firmware_sha256']),('identity.json',p['original_identity_sha256'])]:
        if sha(inside(name))!=h:raise ValueError('Measured image identity changed: '+name)
    return dict(passed=True,immutable_files=len(m['files']),source_id=i['source_id'],firmware_sha256=p['firmware_sha256'],bitstream_sha256=p['bitstream_sha256'],hardware_access=False)
def board_module():
    s=importlib.util.spec_from_file_location('portable_coremark_board',ROOT/'tools/run_ai_camera_board.py')
    m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def dependencies(mapping,root):
    answer={}
    for name,h in mapping.items():
        p=Path(name).resolve();key='package/'+p.relative_to(root).as_posix()if p.is_relative_to(root)else'native/'+p.name
        if key in answer:raise ValueError('Duplicate dependency role')
        answer[key]=h
    return answer
def bind():
    check_path();verify_files()
    import psutil,serial
    if psutil.__version__!='7.2.2'or serial.VERSION!='3.5':raise ValueError('Run setup.ps1 to install pinned offline wheels')
    for run in(ROOT/'runs').glob('*'):
        if (run/'WATCHDOG_READY').exists():
            w=read(run/'wrapper_result.json')if(run/'wrapper_result.json').exists()else{}
            if not w.get('cleanup',{}).get('verified'):raise RuntimeError('Prior session cleanup is unverified: '+str(run))
    board=board_module();b=read(ROOT/'qualification/baseline_gate.json')
    for n in board.source_closure(ROOT):
        if sha(inside(n))!=b['source_hashes'][n]:raise ValueError('Qualified input changed: '+n)
    actual=board.runtime_dependencies()
    if dependencies(actual,ROOT)!=b['runtime_dependencies']:raise ValueError('Native tools/runtime bytes differ from the qualified package')
    names=set(b['source_hashes'])|{'qualification/baseline_gate.json'}
    gate=dict(schema=board.SCHEMA,scope=board.SCOPE,passed=True,candidate_root=str(ROOT),
        source_hashes={n:sha(inside(n))for n in sorted(names)},proof_hashes=b['proof_hashes'],required_proofs=b['required_proofs'],
        dependency_hashes=actual,bitstream=b['bitstream'],identity_sha256=sha(ROOT/'identity.json'),
        baseline_gate_sha256=sha(ROOT/'qualification/baseline_gate.json'),
        qualification_scope='Exact original RTL/ROM/bitstream plus newly tested path/port adapter; local immutable proof and dependency binding only',
        authorization='User requested an exact portable reproduction of measured CoreMark P/V5000; SRAM-only protected flow')
    board.write_json(ROOT/'evidence/BOARD_GATE.json',gate);_,bound=board.qualified()
    return dict(passed=True,candidate_root=str(ROOT),gate_sha256=bound['gate_sha256'],hardware_access=False)
def main():
    p=argparse.ArgumentParser();p.add_argument('--bind',action='store_true');p.add_argument('--check-path',action='store_true');a=p.parse_args()
    print(json.dumps(check_path()if a.check_path else bind()if a.bind else verify_files(),indent=2))
if __name__=='__main__':main()
