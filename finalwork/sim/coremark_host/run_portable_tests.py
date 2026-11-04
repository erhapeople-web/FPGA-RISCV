from pathlib import Path
import hashlib,importlib.util,io,json,subprocess,sys,unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
def main():
    path=Path(__file__).with_name('test_portable_port.py');log=io.StringIO()
    with patch.object(subprocess,'Popen',side_effect=AssertionError('No process or device in offline checks')):
        s=importlib.util.spec_from_file_location('portable_port_tests',path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
        result=unittest.TextTestRunner(stream=log,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(m))
    out=ROOT/'evidence/portable_port_tests';out.mkdir(parents=True,exist_ok=True)
    record=dict(passed=result.wasSuccessful(),tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),process_creation_prohibited=True,hardware_access=False,
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in [path,Path(__file__),ROOT/'tools/run_ai_camera_board.py']})
    (out/'result.json').write_text(json.dumps(record,indent=2),encoding='utf8');(out/'tests.log').write_text(log.getvalue(),encoding='utf8')
    print(log.getvalue());print('PORTABLE_PORT_TESTS',record['passed'],record['tests']);return 0 if record['passed']else 1
if __name__=='__main__':sys.exit(main())
