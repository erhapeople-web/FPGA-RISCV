"""Audit a completed local session, including raw UART and final CRC."""
from pathlib import Path
import argparse,importlib.util,json
from portable_package import ROOT,board_module,sha,read
def audit(run,mode):
    run=Path(run).resolve()
    if run.parent!=ROOT/'runs':raise ValueError('Expected one private package run')
    s=importlib.util.spec_from_file_location('same_image_saved_run_audit',ROOT/'tools/verify_coremark_runs.py')
    m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
    ref=read(ROOT/'qualification/frozen_evidence/evidence/native_coremark_reference/result.json')
    result=m.audit(run,mode,board_module(),ref)
    result['cycles_match_measured_reference']=result['cycles']=={'P':1995110503,'V':2077410668}[mode]
    result['coremark_per_LUT']=result['coremark']/23710
    (run/'verified_result.json').write_text(json.dumps(result,indent=2),encoding='utf8')
    return result
def main():
    p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('--mode',choices=['P','V'],required=True);a=p.parse_args()
    print(json.dumps(audit(a.run,a.mode),indent=2))
if __name__=='__main__':main()
