"""Fake-only checks for early READY capture, execution truth and P/V ownership."""
from pathlib import Path
import importlib.util
import json
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('current_coremark_foundation_tests',ROOT/'sim/ai_board_control/test_ai_board_control.py')
f=importlib.util.module_from_spec(spec);sys.modules[spec.name]=f;spec.loader.exec_module(f)
b=f.b


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.run=Path(self.temp.name)
        self.events=[];self.clock=f.Clock();self.cfg=f.CFG(self.events)
        bit=self.run/'ai_camera_frozen.sbit';bit.write_bytes(b'FAKE_ONLY')
        self.binding={'bitstream_sha256':b.sha(bit)}
        self.serial=f.Serial(self.events)
    def tearDown(self):self.temp.cleanup()
    def execute(self,workload,opener=None):
        def observer(*args,**kw):return f.Observer(*args,**kw,events=self.events)
        def opened(port):self.events.append('UART_open');return self.serial
        return b.Controller(self.run,self.binding,cfg=self.cfg,observer_factory=observer,
            workload=workload,serial_opener=opener or opened,client_check=lambda run:{'stopped':True},
            clock=self.clock,sleeper=self.clock.sleep,display_hold_seconds=0).execute()
    def test_UART_armed_before_program_preserves_ready(self):
        original=self.cfg.program
        def program(bit,check):
            result=original(bit,check);self.serial.data.extend(b'READY_DURING_PROGRAM\n');return result
        self.cfg.program=program
        def work(link,run,check,progress_callback=None):
            received=b''
            for _ in range(64):
                received+=link.read(100)
                if len(received)>=len(b'READY_DURING_PROGRAM\n'):break
            self.assertEqual(received,b'READY_DURING_PROGRAM\n');return {'passed':True}
        result=self.execute(work)
        self.assertTrue(result['passed']);self.assertLess(self.events.index('UART_open'),self.events.index('program'))
        self.assertEqual((self.run/'raw_tx.bin').read_bytes(),b'')
    def test_invalid_program_status_sends_no_command(self):
        self.cfg.program_ot=True
        result=self.execute(lambda *a,**k:self.fail('Workload reached after invalid program status'))
        self.assertFalse(result['passed']);self.assertEqual((self.run/'raw_tx.bin').read_bytes(),b'')
        self.assertEqual(self.cfg.programs,1);self.assertEqual(self.cfg.resets,1)
    def test_begin_then_failure_keeps_execution_true_and_clears(self):
        def work(link,run,check,progress_callback=None):
            progress_callback({'event':'begin'});raise ValueError('Synthetic later transcript failure')
        result=self.execute(work)
        self.assertFalse(result['passed']);self.assertTrue(result['coremark_executed'])
        self.assertTrue(result['sram_clear_verified']);self.assertEqual(self.cfg.programs,1)
    def test_no_begin_keeps_execution_false(self):
        result=self.execute(lambda *a,**k:{'passed':True})
        self.assertTrue(result['passed']);self.assertFalse(result['coremark_executed'])
    def test_serial_open_failure_never_programs(self):
        def failed(port):raise OSError('Synthetic occupied UART')
        result=self.execute(lambda *a,**k:self.fail('Unexpected workload'),failed)
        self.assertFalse(result['passed']);self.assertEqual(self.cfg.programs,0)
        self.assertTrue(result['no_program_attempted'])
    def test_mode_is_part_of_exact_child_identity(self):
        with patch.object(b,'MODE','P'):p=b.command('controller',self.run)
        owner=dict(cmdline=p,exe=sys.executable,cwd=str(self.run),pid=123,create_time=1.)
        with patch.object(b,'MODE','P'):self.assertTrue(b.allowed_role(self.run,owner,'controller'))
        with patch.object(b,'MODE','V'):
            self.assertFalse(b.allowed_role(self.run,owner,'controller'))
            self.assertEqual(b.command('controller',self.run)[-2:],['--mode','V'])
    def test_adapter_forwards_frozen_source_and_mode(self):
        sys.path.insert(0,str(ROOT/'host'))
        import coremark_workload as w
        expected=json.loads((ROOT/'identity.json').read_text(encoding='utf8'))['source_id']
        def fake(mode,link,out,**kw):
            self.assertEqual(mode,'V');self.assertEqual(kw['source_id'],expected)
            self.assertFalse(kw['cancel_check']())
            return dict(passed=True,coremark_executed=True,cycles=1_500_000_000,iterations=5000,cpu_hz=100_000_000)
        with patch.object(w,'run_case',fake):result=w.run_workload(object(),self.run,lambda:None,mode='V')
        self.assertTrue(result['passed']);self.assertFalse(result['AI_RUN_sent'])


if __name__=='__main__':unittest.main()
