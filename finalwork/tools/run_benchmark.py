"""Sequential P/V dispatcher; board wrapper owns all deadlines and cleanup."""
from pathlib import Path
import argparse,json,subprocess,sys
from portable_package import ROOT,verify_files
from verify_run import audit
def main():
    p=argparse.ArgumentParser();p.add_argument('--mode',choices=['Both','P','V'],default='Both');p.add_argument('--port',default='COM11');a=p.parse_args()
    verify_files();rows=[]
    for mode in(['P','V']if a.mode=='Both'else[a.mode]):
        before=set((ROOT/'runs').glob('*'))
        code=subprocess.call([sys.executable,'-B','-X','utf8',str(ROOT/'tools/run_ai_camera_board.py'),'--mode',mode,'--port',a.port])
        if code:raise RuntimeError('Board session failed; inspect runs/ cleanup status before any retry')
        new=set((ROOT/'runs').glob('*'))-before
        if len(new)!=1:raise RuntimeError('Ambiguous private run creation')
        result=audit(new.pop(),mode);rows.append(result)
        print(f"COREMARK_VERIFIED mode={mode} cycles={result['cycles']} seconds={result['seconds']:.8f} CoreMark/MHz={result['coremark_per_mhz']:.9f} exact_reference_cycles={result['cycles_match_measured_reference']}",flush=True)
    print(json.dumps([dict(mode=r['mode'],run=r['board_run'],cycles=r['cycles'],coremark_per_mhz=r['coremark_per_mhz'])for r in rows],indent=2))
if __name__=='__main__':main()
