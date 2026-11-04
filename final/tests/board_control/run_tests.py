"""Run fake-only orchestration tests with process creation prohibited."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'evidence/ai_board_control'
TEST=Path(__file__).with_name('test_ai_board_control.py')


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    began=time.monotonic();log=io.StringIO()
    with patch.object(subprocess,'Popen',side_effect=AssertionError('Offline test attempted process/device startup')):
        spec=importlib.util.spec_from_file_location('ai_board_offline_tests',TEST)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        sys.modules[spec.name]=module
        extra_path=TEST.with_name('test_cleanup_lifecycle.py')
        extra_spec=importlib.util.spec_from_file_location('ai_board_cleanup_tests',extra_path)
        extra=importlib.util.module_from_spec(extra_spec);extra_spec.loader.exec_module(extra)
        established=unittest.defaultTestLoader.loadTestsFromModule(module)
        added=unittest.defaultTestLoader.loadTestsFromModule(extra)
        suite=unittest.TestSuite([established,added])
        result=unittest.TextTestRunner(stream=log,verbosity=2).run(suite)
    text=log.getvalue();(OUT/'tests.log').write_text(text,encoding='utf-8')
    record=dict(passed=result.wasSuccessful(),tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),
                scope='Fake CFG/OT/UART/process/clock and synthetic-gate orchestration only; no board access',
                elapsed_seconds=round(time.monotonic()-began,3),process_creation_prohibited=True,
                actual_hardware_access=False,actual_programs=0,actual_UART_or_JTAG_connections=0,
                runtime_dependencies=module.b.runtime_dependencies(),
                established_cases=81,cleanup_lifecycle_cases=27,
                source_sha256={str(p.relative_to(ROOT)):sha(p) for p in
                    [ROOT/'tools/run_ai_camera_board.py',ROOT/'host/native_cfg.py',ROOT/'host/native_ot_observer.py',
                     ROOT/'host/native_client_lifecycle.py',ROOT/'host/native_server_lifecycle.py',TEST,extra_path,Path(__file__)]},
                test_log_path=str(OUT/'tests.log'),test_log_sha256=sha(OUT/'tests.log'),python_executable=sys.executable,python_version=sys.version)
    (OUT/'result.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    print(text[-1500:]);print('AI_BOARD_OFFLINE_TESTS',record['passed'],record['tests'])
    return 0 if record['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
