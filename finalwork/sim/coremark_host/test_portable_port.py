"""Port routing and exact child ownership across a relocated package."""
from pathlib import Path
import importlib.util,sys,unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('portable_coremark_port_fixture',ROOT/'sim/coremark_host/test_current_integration.py')
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f);b=f.b
class Tests(unittest.TestCase):
    setUp=f.Tests.setUp
    tearDown=f.Tests.tearDown
    execute=f.Tests.execute
    def test_nondefault_port_reaches_serial_open(self):
        seen=[]
        def opened(port):seen.append(port);return self.serial
        with patch.object(b,'UART_PORT','COM27'):
            result=self.execute(lambda *a,**k:{'passed':True},opener=opened)
        self.assertTrue(result['passed']);self.assertEqual(seen,['COM27'])
    def test_port_is_part_of_exact_child_identity(self):
        with patch.object(b,'UART_PORT','COM27'):
            cmd=b.command('controller',self.run);self.assertIn('COM27',cmd)
            owner=dict(cmdline=cmd,exe=sys.executable,cwd=str(self.run),pid=123,create_time=1.)
            self.assertTrue(b.allowed_role(self.run,owner,'controller'))
        self.assertFalse(b.allowed_role(self.run,owner,'controller'))
    def test_invalid_port_rejected_before_qualification(self):
        with patch.object(b,'UART_PORT','COM11'),patch.object(b,'MODE','P'),patch.object(sys,'argv',['runner','--port','COM0']),patch.object(b,'qualified',side_effect=AssertionError('Port must reject before gate/device')):
            with self.assertRaises(b.BoardError):b.main()
if __name__=='__main__':unittest.main()
