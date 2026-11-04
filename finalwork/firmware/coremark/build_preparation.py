"""Compile the gated ROM only. Never execute the benchmark or install firmware."""
from pathlib import Path
from datetime import datetime
import hashlib
import json
import re
import struct
import subprocess

ROOT=Path(__file__).resolve().parent
GCC=Path(r'D:\FPGA2\fpga\2_8_uart_test\test_c\tools\gcc\bin\riscv32-unknown-elf-gcc.exe')
KERNELS=['core_main.c','core_list_join.c','core_matrix.c','core_state.c','core_util.c']
ALLOWED=set('lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu sb sh sw addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu xor srl sra or and fence ecall ebreak'.split())

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    origins=json.loads((ROOT/'source_origins.json').read_text(encoding='utf-8'))
    for name,row in origins['origins'].items():
        assert sha(ROOT/name)==row['sha256'] and sha(Path(row['source']))==row['sha256'],name
    assert GCC.is_file()
    flags=['-march=rv32i','-mabi=ilp32','-O2','-ffreestanding','-fno-builtin','-fno-pic',
           '-msmall-data-limit=0','-ffunction-sections','-fdata-sections','-fno-tree-loop-distribute-patterns',
           '-DITERATIONS=5000','-DVALIDATION_RUN=0','-DTOTAL_DATA_SIZE=2000']
    reported=' '.join(flags)
    files=[ROOT/'upstream'/n for n in KERNELS+['coremark.h','LICENSE.md','UPSTREAM_REVISION']]
    files += sorted((ROOT/'port').glob('*'))
    source_hashes={p.relative_to(ROOT).as_posix():sha(p) for p in files}
    compiler_sha256=sha(GCC)
    source_id=hashlib.sha256(json.dumps({'files':source_hashes,'flags':flags,'reported_flags':reported,
        'runner_sha256':sha(Path(__file__)),'compiler_driver_sha256':compiler_sha256,
        'entry_rename':'main=coremark_main_entry in core_main.c only'},sort_keys=True).encode()).hexdigest()
    out=ROOT/'build'/datetime.now().strftime('%Y%m%d_%H%M%S_%f');out.mkdir(parents=True)
    (out/'identity.h').write_text('#define CM_SOURCE_ID "'+source_id+'"\n',encoding='ascii')
    commands=[]
    def run(label,cmd):
        cmd=list(map(str,cmd));commands.append(cmd)
        p=subprocess.run(cmd,cwd=out,capture_output=True,timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
        (out/(label+'.log')).write_bytes(p.stdout+p.stderr)
        assert p.returncode==0,(label,(p.stdout+p.stderr).decode(errors='replace')[-4000:])
        return p.stdout.decode(errors='replace').replace('\r\n','\n')
    compiler=run('compiler_version',[GCC,'--version']).splitlines()[0]
    prefix=str(GCC).removesuffix('gcc.exe')
    sources=[ROOT/'upstream'/n for n in KERNELS]+[ROOT/'port'/n for n in ['start.S','core_portme.c','soft_arithmetic.c','gated_main.c']]
    objects=[]
    for index,source in enumerate(sources):
        obj=out/(str(index)+'.o');objects.append(obj)
        rename=['-Dmain=coremark_main_entry'] if source.name=='core_main.c' else []
        run('compile_'+str(index),[GCC,*flags,*rename,'-DCOMPILER_FLAGS="'+reported+'"','-I',ROOT/'port','-I',ROOT/'upstream','-I',out,'-c',source,'-o',obj])
    elf=out/'firmware.elf'
    run('link',[GCC,*flags,'-nostdlib','-nostartfiles','-T',ROOT/'port/link.ld','-Wl,--no-relax','-Wl,--gc-sections',
                '-Wl,--build-id=none','-Wl,-Map,'+str(out/'firmware.map'),*objects,'-o',elf])
    dis=run('objdump',[prefix+'objdump.exe','-d','-M','no-aliases',elf]);(out/'firmware.dis').write_text(dis,encoding='utf-8')
    instructions=[]
    for line in dis.splitlines():
        match=re.match(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s+(\S+)',line)
        if match:
            assert len(match[1])==8 and match[2] in ALLOWED,'Non-RV32I instruction: '+line
            instructions.append(match[2])
    assert instructions
    symbols=run('nm',[prefix+'nm.exe','-n',elf]);(out/'symbols.txt').write_text(symbols,encoding='utf-8')
    assert re.search(r'\bT main$',symbols,re.M) and re.search(r'\bT coremark_main_entry$',symbols,re.M)
    assert not run('undefined',[prefix+'nm.exe','-u',elf]).strip()
    size=run('size',[prefix+'size.exe',elf])
    run('objcopy',[prefix+'objcopy.exe','-O','binary',elf,out/'firmware.bin'])
    raw=(out/'firmware.bin').read_bytes();assert len(raw)<=65536
    data=raw+bytes((-len(raw))%4);words=list(struct.unpack('<'+'I'*(len(data)//4),data));words += [0x13]*(16384-len(words))
    (out/'firmware.hex').write_text(''.join(f'{w:08x}\n' for w in words),encoding='ascii')
    (out/'firmware_init.vh').write_text(''.join(f"rom[{i}] = 32'h{w:08x};\n" for i,w in enumerate(words)),encoding='ascii')
    assert all(sha(ROOT/n)==digest for n,digest in source_hashes.items()) and sha(GCC)==compiler_sha256,'Source/compiler changed during compile'
    record={'passed':True,'scope':'Compile, link and RV32I static inspection only; benchmark never executed; no ROM installed',
            'benchmark_executed':False,'hardware_access':False,'installed_into_candidate_src':False,
            'upstream_url':origins['upstream_url'],'upstream_commit':origins['upstream_commit'],'license':origins['license'],
            'compiler':compiler,'compiler_path':str(GCC),'compiler_driver_sha256':compiler_sha256,'flags':flags,'reported_flags':reported,'source_id':source_id,
            'iterations':5000,'clock_hz':100000000,'data_size':2000,'runtime_modes':{'P':[0,0,102,5000,0],'V':[13333,13333,102,5000,0]},
            'binary_bytes':len(raw),'rom_words':len(words),'build_directory':str(out),'instruction_count':len(instructions),
            'instruction_mnemonics':sorted(set(instructions)),'RV32I_only':True,'M_extension_instructions':False,'compressed_instructions':False,
            'size_output':size,'source_hashes':source_hashes,'source_origins_sha256':sha(ROOT/'source_origins.json'),
            'runner_sha256':sha(Path(__file__)),'commands':commands,
            'artifacts':{p.name:{'path':str(p),'sha256':sha(p)} for p in [elf,out/'firmware.bin',out/'firmware.hex',out/'firmware_init.vh',out/'firmware.dis',out/'firmware.map',out/'symbols.txt',out/'identity.h']},
            'required_before_benchmark':['functional and thermal qualification of exact new candidate','final routed timing and actual synthesized ROM identity','protected host execution and independent cleanup watchdog','fresh download per P/V mode','explicit full magic/CRC command from qualified host']}
    (out/'build_report.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    (ROOT/'build_report.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    print('COREMARK_GATED_ROM_COMPILE_PASS',json.dumps({'directory':str(out),'binary_bytes':len(raw),'source_id':source_id,'benchmark_executed':False}),flush=True)

if __name__=='__main__':main()
