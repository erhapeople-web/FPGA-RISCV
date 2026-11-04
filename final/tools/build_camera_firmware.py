"""Build camera firmware from recovered production sources and current hooks.

All base objects are freshly compiled; historical objects remain reference-only.
No hardware use. The optimized executor and v10002 crop are retained.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import shutil

ROOT=Path(__file__).resolve().parents[1]
BIN=Path(r'D:\FPGA2\fpga\2_8_uart_test\test_c\tools\gcc\bin')
GCC=BIN/'riscv32-unknown-elf-gcc.exe'
OUT=ROOT/'firmware/build'

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def run(args,name):
 p=subprocess.run([str(a)for a in args],capture_output=True,timeout=120,creationflags=subprocess.CREATE_NO_WINDOW)
 (OUT/(name+'.log')).write_bytes(p.stdout+p.stderr)
 assert p.returncode==0,(name,(p.stdout+p.stderr).decode(errors='replace')[-6000:])
 return {'command':[str(a)for a in args],'returncode':p.returncode,'log_sha256':sha(OUT/(name+'.log'))}

def main():
 global BIN,GCC
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--toolchain',type=Path,default=Path(os.environ.get('RISCV_TOOLCHAIN_BIN',str(BIN))),
     help='Directory containing riscv32-unknown-elf-{gcc,objcopy,objdump,nm,size}; may also set RISCV_TOOLCHAIN_BIN')
 args=parser.parse_args();BIN=args.toolchain.resolve();GCC=BIN/'riscv32-unknown-elf-gcc.exe'
 for name in ['gcc','objcopy','objdump','nm','size']:
  if not (BIN/f'riscv32-unknown-elf-{name}.exe').is_file():parser.error('Missing RISC-V tool: '+str(BIN/f'riscv32-unknown-elf-{name}.exe'))
 OUT.mkdir(parents=True,exist_ok=True)
 flags=['-march=rv32i_zicsr','-mabi=ilp32','-O2','-ffreestanding','-fno-builtin','-nostdlib',
        '-msmall-data-limit=0','-fstack-usage','-Wall','-Wextra','-Werror','-Wno-misleading-indentation']
 records=[]
 for name in ['executor','camera_hooks']:
  records.append(run([GCC,*flags,'-I',ROOT/'firmware/source','-c',ROOT/'firmware/source'/f'{name}.c','-o',OUT/f'{name}.o'],name))
 legacy=ROOT/'firmware/source/legacy'
 app=legacy/'board_rv32_application';graph=legacy/'board_ddr_executor_smoke/firmware'
 loader=legacy/'board_uart_loader';pp=legacy/'board_integer_postprocess/firmware'
 base_sources=[app/'firmware/start.S',app/'firmware/main.c',app/'firmware/platform.c',
     app/'common/app.c',graph/'graph_runner.c',graph/'executor.c',app/'postprocess_link.c',loader/'loader.c',loader/'crypto.c']
 baseflags=['-march=rv32i_zicsr','-mabi=ilp32','-O2','-ffreestanding','-fno-builtin',
     '-msmall-data-limit=0','-fno-pic','-ffunction-sections','-fdata-sections','-fstack-usage']
 includes=['-I'+str(p)for p in [ROOT/'firmware/source',graph,pp,loader,app/'firmware',app/'common']]
 baseout=OUT/'base';baseout.mkdir(exist_ok=True);objects=[]
 for i,source in enumerate(base_sources):
  if i==5:continue # Use the current optimized executor, not the old one.
  obj=baseout/f'{i}.o'
  records.append(run([GCC,*baseflags,*includes,'-c',source,'-o',obj],f'base_{i}'))
  objects.append(obj)
 objects += [OUT/'executor.o',OUT/'camera_hooks.o']
 elf=OUT/'camera.elf'
 records.append(run([GCC,*flags,'-Wl,--no-relax','-T',ROOT/'firmware/source/link.ld',
     '-Wl,-Map='+str(OUT/'camera.map'),*['-Wl,--wrap='+n for n in ['ul_feed','ul_timeout','platform_read','platform_write','platform_send','ai_graph_run']],
     *objects,'-o',elf],'link'))
 binary=OUT/'camera.bin'
 records.append(run([BIN/'riscv32-unknown-elf-objcopy.exe','-O','binary',elf,binary],'objcopy'))
 records.append(run([BIN/'riscv32-unknown-elf-objdump.exe','-d',elf],'disassembly'))
 dis=(OUT/'disassembly.log').read_text(encoding='utf-8')
 mnemonics=re.findall(r'^\s*[0-9a-f]+:\s+[0-9a-f]+\s+(\S+)',dis,re.M)
 forbidden=[m for m in mnemonics if re.fullmatch(r'(?:mul(?:h|hu|hsu)?|divu?|remu?|c\..+)',m)]
 assert not forbidden,forbidden
 assert binary.stat().st_size<=65536
 records.append(run([BIN/'riscv32-unknown-elf-size.exe',elf],'size'))
 records.append(run([BIN/'riscv32-unknown-elf-nm.exe','-n',elf],'symbols'))
 symbols=(OUT/'symbols.log').read_text(encoding='utf-8')
 def symbol(name):
  found=re.findall(r'^([0-9a-f]+)\s+\S\s+'+re.escape(name)+r'$',symbols,re.M)
  assert len(found)==1,name
  return int(found[0],16)
 ram_used=symbol('__bss_end')-0x10000000
 assert ram_used<=65536-8192
 blob=binary.read_bytes();padded=blob+b'\x13\x00\x00\x00'*((65536-len(blob)+3)//4)
 padded=padded[:65536]
 words=[int.from_bytes(padded[i:i+4],'little')for i in range(0,65536,4)]
 target=ROOT/'src/firmware'
 (target/'production.bin').write_bytes(blob)
 (target/'production.hex').write_text(''.join(f'{w:08x}\n'for w in words),encoding='ascii')
 (target/'firmware_init.vh').write_text(''.join(f"rom[{i}] = 32'h{w:08x};\n"for i,w in enumerate(words)),encoding='ascii')
 shutil.copyfile(elf,ROOT/'firmware/camera.elf')
 sources=[ROOT/'firmware/source'/n for n in ['executor.c','executor.h','camera_hooks.c','camera_hooks.h','link.ld']]+objects
 sources += [p for p in legacy.rglob('*') if p.is_file() and p.suffix in ['.c','.h','.S','.ld']]
 records.append(run([GCC,'--version'],'compiler_version'))
 record={'passed':True,'scope':'Full provided-source camera application build: recovered production base plus current optimized executor/crop and split phases; no board or timing claim',
  'compiler':str(GCC),'records':records,'source_and_object_sha256':{str(p):sha(p)for p in sources},
  'firmware_binary_sha256':sha(binary),'firmware_elf_sha256':sha(elf),'firmware_bytes':len(blob),
  'ram_data_bss_bytes':ram_used,'stack_space_bytes':65536-ram_used,'minimum_stack_reservation':8192,
  'forbidden_instruction_mnemonics':forbidden,'instruction_set':'RV32I + Zicsr, ILP32; no M or C',
  'UART_BAUD':921600,'CPU_HZ':100000000,'load_limit_seconds':300,
  'model_nodes':119,'camera_preprocessing':'version0x10002;RGB565 expand by left shifts;center160x160 crop x80,y10 of320x180;no resize or padding;NCHW uint8',
  'legacy_source_closure_complete':True,'legacy_objects_consumed':False,
  'progress_sequence':'1,2,3,4@1..119,6,7,8,5','hardware_access':False}
 (OUT/'result.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
 print('CAMERA_FIRMWARE_BUILT',json.dumps({k:record[k]for k in ['firmware_binary_sha256','firmware_bytes','ram_data_bss_bytes','stack_space_bytes','UART_BAUD']}),flush=True)

if __name__=='__main__':main()
