"""Read-only post-clear audit of actual current-SoC P and V benchmark sessions."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import re
import sys

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent/'J5_AI_CAMERA_PERF_20261101'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
read=lambda p:json.loads(Path(p).read_text(encoding='utf8'))


def load_board():
    spec=importlib.util.spec_from_file_location('current_coremark_saved_run_reader',ROOT/'tools/run_ai_camera_board.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


def routed_resources():
    path=ROOT/'pds/place_route/test_ddr.prr'
    lines=path.read_text(errors='replace').splitlines()
    headers=[i for i,line in enumerate(lines) if line.startswith('| Module Inst Name')]
    assert len(headers)==1
    names=[s.strip() for s in lines[headers[0]].split('|')[1:]]
    rows=[line for line in lines[headers[0]+1:] if re.match(r'^\|\s*test_ddr\s*\|',line)]
    assert len(rows)==1
    cells=[s.strip() for s in rows[0].split('|')[1:]]
    values=dict(zip(names[1:],cells[1:]))
    resource={name:float(values[name]) for name in ['LUT','FF','Distributed RAM','APM','DRM']}
    assert all(value>0 for value in resource.values())
    physical_luts=[int(m.group(1)) for line in lines[:headers[0]]
                   if (m:=re.match(r'^\|\s+LUT\s*\|\s*(\d+)\s*\|',line))]
    assert len(physical_luts)==2
    return dict(module_statistics=resource,physical_CLMA_CLMS_LUT_sum=sum(physical_luts),
        efficiency_denominator='Final routed PDS top-module test_ddr LUT count; full SoC including camera/display, not CPU-only',
        report_path=str(path),report_sha256=sha(path))


def audit(run,mode,board,reference):
    run=Path(run).resolve();wrapper=read(run/'wrapper_result.json');app=read(run/'application_result.json')
    assert wrapper['passed'] is True and wrapper['state']=='completed'
    assert wrapper['coremark_executed'] is True and wrapper['qualified_inputs_unchanged'] is True
    assert wrapper['cleanup']['verified'] is True and wrapper['server_close']['closed'] is True
    assert not wrapper['server_close']['remaining_listener_PIDs']
    assert wrapper['watchdog']['fallback_reset_attempted'] is False and wrapper['watchdog']['normal_controller_cleanup'] is True
    assert wrapper['controller']['native_clients_stopped_before_reset'] is True
    assert wrapper['flash_written'] is False and wrapper['PC_inference_executed'] is False
    assert app['passed'] is True and app['mode']==mode and app['AI_RUN_sent'] is False
    board.MODE=mode;bit,binding=board.qualified(ROOT)
    assert wrapper['binding']==binding==read(run/'input_binding.json')
    assert sha(run/'ai_camera_frozen.sbit')==sha(bit)==binding['bitstream_sha256']
    sys.path.insert(0,str(ROOT/'host'))
    from coremark_uart_parser import parse_uart,parse_command
    tx=(run/'application/uart_tx.bin').read_bytes();rx=(run/'application/uart_rx.bin').read_bytes()
    assert tx==(run/'raw_tx.bin').read_bytes()and rx==(run/'raw_rx.bin').read_bytes()
    assert len(tx)==32 and parse_command(tx)==dict(mode=mode,nonce=app['nonce'])
    parsed=parse_uart(rx,mode,app['nonce'],binding['source_id'])
    assert parsed['passed']and parsed['cycles']>=1_000_000_000 and parsed['iterations']==5000
    assert parsed['crc']==reference['results'][mode]['crc'],'Independent5000-iteration CRC differs'
    observer=read(run/'native_ot_observer/result.json')
    assert observer['accepted_samples']>=1 and observer['ot_asserted_samples']==observer['read_failures']==0
    assert observer['fault']is None
    samples=[json.loads(s)for s in(run/'native_ot_observer/samples.jsonl').read_text(encoding='utf8').splitlines()]
    accepted=[s for s in samples if s['accepted']]
    assert len(accepted)==observer['accepted_samples']and all(s['over_temp']is False for s in accepted)
    for row in accepted:assert sha(row['log'])==row['log_sha256']
    files=[run/n for n in ['wrapper_result.json','controller_result.json','watchdog_result.json','input_binding.json',
            'application_result.json','application/result.json','application/uart_tx.bin','application/uart_rx.bin',
            'raw_tx.bin','raw_rx.bin','native_ot_observer/result.json','native_ot_observer/samples.jsonl']]
    return dict(passed=True,mode=mode,board_run=str(run),source_id=binding['source_id'],
        bitstream_sha256=binding['bitstream_sha256'],firmware_binary_sha256=read(ROOT/'identity.json')['firmware_sha256'],
        iterations=5000,clock_hz=100_000_000,cycles=parsed['cycles'],seconds=parsed['seconds'],
        coremark=parsed['coremark'],coremark_per_mhz=parsed['coremark_per_mhz'],crc=parsed['crc'],
        all_kernel_and_final_CRC_independent_5000_reference_checked=True,
        cache_counters=parsed['cache_counters'],cache_counter_scope='Cumulative from cold reset through post-result counter read; includes boot, command wait, initialization and UART output, not an isolated timed-kernel window',
        OT_samples=observer['accepted_samples'],OT_asserted_samples=0,
        sram_clear_verified=True,clear_status=wrapper['cleanup']['cleanup']['status']['raw'],
        normal_cleanup=True,native_server_closed=True,
        source_run_hashes={str(p):sha(p)for p in files})


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('P_run',type=Path);parser.add_argument('V_run',type=Path);args=parser.parse_args()
    reference_path=ROOT/'evidence/native_coremark_reference/result.json';reference=read(reference_path)
    assert reference['passed']and reference['candidate_timing_passed_before_execution']
    assert sha(reference['binary_path'])==reference['binary_sha256']
    assert all(sha(p)==d for p,d in reference['source_sha256'].items())
    for row in reference['results'].values():assert sha(row['log_path'])==row['log_sha256']
    board=load_board();rows=[audit(args.P_run,'P',board,reference),audit(args.V_run,'V',board,reference)]
    assert rows[0]['bitstream_sha256']==rows[1]['bitstream_sha256']and args.P_run.resolve()!=args.V_run.resolve()
    assert rows[0]['source_id']==rows[1]['source_id']
    hardware=read(ROOT/'identity.json');baseline=read(BASE/'identity.json')
    resources=routed_resources()
    for row in rows:row['coremark_per_LUT']=row['coremark']/resources['module_statistics']['LUT']
    for name,digest in baseline['all_source_files'].items():
        if not name.startswith('firmware/'):assert sha(ROOT/'src'/name)==sha(BASE/'src'/name)==digest
    assert hardware['constraints']==baseline['constraints']and hardware['FOUR_FUSION']==0 and hardware['video_enabled']
    result=dict(passed=True,scope='Actual current delivered AI SoC hardware, separate CoreMark ROM; two fresh SRAM P/V runs >=10s, full CRC/reference and normal post-clear audit',
        candidate_root=str(ROOT),baseline_AI_root=str(BASE),same_non_ROM_hardware_as_AI_delivery=True,
        iterations=5000,data_size_bytes=2000,clock_mhz=100,FOUR_FUSION=0,video_hardware_retained=True,
        data_location='Local SRAM through actual two-way D-Cache/AXI; ROM through actual I-Cache; not a DDR-resident benchmark',
        firmware_kind='official pinned-source RV32I -O2 command-gated CoreMark5000; no M/C or MAC8 calls',
        results=rows,routed_resources=resources,independent_numeric_reference_path=str(reference_path),independent_numeric_reference_sha256=sha(reference_path),
        identity_sha256=sha(ROOT/'identity.json'),gate_sha256=sha(ROOT/'evidence/BOARD_GATE.json'),
        script_path=str(Path(__file__).resolve()),script_sha256=sha(__file__),hardware_access=False,
        physical_temperature_measured=False,flash_written=False,official_certification_claimed=False,
        limitations=['Printed integer seconds/Iterations-Sec are truncated; reported scores use exact64bit CPU-cycle intervals.',
                     'The test ROM differs from the AI application ROM; this is a same-hardware CPU benchmark, not simultaneous AI throughput.',
                     'Native reference execution is used only for CRC comparison and is not a host speed score.',
                     'Routed hold margin +0.028 ns is nonnegative but below the +0.050 ns working goal; setup margin is +0.519 ns.'])
    target=ROOT/'evidence/COREMARK_BOARD_RESULT.json';target.write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
    report=['# 当前 AI 摄像头版 CPU 的 CoreMark 实板结果','',
            '同一 CPU／Cache／AXI／摄像头／保护硬件，独立 CoreMark ROM。100 MHz，RV32I 无 M/C，-O2，2 KiB 数据，5000 次迭代；FOUR_FUSION=0。原 AI 工程及交付 ZIP 保持原样。','',
            '| 模式 | 精确周期 | 实测秒数 | CoreMark | CoreMark/MHz | CoreMark/LUT |','| --- | ---: | ---: | ---: | ---: | ---: |']
    for row in rows:report.append(f"| {row['mode']} | {row['cycles']} | {row['seconds']:.8f} | {row['coremark']:.9f} | {row['coremark_per_mhz']:.9f} | {row['coremark_per_LUT']:.9f} |")
    report+=['','两组均满足至少10秒，独立5000次参考的全部kernel CRC及crcfinal一致，实际I/D Cache计数有效。每组重新下载SRAM，正常清板，自有服务关闭；所记录的原生OT均为0。未采集实际温度值。','',
             '分数以64位CPU周期换算；UART中的整数秒数和Iterations/Sec存在截断，不用它们反推精确成绩。数据位于SRAM并经过D-Cache/AXI，代码ROM经过I-Cache；不将其表述为DDR驻留跑分。Cache计数从冷复位累计到结果输出后的读数，包含启动、等待命令、初始化及UART输出，不是只覆盖计时内核的窗口。','',
             f"最终布线资源按PDS顶层test_ddr模块统计：LUT {int(resources['module_statistics']['LUT'])}、FF {int(resources['module_statistics']['FF'])}、Distributed RAM {int(resources['module_statistics']['Distributed RAM'])}、DRM {resources['module_statistics']['DRM']}、APM {int(resources['module_statistics']['APM'])}。CoreMark/LUT使用此全SoC模块LUT分母，包含摄像头和显示；物理CLMA/CLMS LUT合计另为{resources['physical_CLMA_CLMS_LUT_sum']}，不混用。",'',
             '100 MHz最终时序：setup +0.519 ns，hold +0.028 ns，负裕量组为0。hold满足非负验收，但尚未达到+0.050 ns工作目标。setup/hold uncertainty保持0.500/0.200 ns。','',
             f"位流SHA256：`{rows[0]['bitstream_sha256']}`。",f"固件SHA256：`{hardware['firmware_sha256']}`。",'',
             '原始逐字节记录和身份见 `evidence/COREMARK_BOARD_RESULT.json` 及其中两轮board_run目录。历史2.7179分只作旧配置记录，本报告只代表当前实测配置。']
    (ROOT/'COREMARK_RESULT.md').write_text('\n'.join(report)+'\n',encoding='utf8')
    print(json.dumps([dict(mode=r['mode'],cycles=r['cycles'],seconds=r['seconds'],coremark=r['coremark'],coremark_per_mhz=r['coremark_per_mhz'])for r in rows],indent=2))


if __name__=='__main__':main()
