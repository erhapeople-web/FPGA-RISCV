"""Run current CoreMark UART and integration controls, prohibiting Popen."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main():
    output=ROOT/'evidence/coremark_uart_tests';output.mkdir(parents=True,exist_ok=True)
    paths=[ROOT/'host'/name for name in ['coremark_uart_parser.py','coremark_uart_case.py','coremark_workload.py']]
    paths += [ROOT/'tools/run_ai_camera_board.py',Path(__file__),ROOT/'sim/ai_board_control/test_ai_board_control.py']
    paths += [Path(__file__).with_name(name)for name in ['test_coremark_uart_case.py','test_current_integration.py']]
    paths += list((Path(__file__).parent/'fixtures').glob('*.py'))
    frozen={str(p):sha(p)for p in paths};log=io.StringIO();suite=unittest.TestSuite()
    with patch.object(subprocess,'Popen',side_effect=AssertionError('Process/device creation forbidden in offline controls')):
        for name in ['test_coremark_uart_case.py','test_current_integration.py']:
            spec=importlib.util.spec_from_file_location(name[:-3],Path(__file__).with_name(name))
            module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
            suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
        result=unittest.TextTestRunner(stream=log,verbosity=2).run(suite)
    (output/'tests.log').write_text(log.getvalue(),encoding='utf8')
    assert all(sha(Path(p))==d for p,d in frozen.items())
    record=dict(passed=result.wasSuccessful(),tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),
                scope='Synthetic P/V CRC/nonce/transport and current pre-program UART capture/ownership/execution-state controls; no benchmark or device',
                process_creation_prohibited=True,hardware_access=False,coremark_algorithm_executed=False,
                source_sha256=frozen,log_path=str(output/'tests.log'),log_sha256=sha(output/'tests.log'))
    (output/'result.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf8')
    print(log.getvalue()[-2600:]);print('CURRENT_COREMARK_UART_CONTROLS',record['passed'],record['tests'])
    return 0 if record['passed']else 1


if __name__=='__main__':raise SystemExit(main())
