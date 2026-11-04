"""Build only from this package; generated PDS products stay under build/."""
from pathlib import Path
from datetime import datetime
import argparse,json,re,subprocess,sys

ROOT=Path(__file__).resolve().parents[1]
def native(shell,script,work,label):
    log=work/(label+'.log')
    with log.open('wb') as out:
        p=subprocess.run([str(shell),'-file',str(script),'-work_dir',str(work),'-project_name','test_ddr'],
                         stdout=out,stderr=subprocess.STDOUT,timeout=2400,creationflags=subprocess.CREATE_NO_WINDOW)
    text=log.read_text(encoding='utf8',errors='replace')
    if p.returncode or re.search(r'^E:\s|Program Error Out\.',text,re.M):raise RuntimeError('PDS failed: '+str(log))
    return log

def main():
    p=argparse.ArgumentParser();p.add_argument('--pds-bin',type=Path,required=True);p.add_argument('--compile-only',action='store_true');a=p.parse_args()
    work=ROOT/'build'/('pds_'+datetime.now().strftime('%Y%m%d_%H%M%S'));work.mkdir(parents=True,exist_ok=False)
    text=(ROOT/'pds/build.tcl').read_text(encoding='utf8')
    text=text.replace('cd [file dirname [file normalize [info script]]]',f'cd {{{work.as_posix()}}}')
    text=text.replace('../src/',(ROOT/'src').as_posix()+'/').replace('../constraints/',(ROOT/'constraints').as_posix()+'/')
    text='cd {'+work.as_posix()+'}\n'+text
    (work/'firmware_init.vh').write_bytes((ROOT/'src/firmware/firmware_init.vh').read_bytes())
    if a.compile_only:
        text=re.split(r'(?m)^synthesize\b',text,maxsplit=1)[0]
        if re.search(r'(?m)^\s*(?:synthesize|dev_map|pnr)\b',text):raise RuntimeError('Compile-only script contains implementation command')
    else:text+='\nreport_timing -force_to_run -input_db_file {place_route/test_ddr_pnr.adf} -report_exception TRUE -max_path 30 -nworst 3\n'
    script=work/'build.tcl';script.write_text(text,encoding='utf8')
    shell=a.pds_bin/'pds_shell.exe';native(shell,script,work,'build')
    expected=work/('compile/test_ddr_comp.adf' if a.compile_only else 'place_route/test_ddr_pnr.adf')
    if not expected.is_file():raise RuntimeError('Expected native output missing: '+str(expected))
    if not a.compile_only:
        subprocess.run([sys.executable,'-B','-X','utf8',str(ROOT/'tools/check_timing.py'),str(work/'report_timing/test_ddr.rtr'),'--out',str(work/'timing.json')],check=True)
        script=work/'bitstream.tcl';script.write_text(f'cd {{{work.as_posix()}}}\nset_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676\ngen_bit_stream -force_to_run -input_db_file {{place_route/test_ddr_pnr.adf}} -scbv {{High Voltage}}\n',encoding='utf8')
        native(shell,script,work,'bitstream')
        if not (work/'generate_bitstream/test_ddr.sbit').is_file():raise RuntimeError('Generated bitstream missing')
    result=dict(passed=True,compile_only=a.compile_only,work_directory=str(work),hardware_access=False,
                frozen_runtime_bitstream_replaced=False)
    (work/'result.json').write_text(json.dumps(result,indent=2),encoding='utf8')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
