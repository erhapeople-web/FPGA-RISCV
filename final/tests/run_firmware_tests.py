"""Run only the two protocol fixes; never open UART/JTAG or build FPGA hardware."""
from pathlib import Path
import argparse
import difflib
import hashlib
import json
import os
import re
import subprocess
import struct
import sys
import time
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'firmware/source'
LEGACY = SOURCE / 'legacy'
APP = LEGACY / 'board_rv32_application'
OUT = ROOT / 'evidence/firmware_tests'
VC = Path(os.environ.get('J5_VCVARS64', r'D:\Visual_Studio\cp\VC\Auxiliary\Build\vcvars64.bat'))
TOOLCHAIN = Path(os.environ.get('RISCV_TOOLCHAIN_BIN', ''))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(name, value):
    (OUT / (name + '.json')).write_text(json.dumps(value, indent=2) + '\n', encoding='utf8')


def run(args, name, cwd=OUT, timeout=180):
    start = time.monotonic()
    result = subprocess.run([str(x) for x in args], cwd=cwd, capture_output=True,
                            timeout=timeout, creationflags=subprocess.CREATE_NO_WINDOW)
    log = OUT / (name + '.log')
    log.write_bytes(result.stdout + result.stderr)
    save(name + '_execution', dict(returncode=result.returncode, seconds=time.monotonic()-start,
                                  log_sha256=sha(log)))
    return result


def compile_protocol(name, override=None):
    folder = OUT / name
    folder.mkdir(exist_ok=True)
    includes = ([override] if override else []) + [SOURCE, APP / 'common', APP / 'firmware',
                LEGACY / 'board_uart_loader', LEGACY / 'board_ddr_executor_smoke/firmware',
                LEGACY / 'board_integer_postprocess/firmware']
    files = [ROOT / 'tests/firmware/test_protocol.c', ROOT / 'tests/firmware/app_bridge.c',
             LEGACY / 'board_uart_loader/loader.c', LEGACY / 'board_uart_loader/crypto.c']
    exe = folder / 'protocol.exe'
    args = ['cl', '/nologo', '/O2', '/std:c11', '/W4',
            *['/I"' + str(x) + '"' for x in includes],
            *['"' + str(x) + '"' for x in files], '/Fe:"' + str(exe) + '"']
    script = folder / 'compile.cmd'
    script.write_text('@echo off\ncall "' + str(VC) + '" >nul\n'
                      'if errorlevel 1 exit /b 1\ncd /d "' + str(folder) + '"\n' +
                      ' '.join(args) + '\nexit /b %errorlevel%\n', encoding='utf8')
    result = run(['cmd.exe', '/d', '/c', script], name + '_compile')
    assert result.returncode == 0, result.stdout.decode(errors='replace')[-3000:]
    return exe


def protocol():
    exe = compile_protocol('protocol')
    result = run([exe], 'protocol')
    assert result.returncode == 0, (result.stdout + result.stderr).decode(errors='replace')
    match = re.search(rb'PROTOCOL_REGRESSION_PASS cases=(\d+) assertions=(\d+)', result.stdout)
    assert match
    inputs = [ROOT / 'tests/firmware/test_protocol.c', ROOT / 'tests/firmware/app_bridge.c',
              SOURCE / 'camera_hooks.c', SOURCE / 'camera_hooks.h', APP / 'common/app.c',
              APP / 'common/app.h', LEGACY / 'board_uart_loader/loader.c',
              LEGACY / 'board_uart_loader/crypto.c']
    record = dict(passed=True, cases=int(match[1]), assertions=int(match[2]),
                  source_sha256={p.relative_to(ROOT).as_posix(): sha(p) for p in inputs},
                  executable_sha256=sha(exe), hardware_access=False,
                  scope='Actual camera hooks/application/loader with fake MMIO/DDR/graph/PP; no full graph or board claim')
    save('protocol', record)
    print(result.stdout.decode(errors='replace').strip(), flush=True)
    return record


def negatives():
    hooks = (SOURCE / 'camera_hooks.c').read_text(encoding='utf8')
    header = ('incoming[5]!=0 || incoming[14]!=0 || incoming[15]!=0 ||\n'
              '     (cmd==0x22 && get32(incoming+8)!=0) ||\n     ')
    admission = (' if(crc_ok && cmd==5 && len==0 && incoming[5]==0 && get32(incoming+8)==0 && '
                 'incoming[14]==0 && incoming[15]==0)camera_prepare_input(loader);\n')
    assert header in hooks
    variants = [
        ('run_before_admission', hooks.replace(' /* The production loader owns RUN admission.',
                                               admission + ' /* The production loader owns RUN admission.')),
        ('custom_header_bypass', hooks.replace(header, '')),
    ]
    rows = []
    for name, source in variants:
        folder = OUT / ('negative_' + name)
        folder.mkdir(exist_ok=True)
        (folder / 'camera_hooks.c').write_text(source, encoding='utf8')
        exe = compile_protocol('negative_' + name, folder)
        result = run([exe], 'negative_' + name)
        detected = result.returncode == 10 and b'FAIL ' in result.stderr
        assert detected, (name, result.returncode, result.stdout, result.stderr)
        rows.append(dict(name=name, detected=True, returncode=result.returncode,
                         mutated_source_sha256=sha(folder / 'camera_hooks.c')))
        print('NEGATIVE_DETECTED', name, flush=True)
    record = dict(passed=True, cases=rows, hardware_access=False)
    save('negative_controls', record)
    return record




def build():
    if not os.environ.get('RISCV_TOOLCHAIN_BIN'):
        raise RuntimeError('Set RISCV_TOOLCHAIN_BIN to the RISC-V toolchain bin directory')
    result = run([sys.executable, '-B', '-X', 'utf8', ROOT / 'tools/build_camera_firmware.py',
                  '--toolchain', TOOLCHAIN], 'firmware_build')
    assert result.returncode == 0, (result.stdout + result.stderr).decode(errors='replace')[-4000:]
    record = json.loads((ROOT / 'firmware/build/result.json').read_text(encoding='utf8'))
    assert record['passed'] and not record['forbidden_instruction_mnemonics']
    assert sha(ROOT / 'firmware/camera.elf') == record['firmware_elf_sha256']
    save('firmware', record)
    print(result.stdout.decode(errors='replace').strip(), flush=True)
    return record


def uart():
    folder = OUT / 'production_uart'
    folder.mkdir(exist_ok=True)

    def frame(cmd, seq, payload=b''):
        packet = struct.pack('<4sBBHIHH', b'AIP1', cmd, 0, seq, 0, len(payload), 0) + payload
        return packet + struct.pack('<I', zlib.crc32(packet))

    requests = frame(4, 1) + frame(5, 2)
    expected = frame(0x84, 1, struct.pack('<III', 0, 0, 0)) + frame(0x85, 2, struct.pack('<III', 5, 0, 0))
    for name, data in [('uart_requests.hex', requests), ('uart_expected.hex', expected)]:
        (folder / name).write_text(''.join(f'{v:02x}\n' for v in data), encoding='ascii')
    symbols = (ROOT / 'firmware/build/symbols.log').read_text(encoding='utf8')
    address = int(re.search(r'^([0-9a-f]+)\s+B\s+application_state$', symbols, re.M)[1], 16)
    sources = [p for p in (ROOT / 'src/rtl').rglob('*.v')
               if 'video' not in p.parts and 'thermal' not in p.parts and p.name != 'board_clock.v']
    exe = folder / 'production.vvp'
    result = run([r'C:\iverilog\bin\iverilog.exe', '-g2012', '-s', 'tb',
                  '-I' + str(ROOT / 'src/firmware'),
                  '-DAPP_STATE_WORD=' + str((address - 0x10000000)//4), '-o', exe,
                  ROOT / 'tests/firmware/tb_production_uart.sv', *sources], 'production_uart_compile')
    assert result.returncode == 0, (result.stdout + result.stderr).decode(errors='replace')[-3000:]
    result = run([r'C:\iverilog\bin\vvp.exe', exe], 'production_uart_run', cwd=folder, timeout=300)
    assert result.returncode == 0 and b'PRODUCTION_UART_PASS' in result.stdout, (result.stdout + result.stderr).decode(errors='replace')
    record = dict(passed=True, firmware_sha256=sha(ROOT / 'src/firmware/production.bin'),
                  testbench_sha256=sha(ROOT / 'tests/firmware/tb_production_uart.sv'),
                  log_sha256=sha(OUT / 'production_uart_run.log'), hardware_access=False,
                  scope='New production ROM on original CPU/Cache/AXI/UART RTL; startup, STATUS, rejected RUN, zero camera/DDR accesses. No CoreMark/AI/board claim')
    save('production_uart', record)
    print(result.stdout.decode(errors='replace').strip(), flush=True)
    return record




def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['protocol','negative','build','uart','all'])
    action=parser.parse_args().action
    OUT.mkdir(parents=True,exist_ok=True)
    if action=='all':
        protocol();negatives();build();uart()
    else:
        {'protocol':protocol,'negative':negatives,'build':build,'uart':uart}[action]()

if __name__=='__main__':
    main()
