"""Fake-only board orchestration tests; never import runtime or open devices."""
from pathlib import Path
import copy
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ai_board_under_test',ROOT/'tools/run_ai_camera_board.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)


def cleared(source='controller',raw='0x00180c80'):
    n=int(raw,16)
    return dict(source=source,sram_clear_verified=True,status=dict(raw=raw,over_temp=bool(n&(1<<27)),
                done=bool(n&(1<<12)),done_i=bool(n&(1<<13)),crc_error=bool(n&2),id_error=bool(n&1)))


class Clock:
    def __init__(self):self.t=10.;self.sleep_hook=None
    def __call__(self):return self.t
    def sleep(self,seconds):
        self.t+=seconds
        if self.sleep_hook:self.sleep_hook()


class Serial:
    def __init__(self,events=(),rx=b''):
        self.events=events;self.data=bytearray(rx);self.closed=False;self.out_waiting=0
    def read(self,n):
        if self.data:
            out=bytes(self.data[:n]);del self.data[:n];return out
        time.sleep(.001);return b''
    def write(self,data):return len(data)
    def close(self):self.closed=True;self.events.append('UART_closed')


class CFG:
    def __init__(self,events,*,baseline_ot=False,program_ot=False,reset_raw='0x00180c80'):
        self.events=events;self.programs=0;self.resets=0;self.baseline_ot=baseline_ot;self.program_ot=program_ot;self.reset_raw=reset_raw
    def baseline(self,check):
        check();self.events.append('baseline');return dict(over_temp=self.baseline_ot,crc_error=False,id_error=False)
    def program(self,bit,check):
        check();self.events.append('program');self.programs+=1
        return dict(over_temp=self.program_ot,done=True,done_i=True,crc_error=False,id_error=False)
    def reset(self,source):self.events.append('reset');self.resets+=1;return cleared(source,self.reset_raw)


class Observer:
    def __init__(self,run,port,cfg,on_fault,*,events,stopped=True,fault=None,samples=2):
        self.events=events;self.stopped=stopped;self.fault=fault;self.on_fault=on_fault;self.samples=samples
    def start(self):self.events.append('observer_start');return self
    def check(self):
        if self.fault:self.on_fault(self.fault);raise b.BoardError(self.fault)
    def stop(self,*,complete_current=False,check=None):
        if complete_current:check()
        self.events.append('observer_stop');return dict(stopped=self.stopped,fault=self.fault,sample_count=self.samples)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)/'candidate';self.root.mkdir()
        def put(name,text):
            p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text,encoding='utf-8')
        self.put=put
        put('tools/run_ai_camera_board.py',b.SCRIPT.read_text(encoding='utf-8'))
        put('host/native_cfg.py',(b.ROOT/'host/native_cfg.py').read_text(encoding='utf-8'))
        shutil.copy2(b.ROOT/'host/native_cfg.py',self.root/'host/native_cfg.py')
        for name in ['native_ot_observer.py','native_client_lifecycle.py','native_server_lifecycle.py']:
            shutil.copy2(b.ROOT/'host'/name,self.root/'host'/name)
        put('host/coremark_workload.py','# fake-only gate fixture\n')
        put('src/top.v','module top;endmodule\n');put('src/firmware/production.bin','FAKE_NOT_A_BITSTREAM')
        put('constraints/test.fdc','# fixture\n');put('identity.json',json.dumps({'source_id':'0'*64}))
        put('pds/build.tcl','add_design {'+(self.root/'src/top.v').as_posix()+'}\nadd_constraint {'+(self.root/'constraints/test.fdc').as_posix()+'}\n')
        put('pds/fake.sbit','FAKE_TEST_ONLY')
        cats=['functional','timing','rom','cdc','host_workload','board_controls']
        proofs={cat:'evidence/'+cat+'.json' for cat in cats}
        for name in proofs.values():put(name,json.dumps(dict(passed=True,synthetic_test_fixture=True)))
        files={p.relative_to(self.root).as_posix():b.sha(p) for p in self.root.rglob('*') if p.is_file() and p.suffix not in ('.sbit',)}
        proof_hashes={name:b.sha(self.root/name) for name in proofs.values()}
        self.gate=dict(schema=b.SCHEMA,passed=True,scope=b.SCOPE,candidate_root=str(self.root),
                       source_hashes=files,proof_hashes=proof_hashes,required_proofs=proofs,
                       dependency_hashes=b.runtime_dependencies(self.root),
                       bitstream=dict(path='pds/fake.sbit',sha256=b.sha(self.root/'pds/fake.sbit')))
        self.publish()
    def tearDown(self):self.tmp.cleanup()
    def publish(self):self.put('evidence/BOARD_GATE.json',json.dumps(self.gate))
    def reject(self):
        with self.assertRaises((b.BoardError,FileNotFoundError,ValueError)):
            with patch.object(b,'load_runtime',side_effect=AssertionError('No runtime import allowed')):
                b.qualified(self.root)
    def test_valid_file_only_gate(self):
        with patch.object(b.subprocess,'Popen',side_effect=AssertionError('No process startup')):
            bit,binding=b.qualified(self.root)
        self.assertEqual(bit,self.root/'pds/fake.sbit');self.assertEqual(binding['scope'],b.SCOPE)
    def test_missing_gate(self):
        (self.root/'evidence/BOARD_GATE.json').unlink();self.reject()
    def test_false_non_boolean_and_old_scope(self):
        for key,value in [('passed',False),('passed',1),('scope','J5_CPU_LOAD_20261030'),('schema','old'),('candidate_root',str(self.root.parent))]:
            old=self.gate[key];self.gate[key]=value;self.publish();self.reject();self.gate[key]=old
    def test_source_change(self):self.put('src/top.v','changed');self.reject()
    def test_omitted_active_source(self):
        del self.gate['source_hashes']['src/top.v'];self.publish();self.reject()
    def test_proof_not_passed(self):
        name='evidence/timing.json';self.put(name,json.dumps(dict(passed=False)))
        digest=b.sha(self.root/name);self.gate['source_hashes'][name]=digest;self.gate['proof_hashes'][name]=digest;self.publish();self.reject()
    def test_required_proof_categories(self):
        del self.gate['required_proofs']['rom'];self.publish();self.reject()
    def test_proof_categories_not_generic_one_file(self):
        self.gate['required_proofs']={k:'evidence/rom.json' for k in self.gate['required_proofs']};self.publish();self.reject()
    def test_dependency_change(self):
        self.gate['dependency_hashes'].pop(next(iter(self.gate['dependency_hashes'])));self.publish();self.reject()
    def test_escaped_source(self):
        self.gate['source_hashes']['../outside']='0'*64;self.publish();self.reject()
    def test_bitstream_change(self):self.put('pds/fake.sbit','changed');self.reject()
    def test_gate_rejection_precedes_run_mkdir_and_devices(self):
        before=set(self.root.rglob('*'))
        with (patch.object(b,'qualified',side_effect=b.BoardError('Rejected fixture gate')),
              patch.object(b,'load_runtime',side_effect=AssertionError('Runtime accessed'))):
            with self.assertRaises(b.BoardError):b.run_board()
        self.assertEqual(before,set(self.root.rglob('*')))


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.run=Path(self.tmp.name);self.events=[];self.clock=Clock()
        self.bit=self.run/'ai_camera_frozen.sbit';self.bit.write_bytes(b'FAKE_TEST_ONLY')
        self.binding=dict(bitstream_sha256=b.sha(self.bit));self.cfg=CFG(self.events)
    def tearDown(self):self.tmp.cleanup()
    def execute(self,*,observer_options=None,workload=None,client_ok=True,opener=None):
        options=observer_options or {}
        def observer(*args,**kw):return Observer(*args,**kw,events=self.events,**options)
        def normal(link,run,check,progress_callback=None):
            check();self.events.append('RUN');progress_callback(dict(nodes=119,stage='fake_only'))
            link.write(b'one_fake_RUN');return dict(passed=True,synthetic_test_fixture=True)
        def clients(run):self.events.append('clients_checked');return dict(stopped=client_ok)
        c=b.Controller(self.run,self.binding,cfg=self.cfg,observer_factory=observer,workload=workload or normal,
                       serial_opener=opener or (lambda port:Serial(self.events)),client_check=clients,clock=self.clock,sleeper=self.clock.sleep)
        self.controller=c;return c.execute()
    def test_success_one_program_clear_order(self):
        r=self.execute();self.assertTrue(r['passed']);self.assertEqual(self.cfg.programs,1);self.assertEqual(self.cfg.resets,1)
        self.assertEqual(self.events.count('RUN'),1)
        self.assertLess(self.events.index('UART_closed'),self.events.index('reset'))
        self.assertLess(self.events.index('observer_stop'),self.events.index('clients_checked'))
        self.assertLess(self.events.index('clients_checked'),self.events.index('reset'))
    def test_real_result_has_at_most_ten_seconds_to_observe(self):
        r=self.execute();self.assertTrue(r['passed'])
        self.assertAlmostEqual(r['result_display']['planned_seconds'],10.)
        self.assertAlmostEqual(r['result_display']['observed_seconds'],10.)
        self.assertEqual(r['result_display']['deadline_seconds_unchanged'],285)
        self.assertEqual(self.events.count('RUN'),1)
    def test_result_hold_skipped_with_two_seconds_budget_left(self):
        def work(*args,**kwargs):self.clock.t+=b.ACTIVE_MAX-2;return dict(passed=True)
        r=self.execute(workload=work);self.assertTrue(r['passed'])
        self.assertEqual(r['result_display']['planned_seconds'],0.)
    def test_result_hold_skips_for_natural_completion_budget(self):
        def work(*args,**kwargs):self.clock.t+=b.ACTIVE_MAX-8;return dict(passed=True)
        r=self.execute(workload=work);self.assertTrue(r['passed'])
        self.assertAlmostEqual(r['result_display']['planned_seconds'],0.)
        self.assertLess(self.clock.t-self.controller.program_started,b.ACTIVE_MAX)
    def test_result_hold_reserves_twenty_seconds_drain_and_three_seconds_headroom(self):
        def work(*args,**kwargs):self.clock.t+=b.ACTIVE_MAX-30;return dict(passed=True)
        r=self.execute(workload=work);self.assertTrue(r['passed'])
        self.assertAlmostEqual(r['result_display']['planned_seconds'],7.)
        self.assertEqual(r['result_display']['reserved_cleanup_seconds'],23.)
    def test_late_result_can_drain_pending_status_before_active_deadline(self):
        def work(*args,**kwargs):self.clock.t+=b.ACTIVE_MAX-8;return dict(passed=True)
        original=Observer.stop
        def pending_status(observer,*,complete_current=False,check=None):
            if complete_current:
                self.clock.sleep(5.)
                check()
            return original(observer,complete_current=complete_current,check=check)
        with patch.object(Observer,'stop',pending_status):r=self.execute(workload=work)
        self.assertTrue(r['passed'],r)
        self.assertEqual(self.cfg.resets,1)
        self.assertLess(self.clock.t-self.controller.program_started,b.ACTIVE_MAX)
    def test_STOP_while_showing_result_stops_and_clears(self):
        self.clock.sleep_hook=lambda:(self.run/'STOP').write_text('user stop during result',encoding='utf-8')
        r=self.execute();self.assertFalse(r['passed']);self.assertEqual(self.cfg.resets,1)
        self.assertEqual(self.events.count('RUN'),1)
        self.assertLess(self.events.index('observer_stop'),self.events.index('reset'))
    def test_OT_while_showing_result_stops_and_clears(self):
        def trip():self.controller.observer.fault='over_temp=1 during real result'
        self.clock.sleep_hook=trip
        r=self.execute();self.assertFalse(r['passed']);self.assertEqual(self.cfg.resets,1)
        self.assertIn('over_temp',r['error'])
    def test_oversleep_cannot_extend_active_deadline(self):
        self.clock.sleep_hook=lambda:setattr(self.clock,'t',self.clock.t+b.ACTIVE_MAX)
        r=self.execute();self.assertFalse(r['passed']);self.assertEqual(self.cfg.resets,1)
        self.assertIn('285s',r['error'])
    def test_baseline_OT_blocks_program(self):
        self.cfg.baseline_ot=True;r=self.execute();self.assertFalse(r['passed']);self.assertEqual(self.cfg.programs,0)
    def test_program_OT_stops_before_RUN(self):
        self.cfg.program_ot=True;r=self.execute();self.assertFalse(r['passed']);self.assertNotIn('RUN',self.events);self.assertEqual(self.cfg.programs,1)
    def test_observer_fault_stops_and_clears(self):
        r=self.execute(observer_options=dict(fault='over_temp=1'));self.assertFalse(r['passed']);self.assertNotIn('RUN',self.events)
        self.assertTrue((self.run/'STOP').exists());self.assertEqual(self.cfg.resets,1)
    def test_observer_client_not_stopped_blocks_reset(self):
        r=self.execute(observer_options=dict(stopped=False));self.assertFalse(r['passed']);self.assertEqual(self.cfg.resets,0)
    def test_missing_native_client_exit_blocks_reset(self):
        r=self.execute(client_ok=False);self.assertFalse(r['passed']);self.assertEqual(self.cfg.resets,0)
    def test_no_OT_sample_cannot_pass(self):
        r=self.execute(observer_options=dict(samples=0));self.assertFalse(r['passed']);self.assertEqual(self.cfg.resets,1)
    def test_active_budget_from_program_start(self):
        def work(link,run,check,progress_callback=None):self.clock.t+=b.ACTIVE_MAX;check();return dict(passed=True)
        r=self.execute(workload=work);self.assertFalse(r['passed']);self.assertIn('285s',r['error']);self.assertEqual(self.cfg.programs,1)
    def test_STOP_cancels_without_retries(self):
        def work(link,run,check,progress_callback=None):(run/'STOP').write_text('operator');check()
        r=self.execute(workload=work);self.assertFalse(r['passed']);self.assertEqual(self.cfg.programs,1);self.assertEqual(self.cfg.resets,1)
    def test_workload_exception_not_retried(self):
        count=[]
        def work(*args,**kwargs):count.append(1);raise ValueError('bad CRC')
        r=self.execute(workload=work);self.assertFalse(r['passed']);self.assertEqual(len(count),1);self.assertEqual(self.cfg.resets,1)
    def test_exact_clear_raw_required(self):
        self.cfg.reset_raw='0x08180c80';r=self.execute();self.assertFalse(r['passed']);self.assertFalse(r['sram_clear_verified'])
    def test_progress_write_failure_does_not_skip_safe_cleanup(self):
        original=b.write_json
        def publish(path,record):
            if Path(path).name=='cleanup_started.json':raise OSError('fake evidence write failure')
            return original(path,record)
        with patch.object(b,'write_json',side_effect=publish):r=self.execute()
        self.assertFalse(r['passed']);self.assertTrue(r['sram_clear_verified']);self.assertEqual(self.cfg.resets,1)
    def test_queue_preserves_startup_bytes_and_records_TX(self):
        raw=Serial(self.events,rx=b'early_boot_and_ack')
        def work(link,run,check,progress_callback=None):
            got=b''
            for _ in range(20):
                got+=link.read(7)
                if len(got)==18:break
            self.assertEqual(got,b'early_boot_and_ack');link.write(b'RUNONCE');link.flush();return dict(passed=True)
        r=self.execute(workload=work,opener=lambda port:raw);self.assertTrue(r['passed'])
        self.assertEqual((self.run/'raw_rx.bin').read_bytes(),b'early_boot_and_ack')
        self.assertEqual((self.run/'raw_tx.bin').read_bytes(),b'RUNONCE')


class PolicyTests(unittest.TestCase):
    def test_heartbeat_and_cleanup_grace(self):
        p=b.WatchdogPolicy(0)
        self.assertEqual(p.step(8,heartbeat_age=8,program_started=0,stop=False,alive=True,cleared=False),'notify')
        self.assertEqual(p.step(37.9,heartbeat_age=8,program_started=0,stop=False,alive=True,cleared=False),'wait')
        self.assertEqual(p.step(38,heartbeat_age=8,program_started=0,stop=False,alive=True,cleared=False),'fallback')
    def test_active_deadline(self):
        p=b.WatchdogPolicy(0)
        self.assertEqual(p.step(294.9,heartbeat_age=0,program_started=10,stop=False,alive=True,cleared=False),'wait')
        self.assertEqual(p.step(295,heartbeat_age=0,program_started=10,stop=False,alive=True,cleared=False),'notify')
    def test_total_budget_reserves_cleanup_before390(self):
        p=b.WatchdogPolicy(0)
        self.assertEqual(p.step(315,heartbeat_age=0,program_started=100,stop=False,alive=True,cleared=False),'notify')
        self.assertEqual(p.step(345,heartbeat_age=0,program_started=100,stop=False,alive=True,cleared=False),'fallback')
        self.assertLess(345+8+4+20,b.WATCHDOG_MAX)
    def test_normal_cleanup_after_workload_deadline_is_not_cancelled(self):
        p=b.WatchdogPolicy(0)
        self.assertEqual(p.step(286,heartbeat_age=0,program_started=0,cleanup_started=284,stop=False,alive=True,cleared=False),'wait')
    def test_hung_cleanup_remains_bounded(self):
        p=b.WatchdogPolicy(0)
        self.assertEqual(p.step(314,heartbeat_age=0,program_started=0,cleanup_started=284,stop=False,alive=True,cleared=False),'notify')
        self.assertEqual(p.step(344,heartbeat_age=0,program_started=0,cleanup_started=284,stop=False,alive=True,cleared=False),'fallback')
    def test_dead_controller_immediate_takeover(self):
        p=b.WatchdogPolicy(0);self.assertEqual(p.step(1,heartbeat_age=0,program_started=0,stop=False,alive=False,cleared=False),'fallback')
    def test_no_program_start_has_bound(self):
        p=b.WatchdogPolicy(0);self.assertEqual(p.step(60,heartbeat_age=0,program_started=None,stop=False,alive=True,cleared=False),'notify')
    def test_only_controller_success_and_normal_watchdog_pass(self):
        args=[dict(passed=True),dict(verified=True),True,dict(passed=True,fallback_reset_attempted=False,notified_monotonic=None),0,0]
        self.assertTrue(b.completion_ok(*args))
        for index in range(len(args)):
            changed=copy.deepcopy(args)
            if index in (0,3):changed[index]['passed']=False
            elif index==1:changed[index]['verified']=False
            elif index==2:changed[index]=False
            else:changed[index]=1
            self.assertFalse(b.completion_ok(*changed))
        self.assertFalse(b.completion_ok(*args,cancelled=True));self.assertFalse(b.completion_ok(*args,supervision_error=True))
        args[3]['fallback_reset_attempted']=True;self.assertFalse(b.completion_ok(*args))
    def test_fallback_never_resets_before_verified_termination(self):
        events=[];cfg=CFG(events)
        r=b.fallback(Path('.'),None,'watchdog',terminator=lambda run:[dict(stopped=False)],cfg=cfg)
        self.assertFalse(r['passed']);self.assertEqual(cfg.resets,0)
        r=b.fallback(Path('.'),None,'watchdog',terminator=lambda run:[dict(stopped=True)],cfg=cfg)
        self.assertTrue(r['passed']);self.assertEqual(cfg.resets,1)


class Process:
    def __init__(self,owner,ppid=0,children=()):self.owner=owner;self.pid=owner['pid'];self.parent=ppid;self.kids=list(children);self.alive=True;self.suspended=False
    def create_time(self):return self.owner['create_time']
    def exe(self):return self.owner['exe']
    def cmdline(self):return self.owner['cmdline']
    def cwd(self):return self.owner['cwd']
    def ppid(self):return self.parent
    def is_running(self):return self.alive
    def children(self,recursive=True):return self.kids
    def suspend(self):self.suspended=True
    def resume(self):self.suspended=False


class ForeignBirthOnly:
    """The completed PID's new occupant must not be inspected or stopped."""
    def __init__(self,pid,birth):self.pid,self.birth=pid,birth
    def create_time(self):return self.birth
    def __getattr__(self,name):raise AssertionError('Foreign process touched: '+name)


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.run=Path(self.tmp.name);self.procs={};self.stops=[]
        self.owner=dict(pid=100,create_time=10.,exe=sys.executable,cmdline=b.command('controller',self.run),cwd=str(self.run))
        self.parent=Process(self.owner);self.procs[100]=self.parent;b.write_json(self.run/'controller_owner.json',self.owner)
    def tearDown(self):self.tmp.cleanup()
    def lookup(self,pid):
        if pid not in self.procs or not self.procs[pid].alive:raise ProcessLookupError(pid)
        return self.procs[pid]
    def stop(self,owner,lookup):
        if b.exact_process(owner,lookup) is None:
            try:lookup(owner['pid']);exists=True
            except ProcessLookupError:exists=False
            return dict(stopped=not exists,pid=owner['pid'])
        self.stops.append(owner['pid']);self.procs[owner['pid']].alive=False;return dict(stopped=True,pid=owner['pid'])
    def client(self,pid=101,parent=100,foreign=False,register=True):
        folder=self.run/'native'/'ot_poll_00000';folder.mkdir(parents=True,exist_ok=True)
        path=folder/'command.tcl';path.write_text('FAKE_NO_HARDWARE')
        cmd=[str(b.native.SHELL),'-file',str(path),'-work_dir',str(folder)]
        row=dict(pid=pid,create_time=11.,exe=str(b.native.SHELL),cmdline=cmd,cwd=str(folder))
        if foreign:row['cwd']=str(self.run.parent)
        proc=Process(row,ppid=parent);self.procs[pid]=proc
        if register:b.write_json(folder/'ownership.json',row)
        return proc
    def run_stop(self):return b.stop_registered(self.run,process_factory=self.lookup,process_iter=lambda:list(self.procs.values()),stop_fn=self.stop)
    def test_exact_controller_and_native_stopped_only(self):
        client=self.client();self.parent.kids=[client]
        rows=self.run_stop();self.assertTrue(all(r['stopped'] for r in rows));self.assertEqual(self.stops,[100,101])
    def test_reused_controller_PID_not_touched(self):
        self.procs[100]=Process(dict(self.owner,create_time=20.))
        rows=self.run_stop();self.assertFalse(rows[-1]['stopped']);self.assertEqual(self.stops,[])
    def test_foreign_JTAG_descendant_refused_before_kill(self):
        client=self.client(foreign=True,register=False);self.parent.kids=[client]
        rows=self.run_stop();self.assertFalse(rows[-1]['stopped']);self.assertEqual(self.stops,[]);self.assertFalse(self.parent.suspended)
    def test_dead_controller_unregistered_native_child_discovered(self):
        self.parent.alive=False;self.client(register=False)
        rows=self.run_stop();self.assertTrue(all(r['stopped'] for r in rows));self.assertEqual(self.stops,[101])
    def test_unrelated_process_untouched(self):
        self.parent.alive=False;foreign=self.client(parent=777,register=False)
        rows=self.run_stop();self.assertTrue(all(r['stopped'] for r in rows));self.assertTrue(foreign.alive);self.assertEqual(self.stops,[])
    def test_reused_native_PID_blocks_cleanup(self):
        client=self.client();self.parent.kids=[]
        self.procs[client.pid]=Process(dict(client.owner,create_time=30.))
        rows=self.run_stop();self.assertFalse(rows[-1]['stopped']);self.assertEqual(self.stops,[100])
    def test_reused_native_PID_with_recorded_exit_is_completed_without_touching_foreign(self):
        client=self.client();original=copy.deepcopy(client.owner)
        folder=self.run/'native/ot_poll_00000'
        b.write_json(folder/'process_result.json',dict(owner=original,returncode=0))
        foreign=Process(dict(original,create_time=30.,exe='C:/Windows/System32/conhost.exe',
                             cmdline=['conhost.exe','foreign'],cwd=str(self.run.parent)))
        self.procs[client.pid]=foreign;self.parent.kids=[]
        self.assertTrue(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])
        rows=self.run_stop();self.assertTrue(all(r['stopped'] for r in rows))
        self.assertEqual(self.stops,[100]);self.assertTrue(foreign.alive)
    def test_recorded_exit_reused_PID_does_not_inspect_foreign_attributes_or_stop(self):
        client=self.client();folder=self.run/'native/ot_poll_00000'
        b.write_json(folder/'process_result.json',dict(owner=client.owner,returncode=0))
        self.procs[101]=ForeignBirthOnly(101,30.);self.parent.kids=[]
        lookup=lambda pid:self.procs[pid]if pid in self.procs else (_ for _ in()).throw(ProcessLookupError(pid))
        self.assertTrue(b.clients_stopped(self.run,process_factory=lookup)['stopped'])
        rows=b.stop_registered(self.run,process_factory=lookup,process_iter=lambda:[],stop_fn=self.stop)
        self.assertTrue(all(r['stopped']for r in rows));self.assertEqual(self.stops,[100])
        self.assertTrue(rows[-1]['pid_reused']);self.assertFalse(rows[-1]['foreign_process_touched'])
    def test_recorded_exit_and_absent_native_is_completed(self):
        client=self.client();b.write_json(self.run/'native/ot_poll_00000/process_result.json',dict(owner=client.owner,returncode=0))
        self.procs[101].alive=False
        self.assertTrue(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])
    def test_recorded_nonzero_exit_allows_cleanup_without_functional_success(self):
        client=self.client();b.write_json(self.run/'native/ot_poll_00000/process_result.json',dict(owner=client.owner,returncode=15))
        self.procs[101].alive=False;r=b.clients_stopped(self.run,process_factory=self.lookup)
        self.assertTrue(r['stopped']);self.assertEqual(r['children'][0]['returncode'],15)
        self.assertNotIn('passed',r)
    def test_same_birth_attribute_mismatch_blocks_native_cleanup(self):
        client=self.client();original=copy.deepcopy(client.owner)
        b.write_json(self.run/'native/ot_poll_00000/process_result.json',dict(owner=original,returncode=0))
        for key,value in [('exe','C:/Windows/System32/conhost.exe'),('cmdline',['foreign']),('cwd',str(self.run.parent))]:
            with self.subTest(field=key):
                self.parent.alive=True;self.parent.kids=[];self.stops.clear()
                foreign=Process(dict(original,**{key:value}));self.procs[101]=foreign
                self.assertFalse(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])
                rows=self.run_stop();self.assertFalse(rows[-1]['stopped']);self.assertEqual(self.stops,[100]);self.assertTrue(foreign.alive)
    def test_absent_native_without_exit_provenance_blocks_takeover(self):
        self.client();self.procs[101].alive=False
        rows=self.run_stop();self.assertFalse(rows[-1]['stopped']);self.assertEqual(self.stops,[100])
    def test_reused_native_with_mismatched_exit_owner_blocks_takeover(self):
        client=self.client();original=copy.deepcopy(client.owner)
        b.write_json(self.run/'native/ot_poll_00000/process_result.json',dict(owner=dict(original,create_time=12.),returncode=0))
        foreign=Process(dict(original,create_time=30.));self.procs[101]=foreign;self.parent.kids=[]
        self.assertFalse(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])
        rows=self.run_stop();self.assertFalse(rows[-1]['stopped']);self.assertEqual(self.stops,[100]);self.assertTrue(foreign.alive)
    def test_recorded_exit_with_same_live_identity_still_requires_stop(self):
        client=self.client();b.write_json(self.run/'native/ot_poll_00000/process_result.json',dict(owner=client.owner,returncode=0))
        self.assertFalse(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])
        self.parent.kids=[client];rows=self.run_stop()
        self.assertTrue(all(r['stopped']for r in rows));self.assertEqual(self.stops,[100,101])
    def test_dead_watchdog_orphan_is_also_stopped(self):
        self.parent.alive=False
        watch=dict(pid=200,create_time=10.5,exe=sys.executable,cmdline=b.command('watchdog',self.run),cwd=str(self.run))
        b.write_json(self.run/'watchdog_owner.json',watch);self.client(parent=200,register=False)
        rows=self.run_stop();self.assertTrue(all(r['stopped'] for r in rows));self.assertEqual(self.stops,[101])
    def test_live_other_watchdog_blocks_outer_takeover(self):
        watch=dict(pid=200,create_time=10.5,exe=sys.executable,cmdline=b.command('watchdog',self.run),cwd=str(self.run))
        b.write_json(self.run/'watchdog_owner.json',watch);self.procs[200]=Process(watch)
        rows=self.run_stop();self.assertFalse(rows[-1]['stopped']);self.assertEqual(self.stops,[]);self.assertFalse(self.parent.suspended)
    def test_native_exit_record_missing_blocks_reset(self):
        self.client();self.procs[101].alive=False
        self.assertFalse(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])
    def test_missing_owner_folder_not_silently_ignored(self):
        self.client(register=False)
        self.assertFalse(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])
    def test_explicit_OT_before_spawn_cancellation_can_stop(self):
        self.client(register=False);self.procs[101].alive=False
        folder=self.run/'native_ot_observer';folder.mkdir()
        (folder/'samples.jsonl').write_text(json.dumps(dict(label='ot_poll_00000',cancelled=True))+'\n')
        self.assertTrue(b.clients_stopped(self.run,process_factory=self.lookup)['stopped'])


class LocalObserverCompletionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.run=Path(self.tmp.name);self.folder=self.run/'native/ot_poll_00000';self.folder.mkdir(parents=True)
        self.cfg=type('CFGIdentity',(),dict(run=self.run,port=65446))();self.faults=[];self.processes={}
        self.module=b.load_module('local_ot_under_test',ROOT/'host/native_ot_observer.py')
        self.observer=self.module.NativeOTObserver(self.run,65446,self.cfg,self.faults.append,process_factory=self.lookup)
        self.observer.attempts=[dict(label='ot_poll_00000',read_succeeded=True)]
        script=self.folder/'command.tcl';script.write_text('FAKE_ONLY_NO_DEVICE')
        self.owner=dict(pid=101,create_time=11.,exe=str(b.native.SHELL),cwd=str(self.folder),
                        cmdline=[str(b.native.SHELL),'-file',str(script),'-work_dir',str(self.folder)])
        b.write_json(self.folder/'ownership.json',self.owner)
        self.done=dict(owner=self.owner,returncode=0);b.write_json(self.folder/'process_result.json',self.done)
    def tearDown(self):self.tmp.cleanup()
    def lookup(self,pid):
        if pid not in self.processes:raise ProcessLookupError(pid)
        return self.processes[pid]
    def test_local_observer_uses_local_native_and_lifecycle(self):
        self.assertEqual(Path(self.module.native.__file__).resolve(),ROOT/'host/native_cfg.py')
        self.assertEqual(Path(self.module.lifecycle.__file__).resolve(),ROOT/'host/native_client_lifecycle.py')
        self.assertEqual(b.sha(ROOT/'host/native_cfg.py'),b.sha(b.PARENT/'host/native_cfg.py'))
        deps=b.runtime_dependencies();self.assertIn(str((ROOT/'host/native_ot_observer.py').resolve()),deps)
        self.assertIn(str((ROOT/'host/native_client_lifecycle.py').resolve()),deps)
        self.assertFalse(any('J5_CPU_SOAK' in name for name in deps))
    def test_observer_recorded_exit_absent(self):
        r=self.observer.stop();self.assertTrue(r['stopped']);self.assertEqual(self.faults,[])
    def test_observer_recorded_exit_PID_reused_foreign_untouched(self):
        self.processes[101]=ForeignBirthOnly(101,30.)
        r=self.observer.stop();self.assertTrue(r['stopped']);self.assertTrue(r['children'][0]['pid_reused']);self.assertEqual(self.faults,[])
    def test_observer_same_birth_foreign_attributes_block_even_inactive(self):
        p=Process(dict(self.owner,exe='C:/Windows/System32/conhost.exe'));p.alive=False;self.processes[101]=p
        r=self.observer.stop();self.assertFalse(r['stopped']);self.assertEqual(r['children'][0]['reason'],'same_birth_process_identity_mismatch')
    def test_observer_same_live_process_blocks(self):
        self.processes[101]=Process(self.owner);self.assertFalse(self.observer.stop()['stopped'])
    def test_observer_missing_exit_blocks_absent_and_reused(self):
        (self.folder/'process_result.json').unlink()
        for occupant in [None,ForeignBirthOnly(101,30.)]:
            with self.subTest(reused=occupant is not None):
                self.processes={}if occupant is None else{101:occupant}
                self.assertFalse(self.observer.stop()['stopped'])
    def test_observer_mismatched_exit_owner_blocks(self):
        b.write_json(self.folder/'process_result.json',dict(owner=dict(self.owner,create_time=12.),returncode=0))
        self.processes[101]=ForeignBirthOnly(101,30.);self.assertFalse(self.observer.stop()['stopped'])
    def test_observer_exit_returncode_requires_integer_not_boolean(self):
        for code in [None,True,'0']:
            with self.subTest(returncode=code):
                b.write_json(self.folder/'process_result.json',dict(owner=self.owner,returncode=code))
                self.assertFalse(self.observer.stop()['stopped'])
    def test_observer_nonzero_integer_exit_is_completed(self):
        b.write_json(self.folder/'process_result.json',dict(owner=self.owner,returncode=15))
        self.processes[101]=ForeignBirthOnly(101,30.)
        r=self.observer.stop();self.assertTrue(r['stopped']);self.assertEqual(r['children'][0]['returncode'],15)
    def test_observer_missing_owner_without_cancellation_blocks(self):
        (self.folder/'ownership.json').unlink();self.assertFalse(self.observer.stop()['stopped'])
    def test_observer_cancelled_before_spawn_is_completed(self):
        (self.folder/'ownership.json').unlink();self.observer.attempts=[dict(label='ot_poll_00000',cancelled=True)]
        self.assertTrue(self.observer.stop()['stopped'])
    def test_observer_live_worker_blocks_without_process_probe(self):
        class LiveThread:
            def join(self,timeout):self.timeout=timeout
            def is_alive(self):return True
        self.observer.thread=LiveThread();self.observer.process_factory=lambda pid:(_ for _ in()).throw(AssertionError('Unexpected process lookup'))
        r=self.observer.stop();self.assertFalse(r['stopped']);self.assertFalse(r['thread_stopped']);self.assertEqual(r['children'],[])
    def test_unavailable_process_observation_blocks(self):
        self.observer.process_factory=lambda pid:(_ for _ in()).throw(PermissionError('fake denied'))
        self.assertFalse(self.observer.stop()['stopped'])
    def test_invalid_birth_times_do_not_prove_PID_reuse(self):
        for birth in [float('nan'),float('inf'),True,-1]:
            with self.subTest(birth=birth):
                self.processes[101]=ForeignBirthOnly(101,birth)
                self.assertFalse(self.observer.stop()['stopped'])
    def test_changed_birth_during_same_identity_read_blocks(self):
        class ChangingBirth(Process):
            def __init__(self,owner):super().__init__(owner);self.reads=0
            def create_time(self):self.reads+=1;return 11. if self.reads==1 else float('nan')
        self.processes[101]=ChangingBirth(self.owner);self.assertFalse(self.observer.stop()['stopped'])


class LocalObserverControllerCleanupTests(unittest.TestCase):
    def exercise(self,*,deadline=False,same_birth_mismatch=False):
        with tempfile.TemporaryDirectory()as temporary:
            run=Path(temporary);events=[];clock=Clock();processes={};observers=[]
            bit=run/'ai_camera_frozen.sbit';bit.write_bytes(b'FAKE_ONLY_NOT_A_BITSTREAM')
            class CompletedOTCFG(CFG):
                def __init__(self):super().__init__(events);self.run,self.port=run,b.PORT
                def call(self,label,body,timeout,cancel_check):
                    cancel_check();folder=run/'native'/label;folder.mkdir(parents=True)
                    script=folder/'command.tcl';script.write_text('FAKE_NATIVE_COMPLETED_NO_DEVICE')
                    owner=dict(pid=101,create_time=11.,exe=str(b.native.SHELL),cwd=str(folder),
                               cmdline=[str(b.native.SHELL),'-file',str(script),'-work_dir',str(folder)])
                    b.write_json(folder/'ownership.json',owner)
                    b.write_json(folder/'process_result.json',dict(owner=owner,returncode=0))
                    text='PG2L200H\nStatus Register: 0x00183c80\n';(folder/'command.log').write_text(text)
                    processes[101]=Process(dict(owner,exe='C:/Windows/System32/conhost.exe'))if same_birth_mismatch else ForeignBirthOnly(101,30.)
                    events.append('native_exit_recorded');return text
            cfg=CompletedOTCFG()
            module=b.load_module('local_ot_controller_integration',ROOT/'host/native_ot_observer.py')
            def lookup(pid):
                if pid not in processes:raise ProcessLookupError(pid)
                return processes[pid]
            def observer(*args,**kwargs):
                result=module.NativeOTObserver(*args,**kwargs,clock=clock,process_factory=lookup);observers.append(result);return result
            def workload(link,folder,check,progress_callback=None):
                self.assertTrue(observers[0].ready_event.wait(1));check()
                if deadline:clock.t+=b.ACTIVE_MAX;check()
                return dict(passed=True,synthetic_test_fixture=True)
            controller=b.Controller(run,dict(bitstream_sha256=b.sha(bit)),cfg=cfg,observer_factory=observer,
                    workload=workload,serial_opener=lambda port:Serial(events),
                    client_check=lambda folder:b.clients_stopped(folder,process_factory=lookup),clock=clock,sleeper=clock.sleep)
            result=controller.execute();self.assertEqual(cfg.programs,1)
            self.assertIn('native_exit_recorded',events)
            if same_birth_mismatch:
                self.assertFalse(result['passed']);self.assertEqual(cfg.resets,0)
                self.assertFalse(result['native_clients_stopped_before_reset']);self.assertEqual(result['state'],'cleanup_unverified')
            else:
                self.assertTrue(result['OT_stop']['stopped']);self.assertTrue(result['native_clients_stop']['stopped'])
                self.assertTrue(result['native_clients_stopped_before_reset']);self.assertTrue(result['sram_clear_verified']);self.assertEqual(cfg.resets,1)
                self.assertEqual(result['passed'],not deadline)
                if deadline:self.assertIn('285s',result['error']);self.assertEqual(result['state'],'failed_cleared')
            self.assertFalse(observers[0].thread.is_alive())
    def test_normal_controller_clears_after_real_local_observer_reused_PID(self):self.exercise()
    def test_deadline_failure_still_clears_without_becoming_functional_pass(self):self.exercise(deadline=True)
    def test_same_birth_foreign_identity_still_blocks_controller_reset(self):self.exercise(same_birth_mismatch=True)


if __name__=='__main__':unittest.main(verbosity=2)
