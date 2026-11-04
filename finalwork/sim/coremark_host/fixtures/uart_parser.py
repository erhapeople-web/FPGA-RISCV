"""Inert CoreMark command codec and strict CPU-UART transcript validator.

No serial/JTAG imports, reads, or hardware actions occur. The caller must first
validate and demultiplex any temperature frames; this parser rejects other data.
Fixture acceptance is never physical-board evidence by itself.
"""
import argparse
import json
from pathlib import Path
import re
import zlib

CPU_HZ=100000000
ITERATIONS=5000
CRC={'P':{'seedcrc':'e9f5','crclist':'e714','crcmatrix':'1fd7','crcstate':'8e3a'},
     'V':{'seedcrc':'18f2','crclist':'e3c1','crcmatrix':'0747','crcstate':'8d84'}}
VALIDATED='Correct operation validated. See README.md for run and reporting rules.'

class CaptureError(ValueError):pass

def mode_nonce(mode,nonce):
    if mode not in ('P','V') or type(nonce) is not int or not 1<=nonce<=0xffffffff:
        raise CaptureError('Expected mode P/V and a nonzero unsigned32 nonce')

def make_command(mode,nonce):
    mode_nonce(mode,nonce)
    prefix=f'J5CM5000V1 {mode} {nonce:08x} '.encode('ascii')
    assert len(prefix)==22
    return prefix+f'{zlib.crc32(prefix):08x}\r\n'.encode('ascii')

def parse_command(data):
    if not isinstance(data,bytes) or len(data)!=32:
        raise CaptureError('Expected exactly32 command bytes')
    match=re.fullmatch(rb'J5CM5000V1 ([PV]) ([0-9a-f]{8}) ([0-9a-f]{8})\r\n',data)
    if not match:raise CaptureError('Malformed command')
    mode=match[1].decode('ascii');nonce=int(match[2],16);mode_nonce(mode,nonce)
    if int(match[3],16)!=zlib.crc32(data[:22]):raise CaptureError('Command CRC mismatch')
    return {'mode':mode,'nonce':nonce}

def parse_uart(data,expected_mode,expected_nonce,expected_source_id):
    mode_nonce(expected_mode,expected_nonce)
    if not isinstance(expected_source_id,str) or not re.fullmatch(r'[0-9a-f]{64}',expected_source_id):
        raise CaptureError('Expected the64-hex source identity from the frozen build')
    if not isinstance(data,bytes) or not data or len(data)>131072 or not data.endswith(b'\n'):
        raise CaptureError('Expected a complete bounded CPU-UART byte transcript')
    try:text=data.decode('ascii').replace('\r\n','\n')
    except UnicodeDecodeError as exc:raise CaptureError('Non-ASCII UART') from exc
    if any(ord(ch)<32 and ch!='\n' for ch in text) or '\r' in text:
        raise CaptureError('Unexpected control character')
    lines=text.splitlines()
    if any(not line for line in lines):raise CaptureError('Unexpected blank record')
    if any(token in text for token in ['ERROR!','Errors detected','Cannot validate','J5_COREMARK_REJECT']):
        raise CaptureError('Firmware reported failure')
    def one(prefix,pattern):
        selected=[(i,line) for i,line in enumerate(lines) if line.startswith(prefix)]
        if len(selected)!=1:raise CaptureError('Missing/duplicate record: '+prefix)
        index,line=selected[0];match=re.fullmatch(pattern,line)
        if not match:raise CaptureError('Malformed record: '+prefix)
        return index,match
    mode=expected_mode;nonce=f'{expected_nonce:08x}'
    ready,_=one('J5_COREMARK_READY ',rf'J5_COREMARK_READY V=1 SEQ=00000000 SOURCE_ID={expected_source_id} CPU_HZ=100000000 ITERATIONS=5000 DATA_SIZE=2000 ISA=RV32I COMMAND_BYTES=32')
    begin,_=one('CM5_BEGIN ',rf'CM5_BEGIN SEQ=00000001 MODE={mode} NONCE={nonce}')
    seed=0 if mode=='P' else 0x3415
    seeds,_=one('CM5_SEEDS ',rf'CM5_SEEDS SEQ=00000002 MODE={mode} NONCE={nonce} SEED1={seed:08x} SEED2={seed:08x} SEED3=00000066 SEED4=00001388 SEED5=00000000 CPU_HZ=100000000 ITERATIONS=5000')
    metrics,tm=one('EXACT_CYCLES_HEX=',rf'EXACT_CYCLES_HEX=([0-9a-f]{{16}}) CPU_HZ=100000000 ITERATIONS=5000 SEQ=00000003 MODE={mode} NONCE={nonce}')
    finish,_=one('AI_CPU_COREMARK_FINISHED ',rf'AI_CPU_COREMARK_FINISHED SEQ=00000004 MODE={mode} NONCE={nonce} RETURN=00000000')
    cache,cm=one('CACHE_COUNTERS ',r'CACHE_COUNTERS IC_ACCESS=([0-9a-f]{8}) IC_MISS=([0-9a-f]{8}) DC_ACCESS=([0-9a-f]{8}) DC_MISS=([0-9a-f]{8})')
    if not (ready==0 and ready<begin<seeds<metrics<cache<finish==len(lines)-1):
        raise CaptureError('Marker order/sequence mismatch or trailing UART')
    cycles=int(tm[1],16)
    if cycles<1000000000:raise CaptureError('CoreMark runtime below10seconds')
    counters=dict(zip(['ic_access','ic_miss','dc_access','dc_miss'],map(lambda s:int(s,16),cm.groups())))
    if not (counters['ic_access']>0 and counters['dc_access']>0 and counters['ic_miss']<=counters['ic_access'] and counters['dc_miss']<=counters['dc_access']):
        raise CaptureError('Cache activity counters invalid')
    official=[]
    def scalar(prefix,pattern):
        index,match=one(prefix,pattern);official.append(index);return match
    name='performance' if mode=='P' else 'validation'
    scalar('2K ',rf'2K {name} run parameters for coremark\.')
    scalar('CoreMark Size',r'CoreMark Size\s*:\s*666')
    ticks=int(scalar('Total ticks',r'Total ticks\s*:\s*(\d+)')[1])
    seconds=int(scalar('Total time (secs)',r'Total time \(secs\)\s*:\s*(\d+)')[1])
    ips=int(scalar('Iterations/Sec',r'Iterations/Sec\s*:\s*(\d+)')[1])
    scalar('Iterations ',r'Iterations\s*:\s*5000')
    scalar('Compiler version',r'Compiler version\s*:\s*GCC [ -~]+')
    flags=scalar('Compiler flags',r'Compiler flags\s*:\s*([ -~]+)')[1].split()
    if flags.count('-march=rv32i')!=1 or flags.count('-mabi=ilp32')!=1 or flags.count('-DITERATIONS=5000')!=1:
        raise CaptureError('ISA/iteration compiler flags differ')
    if any(token.startswith('-march=') and token!='-march=rv32i' for token in flags):
        raise CaptureError('Non-RV32I compiler flags')
    scalar('Memory location',r'Memory location\s*:\s*STATIC SRAM')
    crc={}
    for key,expected in CRC[mode].items():
        prefix='seedcrc' if key=='seedcrc' else '[0]'+key
        value=scalar(prefix,re.escape(prefix)+r'\s*:\s*0x([0-9a-f]{4})')[1]
        if value!=expected:raise CaptureError('Incorrect '+key)
        crc[key]=value
    crc['crcfinal']=scalar('[0]crcfinal',r'\[0\]crcfinal\s*:\s*0x([0-9a-f]{4})')[1]
    scalar('Correct operation',re.escape(VALIDATED))
    if not all(seeds<i<metrics for i in official):raise CaptureError('Official result block outside timed markers')
    if ticks!=(cycles&0xffffffff) or seconds!=cycles//CPU_HZ or ips!=ITERATIONS//seconds:
        raise CaptureError('Integer official time/ticks disagree with exact cycles')
    allowed=set([ready,begin,seeds,metrics,cache,finish,*official])
    if allowed!=set(range(len(lines))):raise CaptureError('Unexpected UART record; demultiplex temperature outside this parser')
    return {'passed':True,'scope':'CPU-UART transcript conditions only; caller must separately bind a real board, image and protected run',
            'board_tested':False,'mode':mode,'nonce':expected_nonce,'source_id':expected_source_id,
            'cpu_hz':CPU_HZ,'iterations':ITERATIONS,'cycles':cycles,'seconds':cycles/CPU_HZ,
            'coremark':ITERATIONS*CPU_HZ/cycles,'coremark_per_mhz':ITERATIONS*1000000/cycles,
            'crc':crc,'kernel_crc_independent_constants_checked':True,
            'crcfinal_independent_5000_reference_checked':False,'cache_counters':counters}

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('capture',type=Path)
    ap.add_argument('--mode',choices=['P','V'],required=True);ap.add_argument('--nonce',type=lambda s:int(s,16),required=True)
    ap.add_argument('--source-id',required=True);a=ap.parse_args()
    try:result=parse_uart(a.capture.read_bytes(),a.mode,a.nonce,a.source_id)
    except (CaptureError,OSError) as exc:print(json.dumps({'passed':False,'error':str(exc)}));return 2
    print(json.dumps(result,indent=2));return 0

if __name__=='__main__':raise SystemExit(main())
