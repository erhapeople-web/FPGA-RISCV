"""Synthetic transcript/command tests only: never links or runs a benchmark."""
from pathlib import Path
import hashlib
import importlib.util
import json
import subprocess
import sys

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('cm5_parser',ROOT/'uart_parser.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
IDENTITY='1'*64
NONCE=0x12345678

def fixture(mode='P',cycles=2000000000):
    seed=0 if mode=='P' else 0x3415;crc=p.CRC[mode]
    lines=[f'J5_COREMARK_READY V=1 SEQ=00000000 SOURCE_ID={IDENTITY} CPU_HZ=100000000 ITERATIONS=5000 DATA_SIZE=2000 ISA=RV32I COMMAND_BYTES=32',
           f'CM5_BEGIN SEQ=00000001 MODE={mode} NONCE={NONCE:08x}',
           f'CM5_SEEDS SEQ=00000002 MODE={mode} NONCE={NONCE:08x} SEED1={seed:08x} SEED2={seed:08x} SEED3=00000066 SEED4=00001388 SEED5=00000000 CPU_HZ=100000000 ITERATIONS=5000',
           f'2K {"performance" if mode=="P" else "validation"} run parameters for coremark.',
           'CoreMark Size    : 666',f'Total ticks      : {cycles&0xffffffff}',f'Total time (secs): {cycles//p.CPU_HZ}',
           f'Iterations/Sec   : {p.ITERATIONS//max(1,cycles//p.CPU_HZ)}','Iterations       : 5000',
           'Compiler version : GCC 15.2.0','Compiler flags   : -march=rv32i -mabi=ilp32 -O2 -DITERATIONS=5000',
           'Memory location  : STATIC SRAM',f'seedcrc          : 0x{crc["seedcrc"]}',
           f'[0]crclist       : 0x{crc["crclist"]}',f'[0]crcmatrix     : 0x{crc["crcmatrix"]}',f'[0]crcstate      : 0x{crc["crcstate"]}',
           '[0]crcfinal      : 0x1234',p.VALIDATED,
           f'EXACT_CYCLES_HEX={cycles:016x} CPU_HZ=100000000 ITERATIONS=5000 SEQ=00000003 MODE={mode} NONCE={NONCE:08x}',
           'CACHE_COUNTERS IC_ACCESS=00000100 IC_MISS=00000010 DC_ACCESS=00000200 DC_MISS=00000020',
           f'AI_CPU_COREMARK_FINISHED SEQ=00000004 MODE={mode} NONCE={NONCE:08x} RETURN=00000000']
    return ('\n'.join(lines)+'\n').encode('ascii')

def main():
    checks=[]
    def good(name,test):assert test,name;checks.append(name)
    def reject(name,data,mode='P',nonce=NONCE,source=IDENTITY):
        try:p.parse_uart(data,mode,nonce,source)
        except p.CaptureError:checks.append(name);return
        raise AssertionError('Accepted negative: '+name)
    for mode in ['P','V']:
        good(mode+'_positive',p.parse_uart(fixture(mode),mode,NONCE,IDENTITY)['passed'])
        good(mode+'_CRLF',p.parse_uart(fixture(mode).replace(b'\n',b'\r\n'),mode,NONCE,IDENTITY)['passed'])
        good(mode+'_command_roundtrip',p.parse_command(p.make_command(mode,NONCE))=={'mode':mode,'nonce':NONCE})
        for key in p.CRC[mode]:reject(mode+'_bad_'+key,fixture(mode).replace(p.CRC[mode][key].encode(),b'0000',1),mode)
    base=fixture()
    mutations={
      'short_runtime':fixture(cycles=999999999),'one_second_runtime':fixture(cycles=100000000),
      'wrong_nonce':base.replace(b'NONCE=12345678',b'NONCE=12345679',1),
      'wrong_mode':base.replace(b'MODE=P',b'MODE=V',1),'wrong_source':base.replace(IDENTITY.encode(),b'2'*64,1),
      'wrong_frequency':base.replace(b'CPU_HZ=100000000',b'CPU_HZ=125000000',1),
      'wrong_iterations':base.replace(b'ITERATIONS=5000',b'ITERATIONS=3000',1),
      'wrong_seed':base.replace(b'SEED1=00000000',b'SEED1=00000001',1),
      'wrong_seq':base.replace(b'SEQ=00000003',b'SEQ=00000004',1),
      'duplicate_ready':base.splitlines(keepends=True)[0]+base,
      'duplicate_finish':base+base.splitlines(keepends=True)[-1],
      'duplicate_crc':base.replace(b'[0]crclist       : 0xe714\n',b'[0]crclist       : 0xe714\n[0]crclist       : 0xe714\n'),
      'missing_finish':b'\n'.join(base.split(b'\n')[:-2])+b'\n',
      'missing_newline':base[:-1],'truncated':base[:60],
      'failure':base.replace(p.VALIDATED.encode(),b'Errors detected'),
      'official_time_mismatch':base.replace(b'Total time (secs): 20',b'Total time (secs): 21'),
      'official_ticks_mismatch':base.replace(b'Total ticks      : 2000000000',b'Total ticks      : 2000000001'),
      'extra_record':base+b'UNRELATED\n','temperature_not_demultiplexed':base+b'TH3 N=00000000\n',
      'zero_cache_access':base.replace(b'IC_ACCESS=00000100',b'IC_ACCESS=00000000'),
      'cache_miss_gt_access':base.replace(b'IC_MISS=00000010',b'IC_MISS=00000101'),
      'M_compiler_flags':base.replace(b'-march=rv32i ',b'-march=rv32im '),
      'compressed_compiler_flags':base.replace(b'-march=rv32i ',b'-march=rv32ic '),
      'nonzero_return':base.replace(b'RETURN=00000000',b'RETURN=00000001'),
      'bad_final_crc_format':base.replace(b'crcfinal      : 0x1234',b'crcfinal      : 0xzzzz'),
      'NUL':base.replace(b'GCC 15',b'GCC\x00 15'),
    }
    for name,data in mutations.items():reject(name,data)
    reject('expected_nonce_mismatch',base,nonce=NONCE+1);reject('expected_mode_mismatch',base,mode='V')
    good('ten_second_boundary',p.parse_uart(fixture(cycles=1000000000),'P',NONCE,IDENTITY)['seconds']==10)
    command=p.make_command('P',NONCE)
    for name,data in [('command_bad_magic',b'X'+command[1:]),('command_bad_crc',command[:22]+b'00000000\r\n'),('command_truncated',command[:-1]),('command_zero_nonce',p.make_command('P',1).replace(b'00000001',b'00000000')),('command_bad_mode',command.replace(b' P ',b' X '))]:
        try:p.parse_command(data)
        except p.CaptureError:checks.append(name)
        else:raise AssertionError(name)
    for mode,nonce in [('X',1),('P',0),('V',-1),('P',2**32),('P',True)]:
        try:p.make_command(mode,nonce)
        except p.CaptureError:checks.append('invalid_command_argument_'+str((mode,nonce)))
        else:raise AssertionError('Invalid command argument accepted')
    out=ROOT/'tests';out.mkdir(exist_ok=True)
    sample=out/'synthetic_fixture_P.txt';sample.write_bytes(base)
    cli=subprocess.run([sys.executable,'-B',str(ROOT/'uart_parser.py'),str(sample),'--mode','P','--nonce',f'{NONCE:08x}','--source-id',IDENTITY],capture_output=True,text=True,timeout=20)
    good('inert_CLI_fixture_parse',cli.returncode==0 and json.loads(cli.stdout)['board_tested'] is False)
    sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    result={'passed':True,'checks':len(checks),'cases':checks,'hardware_access':False,'benchmark_executed':False,
            'fixtures_are_synthetic_not_board_results':True,'parser_sha256':sha(ROOT/'uart_parser.py'),
            'test_sha256':sha(Path(__file__)),'fixture_sha256':sha(sample),
            'crcfinal_note':'No5000-iteration reference was executed. Validate official seed/kernel CRCs; record crcfinal without pretending independent reference.'}
    (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('COREMARK_INERT_PARSER_TEST_PASS',len(checks),'benchmark_executed=false')

if __name__=='__main__':main()
