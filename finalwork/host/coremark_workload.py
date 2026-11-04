"""One P/V invocation on an already-owned UART; never opens a device."""
from pathlib import Path
import json

from coremark_uart_case import run_case

ROOT=Path(__file__).resolve().parents[1]


def run_workload(link,run,check,progress_callback=None,*,mode='P'):
    assert mode in ('P','V')
    identity=json.loads((ROOT/'identity.json').read_text(encoding='utf8'))
    assert identity['firmware_kind']=='coremark_uart_gate_v1' and identity['iterations']==5000
    assert identity['clock_mhz']==100 and identity['FOUR_FUSION']==0
    def cancel():
        check()
        return False
    def event(row):
        check()
        if progress_callback:progress_callback(row)
    result=run_case(mode,link,Path(run)/'application',source_id=identity['source_id'],
                    cancel_check=cancel,maximum_seconds=120,on_event=event)
    assert result['passed'] and result['coremark_executed'] and result['cycles']>=1_000_000_000
    assert result['iterations']==5000 and result['cpu_hz']==100_000_000
    result.update(host_inference_used=False,golden_boxes_sent=False,AI_RUN_sent=False,
                  same_hardware_as_current_AI_delivery=True,UART_baud=921600)
    (Path(run)/'application_result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8')
    return result
