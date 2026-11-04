"""Synthetic server/PID and in-flight native-status handover regressions.

No serial, JTAG, native executable, port bind, or real process is used.
"""
from pathlib import Path
import copy
import json
import tempfile
import threading
import time
import unittest

from ai_board_offline_tests import b, CFG, Clock, Serial, Process, ForeignBirthOnly, cleared


class ServerCloseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.run=Path(self.temp.name)
        self.exe=self.run/'fake_server.exe';self.exe.write_bytes(b'NOT_EXECUTABLE_FAKE_ONLY')
        self.folder=self.run/'server/generation_000';self.folder.mkdir(parents=True)
        command=[str(self.exe),'-port','65446','-work_dir',str(self.folder)]
        self.owner=dict(pid=101,create_time=100.,exe=str(self.exe),cmdline=command,cwd=str(self.folder))
        self.event=dict(state='own_pid_exited_port_free',pid=101,epoch=102.,monotonic=5.)
        self.generation=dict(owner=self.owner,command=command,exe_sha256=b.sha(self.exe),started_epoch=100.1,
                             observed_exited_epoch=101.9,last_state=self.event)
        b.write_json(self.folder/'ownership.json',self.owner)
        (self.run/'server_lifecycle.jsonl').write_text(json.dumps(self.event)+'\n')
        self.processes={};self.signals=[];self.saved=[];self.listeners=[]
        self.server=type('FakeServer',(),{})()
        self.server.run,self.server.port,self.server.exe=self.run,65446,self.exe
        self.server.generations=[self.generation]
        self.server._proc=self.lookup;self.server._listeners=lambda:self.listeners
        self.server.save=lambda:self.saved.append(True)
    def tearDown(self):self.temp.cleanup()
    def lookup(self,pid):
        if pid not in self.processes:raise ProcessLookupError(pid)
        return self.processes[pid]
    def stop(self,owner,lookup):
        self.assertIsNotNone(b.exact_process(owner,lookup));self.signals.append(owner['pid'])
        self.processes.pop(owner['pid']);self.listeners=[];return dict(stopped=True,pid=owner['pid'])
    def close(self,**kw):
        return b.server_lifecycle.close_server(self.server,cleared=kw.get('cleared',True),
            watchdog_ended=kw.get('watchdog_ended',True),native=b.native,stop_fn=self.stop)
    def test_witnessed_original_exit_reused_PID_foreign_birth_only(self):
        self.processes[101]=ForeignBirthOnly(101,110.)
        r=self.close();self.assertTrue(r['closed']);self.assertTrue(r['generations'][0]['pid_reused'])
        self.assertFalse(r['generations'][0]['foreign_process_touched']);self.assertEqual(self.signals,[])
    def test_witnessed_original_exit_and_absent_PID(self):self.assertTrue(self.close()['closed'])
    def test_reused_PID_without_exit_evidence_is_rejected(self):
        self.processes[101]=ForeignBirthOnly(101,110.);self.generation.pop('observed_exited_epoch')
        self.assertFalse(self.close()['closed']);self.assertEqual(self.signals,[])
    def test_absent_PID_without_exit_evidence_is_rejected(self):
        self.generation.pop('observed_exited_epoch');self.assertFalse(self.close()['closed'])
    def test_forged_exit_state_PID_and_times_are_rejected(self):
        self.processes[101]=ForeignBirthOnly(101,110.)
        for change in [dict(state='listening'),dict(pid=202),dict(epoch=101.),dict(monotonic=float('nan'))]:
            with self.subTest(change=change):
                self.generation['last_state']=dict(self.event,**change);self.assertFalse(self.close()['closed'])
        self.generation['last_state']=self.event
        for value in [True,float('nan'),99.,103.]:
            with self.subTest(exited=value):
                self.generation['observed_exited_epoch']=value;self.assertFalse(self.close()['closed'])
        self.assertEqual(self.signals,[])
    def test_exit_metadata_without_lifecycle_witness_is_rejected(self):
        self.processes[101]=ForeignBirthOnly(101,110.)
        (self.run/'server_lifecycle.jsonl').write_text('');self.assertFalse(self.close()['closed'])
    def test_exit_from_different_generation_owner_is_rejected(self):
        self.processes[101]=ForeignBirthOnly(101,110.)
        b.write_json(self.folder/'ownership.json',dict(self.owner,create_time=101.))
        self.assertFalse(self.close()['closed']);self.assertEqual(self.signals,[])
    def test_malformed_generation_command_and_executable_hash_block(self):
        for key,value in [('command',['foreign']),('exe_sha256','0'*64)]:
            with self.subTest(field=key):
                old=self.generation[key];self.generation[key]=value
                self.assertFalse(self.close()['closed']);self.generation[key]=old
    def test_same_birth_with_exit_witness_is_inconsistent_and_never_signalled(self):
        self.processes[101]=Process(self.owner);self.assertFalse(self.close()['closed']);self.assertEqual(self.signals,[])
    def test_same_birth_changed_attributes_are_not_adopted(self):
        self.generation.pop('observed_exited_epoch')
        self.processes[101]=Process(dict(self.owner,exe='C:/Windows/System32/conhost.exe'))
        self.assertFalse(self.close()['closed']);self.assertEqual(self.signals,[])
    def test_exact_live_current_generation_is_stopped_once(self):
        self.generation.pop('observed_exited_epoch');self.generation.pop('last_state')
        self.processes[101]=Process(self.owner);self.assertTrue(self.close()['closed']);self.assertEqual(self.signals,[101])
    def test_clear_and_watchdog_guards_precede_process_observation(self):
        self.server._proc=lambda pid:(_ for _ in()).throw(AssertionError('Must not observe before clear/watchdog'))
        self.assertFalse(self.close(cleared=False)['closed']);self.assertFalse(self.close(watchdog_ended=False)['closed'])
        self.assertEqual(self.saved,[])
    def test_foreign_listener_still_blocks_close_and_is_untouched(self):
        self.processes[101]=ForeignBirthOnly(101,110.);self.listeners=[type('Listener',(),dict(pid=999))()]
        self.assertFalse(self.close()['closed']);self.assertEqual(self.signals,[])
    def test_invalid_or_changing_birth_does_not_prove_reuse(self):
        for value in [True,float('nan'),float('inf'),-1]:
            with self.subTest(value=value):
                self.processes[101]=ForeignBirthOnly(101,value);self.assertFalse(self.close()['closed'])
        class Changing:
            pid=101
            def __init__(self):self.n=0
            def create_time(self):self.n+=1;return 110. if self.n==1 else 111.
        self.processes[101]=Changing();self.assertFalse(self.close()['closed']);self.assertEqual(self.signals,[])


class NaturalObserverStopTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.run=Path(self.temp.name);self.clock=Clock();self.clock.t=0.
        self.module=b.load_module('natural_stop_observer_under_test',b.ROOT/'host/native_ot_observer.py')
        self.cfg=type('CFGIdentity',(),dict(run=self.run,port=b.PORT))();self.faults=[];self.processes={}
        self.observer=self.module.NativeOTObserver(self.run,b.PORT,self.cfg,self.faults.append,
                         clock=self.clock,process_factory=self.lookup)
        self.observer.started=0.;self.observer.last_sample=dict(ended_monotonic=0.);self.observer.ready_event.set()
        self.folder=self.run/'native/ot_poll_00000';self.folder.mkdir(parents=True)
        script=self.folder/'command.tcl';script.write_text('FAKE_NOT_NATIVE')
        self.owner=dict(pid=101,create_time=1.,exe=str(b.native.SHELL),cwd=str(self.folder),
                        cmdline=[str(b.native.SHELL),'-file',str(script),'-work_dir',str(self.folder)])
        b.write_json(self.folder/'ownership.json',self.owner)
        self.processes[101]=Process(self.owner);self.observer.attempts=[dict(label='ot_poll_00000')]
    def tearDown(self):self.temp.cleanup()
    def lookup(self,pid):
        if pid not in self.processes:raise ProcessLookupError(pid)
        return self.processes[pid]
    def thread(self,seconds=9.7):
        case=self
        class InFlightStatus:
            alive=True;cancelled=False
            def is_alive(self):return self.alive
            def join(self,timeout):
                if not self.alive:return
                try:case.observer._cancel()
                except case.module._StopRequested:
                    self.cancelled=True;self.alive=False
                    b.write_json(case.folder/'process_result.json',dict(owner=case.owner,returncode=15));case.processes.clear();return
                case.clock.sleep(min(timeout,max(0.,seconds-case.clock.t)))
                if case.clock.t>=seconds:
                    self.alive=False;case.processes.clear()
                    case.observer.last_sample=dict(ended_monotonic=case.clock())
                    b.write_json(case.folder/'process_result.json',dict(owner=case.owner,returncode=0))
        self.observer.thread=InFlightStatus();return self.observer.thread
    def test_normal_stop_finishes_9_7s_inflight_without_cancellation(self):
        thread=self.thread();checks=[]
        r=self.observer.stop(complete_current=True,check=lambda:checks.append(self.clock()))
        self.assertTrue(r['stopped']);self.assertTrue(r['natural_completion_verified']);self.assertFalse(thread.cancelled)
        self.assertAlmostEqual(self.clock(),9.7);self.assertGreater(len(checks),100)
        self.assertTrue(self.observer.finish_event.is_set());self.assertFalse(self.observer.stop_event.is_set())
    def test_ordinary_cancel_preserved_as_red_race_control(self):
        thread=self.thread();r=self.observer.stop()
        self.assertTrue(r['stopped']);self.assertTrue(thread.cancelled);self.assertFalse(r['natural_completion_verified'])
        # The real fourth-run server retained USB work after this client exit.
        server_usb_busy=thread.cancelled
        self.assertTrue(server_usb_busy)
    def test_missing_live_check_is_rejected(self):
        self.thread()
        with self.assertRaises(ValueError):self.observer.stop(complete_current=True)
    def test_closed_scheduling_prevents_new_status_at_worker_entry(self):
        observer=self.module.NativeOTObserver(self.run,b.PORT,self.cfg,self.faults.append,clock=self.clock)
        self.cfg.call=lambda *args:(_ for _ in()).throw(AssertionError('New poll after normal stop'))
        r=observer.stop(complete_current=True,check=lambda:None)
        self.assertTrue(r['stopped']);observer._worker();self.assertEqual(observer.attempts,[])
    def test_STOP_during_drain_cancels_then_raises_without_reset_permission(self):
        thread=self.thread()
        def check():
            if self.clock()>=.1:raise b.BoardError('STOP during native drain')
        with self.assertRaisesRegex(b.BoardError,'STOP'):self.observer.stop(complete_current=True,check=check)
        self.assertTrue(thread.cancelled);self.assertFalse(self.observer.stop_record['natural_completion_verified'])
    def test_285_deadline_during_drain_cancels_then_raises(self):
        thread=self.thread();controller=type('Safety',(),{})()
        controller.fault=None;controller.run=self.run;controller.clock=lambda:284.9+self.clock()
        controller.program_started=0.;controller.observer=self.observer
        with self.assertRaisesRegex(TimeoutError,'285s'):
            self.observer.stop(complete_current=True,check=lambda:b.Controller.check(controller))
        self.assertTrue(thread.cancelled);self.assertLess(self.clock(),.2)
    def test_new_OT_fault_during_drain_cancels_then_raises(self):
        thread=self.thread()
        def check():
            if self.clock()>=.1:self.observer.fault='over_temp=1'
            self.observer.check()
        with self.assertRaisesRegex(self.module.NativeOTObserverError,'over_temp'):
            self.observer.stop(complete_current=True,check=check)
        self.assertTrue(thread.cancelled)
    def test_fresh_OT_age_remains_enforced_during_drain(self):
        thread=self.thread(seconds=40);self.clock.t=24.9
        with self.assertRaisesRegex(self.module.NativeOTObserverError,'stale'):
            self.observer.stop(complete_current=True,check=self.observer.check)
        self.assertTrue(thread.cancelled);self.assertLess(self.clock(),25.1)
    def test_natural_wait_has_20s_extra_bound_even_with_noop_check(self):
        thread=self.thread(seconds=40)
        with self.assertRaisesRegex(TimeoutError,'20s'):
            self.observer.stop(complete_current=True,check=lambda:None)
        self.assertTrue(thread.cancelled);self.assertLess(self.clock(),20.1)


class ControllerNativeHandoverTests(unittest.TestCase):
    def exercise(self,*,drain_deadline=False,cable_error=False,forced_old_cancel=False):
        with tempfile.TemporaryDirectory()as temporary:
            run=Path(temporary);events=[];clock=Clock();processes={};observers=[]
            bit=run/'ai_camera_frozen.sbit';bit.write_bytes(b'FAKE_NOT_BITSTREAM')
            module=b.load_module('real_worker_drain_under_test',b.ROOT/'host/native_ot_observer.py')
            class InFlightCFG(CFG):
                def __init__(self):super().__init__(events);self.run,self.port=run,b.PORT;self.busy=False;self.calls=0
                def call(self,label,body,timeout,cancel_check):
                    self.calls+=1;self.busy=True;folder=run/'native'/label;folder.mkdir(parents=True)
                    script=folder/'command.tcl';script.write_text('FAKE_NOT_NATIVE')
                    owner=dict(pid=101,create_time=1.,exe=str(b.native.SHELL),cwd=str(folder),
                               cmdline=[str(b.native.SHELL),'-file',str(script),'-work_dir',str(folder)])
                    b.write_json(folder/'ownership.json',owner);processes[101]=Process(owner)
                    while not observers[0].finish_event.wait(.001):cancel_check()
                    if drain_deadline:clock.t+=b.ACTIVE_MAX
                    else:clock.t+=9.7
                    try:cancel_check()
                    except BaseException:
                        events.append('forced_status_cancel_USB_still_busy');processes.clear()
                        b.write_json(folder/'process_result.json',dict(owner=owner,returncode=15));raise
                    self.busy=False;processes.clear();events.append('natural_status_completed')
                    b.write_json(folder/'process_result.json',dict(owner=owner,returncode=0))
                    text='PG2L200H\nStatus Register: 0x00183c80\n';(folder/'command.log').write_text(text);return text
                def reset(self,source):
                    if self.busy or cable_error:raise b.native.NativeError('Cable List empty; synthetic native reset failure')
                    return super().reset(source)
            cfg=InFlightCFG()
            def lookup(pid):
                if pid not in processes:raise ProcessLookupError(pid)
                return processes[pid]
            def observer(*args,**kwargs):
                item=module.NativeOTObserver(*args,**kwargs,clock=clock,process_factory=lookup)
                if forced_old_cancel:
                    original=item.stop
                    item.stop=lambda **ignored:original()
                observers.append(item);return item
            def work(*args,**kw):
                until=time.monotonic()+1
                while not cfg.busy and time.monotonic()<until:time.sleep(.001)
                self.assertTrue(cfg.busy);return dict(passed=True,synthetic_test_fixture=True)
            controller=b.Controller(run,dict(bitstream_sha256=b.sha(bit)),cfg=cfg,observer_factory=observer,
                workload=work,serial_opener=lambda port:Serial(events),client_check=lambda folder:b.clients_stopped(folder,process_factory=lookup),
                clock=clock,sleeper=clock.sleep,display_hold_seconds=0)
            r=controller.execute();self.assertEqual(cfg.programs,1);self.assertEqual(cfg.calls,1)
            self.assertFalse(observers[0].thread.is_alive());self.assertTrue(observers[0].finish_event.is_set())
            if drain_deadline:
                self.assertFalse(r['passed']);self.assertEqual(cfg.resets,0);self.assertFalse(r['native_clients_stopped_before_reset'])
                self.assertIn('285s',r.get('OT_stop_error',''))
            elif forced_old_cancel:
                self.assertFalse(r['passed']);self.assertIn('cleanup_error',r);self.assertFalse(r['sram_clear_verified'])
                self.assertIn('forced_status_cancel_USB_still_busy',events)
            elif cable_error:
                self.assertFalse(r['passed']);self.assertIn('cleanup_error',r);self.assertFalse(r['sram_clear_verified'])
                self.assertEqual(cfg.resets,0)
            else:
                self.assertTrue(r['passed']);self.assertEqual(cfg.resets,1);self.assertTrue(r['OT_stop']['natural_completion_verified'])
                self.assertLess(events.index('natural_status_completed'),events.index('reset'))
            self.assertFalse(b.completion_ok(r,dict(verified=True),True,dict(passed=True,fallback_reset_attempted=True),0,0))
            return r
    def test_real_local_worker_normal_handover_completes_before_reset(self):self.exercise()
    def test_old_immediate_cancel_reproduces_busy_server_red_control(self):self.exercise(forced_old_cancel=True)
    def test_deadline_during_handover_blocks_controller_reset(self):self.exercise(drain_deadline=True)
    def test_independent_reset_CableList_error_remains_failure(self):self.exercise(cable_error=True)


if __name__=='__main__':unittest.main(verbosity=2)
