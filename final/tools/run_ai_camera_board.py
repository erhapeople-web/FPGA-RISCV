"""One qualified AI-camera SRAM session, with independent watchdog and supervisor.

Import and --dependencies are inert. Missing/invalid BOARD_GATE rejects before
creating a run or importing board runtime. No Flash, CoreMark, PC inference,
program retry or RUN retry is implemented. Only the wrapper entry accesses a
board; tests inject fake CFG/observer/serial/workload and process dependencies.
"""
from __future__ import annotations
import argparse
from datetime import datetime
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
SCRIPT=Path(__file__).resolve()
PARENT=ROOT/'runtime/board_support'
PORT=65446
BAUD=921600
ACTIVE_MAX=285.0
NORMAL_COMPLETION_RESERVE=23.0  # Existing OT natural drain <=20s, plus3s headroom.
WATCHDOG_MAX=390.0
OUTER_MAX=425.0
HEARTBEAT_MAX=8.0
CLEANUP_GRACE=30.0
SCHEMA='AI_CAMERA_BOARD_GATE_V1'
SCOPE='J5_AI_CAMERA_20261031'


def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


native=load_module('_ai_board_local_native',ROOT/'host/native_cfg.py')
lifecycle=load_module('_ai_board_native_lifecycle',ROOT/'host/native_client_lifecycle.py')
server_lifecycle=load_module('_ai_board_server_lifecycle',ROOT/'host/native_server_lifecycle.py')
sha,read_json,write_json=native.sha,native.read_json,native.write_json
normalized,exact_process,snapshot,stop_exact=native.normalized,native.exact_process,native.snapshot,native.stop_exact


class BoardError(RuntimeError):
    pass


def runtime_dependencies(root=ROOT):
    """Exact imported source/tool closure, not an old candidate's qualification."""
    if sha(Path(root)/'host/native_cfg.py')!=sha(PARENT/'host/native_cfg.py'):
        raise BoardError('NativeCFG copy differs from the previously tested mechanics')
    paths=[Path(root)/'tools/run_ai_camera_board.py',Path(root)/'host/native_cfg.py',
           PARENT/'tools/run_cpu_load_board.py',PARENT/'host/cpu_load_qualification.py',
           PARENT/'host/native_cfg.py',Path(root)/'host/native_ot_observer.py',Path(root)/'host/native_client_lifecycle.py',
           Path(root)/'host/native_server_lifecycle.py',
           native.SHELL,native.SHELL.parent/'cdt_js.exe']
    return {str(p.resolve()):sha(p) for p in paths}


def inside(root,name):
    if not isinstance(name,str) or not name or Path(name).is_absolute():
        raise BoardError('Gate paths must be relative candidate files')
    path=(Path(root)/name).resolve()
    if path==Path(root).resolve() or not path.is_relative_to(Path(root).resolve()) or not path.is_file():
        raise BoardError('Gate file missing or escaped candidate: '+str(name))
    return path


def verify_hashes(root,mapping):
    if not isinstance(mapping,dict) or not mapping:
        raise BoardError('Nonempty gate hash map required')
    for name,digest in mapping.items():
        path=inside(root,name)
        if not isinstance(digest,str) or not re.fullmatch('[0-9a-f]{64}',digest) or sha(path)!=digest:
            raise BoardError('Gate hash mismatch: '+name)


def source_closure(root):
    root=Path(root).resolve()
    required={'tools/run_ai_camera_board.py','host/native_cfg.py','host/native_ot_observer.py',
              'host/native_client_lifecycle.py','host/camera_workload.py','identity.json','pds/build.tcl'}
    build=inside(root,'pds/build.tcl').read_text(encoding='utf-8')
    names=re.findall(r'^add_(?:design|constraint)\s+\{([^}]+)\}',build,re.M)
    if len(names)!=len(re.findall(r'^add_(?:design|constraint)\b',build,re.M)):
        raise BoardError('Unsupported/unparsed active build input syntax')
    for name in names:
        p=Path(name)
        path=(p if p.is_absolute() else root/'pds'/p).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise BoardError('Build input missing/escaped candidate: '+name)
        required.add(path.relative_to(root).as_posix())
    if not any(n.startswith('src/') for n in required) or not any(n.startswith('constraints/') for n in required):
        raise BoardError('Build source/constraint closure empty')
    required|={p.relative_to(root).as_posix() for p in (root/'src/firmware').glob('*') if p.is_file()}
    required|={p.relative_to(root).as_posix() for p in (root/'host').glob('*.py') if p.is_file()}
    return required


def qualified(root=ROOT):
    """Pure file validation. It must finish before run mkdir or device startup."""
    root=Path(root).resolve();gate_path=root/'evidence/BOARD_GATE.json'
    gate_hash=sha(gate_path)
    gate=read_json(gate_path)
    if (not isinstance(gate.get('candidate_root'),str) or not Path(gate['candidate_root']).is_absolute() or
            gate.get('schema')!=SCHEMA or gate.get('passed') is not True or gate.get('scope')!=SCOPE or
            normalized(gate.get('candidate_root',''))!=normalized(root)):
        raise BoardError('BOARD_GATE is not a passed gate for this exact candidate')
    verify_hashes(root,gate.get('source_hashes'))
    missing=source_closure(root)-set(gate['source_hashes'])
    if missing:raise BoardError('Gate omits active sources: '+str(sorted(missing)))
    verify_hashes(root,gate.get('proof_hashes'))
    required=gate.get('required_proofs',{})
    if (not isinstance(required,dict) or not all(isinstance(v,str) for v in required.values()) or
            set(required)!={'functional','timing','rom','cdc','host_workload','board_controls'} or len(set(required.values()))!=6):
        raise BoardError('Gate proof categories incomplete')
    for name in gate['proof_hashes']:
        if read_json(inside(root,name)).get('passed') is not True:
            raise BoardError('A gate proof is not passed: '+name)
    if any(name not in gate['proof_hashes'] for name in required.values()):
        raise BoardError('Required proof not hashed')
    dependencies=runtime_dependencies(root)
    if gate.get('dependency_hashes')!=dependencies:
        raise BoardError('Gate runtime dependency closure mismatch')
    bit=gate.get('bitstream',{})
    path=inside(root,bit.get('path'))
    if path.suffix.lower()!='.sbit' or sha(path)!=bit.get('sha256'):
        raise BoardError('Gate bitstream mismatch')
    if gate_hash!=sha(gate_path):
        raise BoardError('Gate changed during read')
    binding=dict(schema=SCHEMA,scope=SCOPE,candidate_root=str(root),gate_sha256=gate_hash,
                 bitstream_sha256=bit['sha256'],source_hashes=gate['source_hashes'],
                 proof_hashes=gate['proof_hashes'],dependency_hashes=dependencies)
    return path,binding


def load_runtime(binding):
    if binding['dependency_hashes']!=runtime_dependencies():raise BoardError('Runtime sources changed')
    board=load_module('_ai_camera_original_server',PARENT/'tools/run_cpu_load_board.py')
    ot=load_module('_ai_camera_local_ot',ROOT/'host/native_ot_observer.py')
    # These imported APIs are used only for native/server mechanics. No old
    # Controller/qualified_inputs function or old proof is called or replaced.
    if normalized(board.__file__)!=normalized(PARENT/'tools/run_cpu_load_board.py'):
        raise BoardError('Unexpected server module')
    if normalized(ot.__file__)!=normalized(ROOT/'host/native_ot_observer.py'):
        raise BoardError('Unexpected local OT observer module')
    return type('Runtime',(),dict(board=board,observer=ot.NativeOTObserver))()


def command(role,run,port='COM11'):
    return [sys.executable,'-B','-X','utf8',str(SCRIPT),'--role',role,'--run-dir',str(Path(run).resolve()),'--port',port]


def allowed_role(run,owner,role):
    try:
        return (owner['cmdline']==command(role,run) and normalized(owner['exe'])==normalized(sys.executable)
                and normalized(owner['cwd'])==normalized(run) and type(owner['pid']) is int
                and isinstance(owner['create_time'],(int,float)))
    except (KeyError,TypeError,ValueError,OSError):return False


def allowed_native(run,owner):
    try:
        cmd=owner['cmdline'];folder=Path(cmd[4]).resolve();script=Path(cmd[2]).resolve()
        return (len(cmd)==5 and cmd[1]=='-file' and cmd[3]=='-work_dir' and
                normalized(cmd[0])==normalized(native.SHELL)==normalized(owner['exe']) and
                normalized(owner['cwd'])==normalized(folder) and script==folder/'command.tcl' and
                folder.parent==Path(run).resolve()/'native' and re.fullmatch('[a-z][a-z0-9_]{0,48}',folder.name))
    except (KeyError,TypeError,ValueError,IndexError,OSError):return False


def stop_registered(run,*,process_factory=None,process_iter=None,stop_fn=stop_exact):
    """Suspend/reverify controller, discover own children, stop, then native clients.

    Strict process identities and private canonical command/cwd are required.
    Foreign/reused PID is never stopped. Only exact recorded native exit plus
    a different process birth can prove the old client gone despite PID reuse.
    """
    if process_factory is None or process_iter is None:
        import psutil
        lookup=process_factory or psutil.Process;iterate=process_iter or psutil.process_iter
        missing=(ProcessLookupError,psutil.NoSuchProcess)
    else:lookup,iterate,missing=process_factory,process_iter,(ProcessLookupError,)
    run=Path(run).resolve()
    owner=read_json(run/'controller_owner.json',{})
    rows=[];discovered=[];suspended=False
    if not allowed_role(run,owner,'controller'):
        return [dict(stopped=False,reason='Unowned controller command')]
    def probe():
        try:p=lookup(owner['pid'])
        except missing:return None
        if exact_process(owner,lookup) is None:raise BoardError('Controller PID reused/changed; takeover refused')
        return p
    def capture(p):
        row=snapshot(p)
        if row['create_time']<=owner['create_time']:raise BoardError('Child predates controller')
        if allowed_native(run,row):discovered.append(row)
        elif Path(row['exe']).name.lower() in ('cdt_cfg_shell.exe','cdt_dbg.exe'):
            raise BoardError('Foreign JTAG descendant; no takeover')
    try:
        p=probe()
        if p is not None:
            p.suspend();suspended=True
            p=probe()
            if p is None:raise BoardError('Controller disappeared during suspension')
            for child in p.children(recursive=True):capture(child)
        else:
            for child in iterate():
                try:
                    if child.ppid()==owner['pid'] and child.create_time()>owner['create_time']:capture(child)
                except missing:pass
        # An outer takeover also covers a dead watchdog's possible orphaned
        # native client. Never race another live watchdog's reset operation.
        watch=read_json(run/'watchdog_owner.json',{})
        if watch:
            if not allowed_role(run,watch,'watchdog'):raise BoardError('Unowned watchdog record')
            try:wp=lookup(watch['pid'])
            except missing:wp=None
            if wp is not None:
                if exact_process(watch,lookup) is None:raise BoardError('Watchdog PID reused/changed')
                if watch['pid']!=os.getpid():raise BoardError('Another live watchdog owns cleanup')
            else:
                for child in iterate():
                    try:
                        if child.ppid()==watch['pid'] and child.create_time()>watch['create_time']:
                            row=snapshot(child)
                            if not allowed_native(run,row):raise BoardError('Unknown orphan of watchdog')
                            discovered.append(row)
                    except missing:pass
        registered=[]
        for file in (run/'native').glob('*/ownership.json'):
            row=read_json(file)
            if not allowed_native(run,row):raise BoardError('Noncanonical registered native owner')
            registered.append(row)
        if p is not None:
            stopped=stop_fn(owner,lookup);rows.append(dict(kind='controller',**stopped))
            if stopped.get('stopped') is not True:raise BoardError('Controller termination unverified')
        else:rows.append(dict(kind='controller',stopped=True,pid=owner['pid'],confirmed_absent=True))
        seen=set()
        for row in registered+discovered:
            key=(row['pid'],row['create_time'])
            if key not in seen:
                seen.add(key)
                done=read_json(Path(row['cmdline'][4])/'process_result.json',{})
                completed=lifecycle.completed_client(row,done,process_factory=lookup)
                if completed['stopped']:
                    rows.append(dict(kind='native_client',**completed))
                elif exact_process(row,lookup)is None:
                    # Missing exit evidence or a same-birth attribute mismatch
                    # cannot authorize a reset or a stop of the current PID.
                    rows.append(dict(kind='native_client',**completed))
                else:
                    rows.append(dict(kind='native_client',**stop_fn(row,lookup)))
        return rows
    except Exception as error:
        failed=dict(stopped=False,reason=repr(error),suspension_attempted=suspended)
        if suspended:
            p=exact_process(owner,lookup)
            if p is not None:
                try:p.resume();failed['exact_controller_resumed']=True
                except Exception as resume:failed['resume_error']=repr(resume)
        return rows+[failed]


def wait_server(runtime,run,seconds=4):
    import psutil
    manager=runtime.board.ServerManager(run,PORT)
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        owner=read_json(Path(run)/'server_current.json',{})
        p=exact_process(owner)
        listeners=manager._listeners()
        if any(r.pid!=owner.get('pid') for r in listeners):raise BoardError('Foreign JTAG listener; no takeover')
        if p is not None and listeners and not manager._busy_clients(owner):return
        time.sleep(.025)
    raise BoardError('Exact owned JTAG server readiness timed out')


def cleanup_ok(row):
    return (isinstance(row,dict) and row.get('sram_clear_verified') is True and
            native.clear_verified(row.get('status')) and row['status'].get('raw','').lower()=='0x00180c80')


def session_cleanup(run):
    for name,source in [('SESSION_FINISHED','controller'),('watchdog_result.json','watchdog'),('outer_fallback_result.json','outer_fallback')]:
        row=read_json(Path(run)/name,{})
        if (row.get('native_clients_stopped_before_reset') is True and row.get('cleanup',{}).get('source')==source
                and cleanup_ok(row.get('cleanup'))):
            return dict(verified=True,source=source,cleanup=row['cleanup'])
    return dict(verified=False,source=None)


def clients_stopped(run,*,process_factory=None):
    """No killing: require original exit and absence or a different PID birth."""
    rows=[]
    for folder in (Path(run)/'native').glob('*'):
        if not folder.is_dir():continue
        file=folder/'ownership.json'
        if not file.exists():
            # In the frozen NativeCFG, cancellation can happen before Popen;
            # only an explicit OT cancellation record can prove that case.
            samples=Path(run)/'native_ot_observer/samples.jsonl'
            cancelled=False
            if samples.exists():
                records=[json.loads(s) for s in samples.read_text(encoding='utf-8').splitlines() if s]
                cancelled=any(r.get('label')==folder.name and r.get('cancelled') is True for r in records)
            rows.append(dict(label=folder.name,stopped=cancelled,reason='cancelled_before_spawn' if cancelled else 'native ownership missing'))
            continue
        owner=read_json(file);done=read_json(file.parent/'process_result.json',{})
        if not allowed_native(run,owner):
            rows.append(dict(pid=owner.get('pid'),stopped=False,reason='noncanonical native ownership'));continue
        rows.append(lifecycle.completed_client(owner,done,process_factory=process_factory))
    return dict(stopped=all(r['stopped'] for r in rows),children=rows)


class QueuedSerial:
    """One RX owner; no discarded startup bytes and no unbounded flush."""
    timeout=.05
    write_timeout=.5
    def __init__(self,serial,run,on_fault,*,check=lambda:None):
        self.serial,self.run,self.on_fault,self.check=serial,Path(run),on_fault,check
        self.stop_event=threading.Event();self.condition=threading.Condition();self.buffer=bytearray();self.fault=None
        self.rx=(self.run/'raw_rx.bin').open('xb');self.tx=(self.run/'raw_tx.bin').open('xb')
        self.thread=threading.Thread(target=self._reader,name='ai-camera-uart-reader',daemon=True);self.thread.start()
    def _reader(self):
        try:
            while not self.stop_event.is_set():
                # ACKs are only32 bytes. Waiting to fill4096 with a positive
                # serial timeout adds that entire timeout to each upload ACK.
                # Block for the first byte, then drain only bytes already held
                # by the driver. This thread remains the sole RX owner.
                waiting=getattr(self.serial,'in_waiting',0)
                if type(waiting) is not int or waiting<0:raise BoardError('Invalid UART pending-byte count')
                data=self.serial.read(min(4096,waiting) if waiting else 1)
                if not isinstance(data,bytes):raise BoardError('Non-byte UART read')
                if data:
                    self.rx.write(data);self.rx.flush()
                    with self.condition:
                        if len(self.buffer)+len(data)>16*1024*1024:raise BoardError('UART queue bound exceeded')
                        self.buffer.extend(data);self.condition.notify_all()
        except BaseException as error:
            if not self.stop_event.is_set():
                self.fault=repr(error);self.on_fault('UART reader: '+self.fault)
    def read(self,n):
        if type(n) is not int or n<1:raise ValueError('Positive read length required')
        self.check()
        with self.condition:
            if not self.buffer:self.condition.wait(self.timeout)
            if self.fault:raise BoardError(self.fault)
            result=bytes(self.buffer[:n]);del self.buffer[:n]
        self.check();return result
    def write(self,data):
        self.check();count=self.serial.write(data)
        if type(count) is not int or not 0<=count<=len(data):raise BoardError('Invalid UART write count')
        self.tx.write(data[:count]);self.tx.flush();self.check();return count
    def flush(self):
        until=time.monotonic()+self.write_timeout
        while getattr(self.serial,'out_waiting',0):
            self.check()
            if time.monotonic()>=until:raise TimeoutError('Bounded UART flush deadline')
            time.sleep(.005)
    def close(self):
        self.stop_event.set()
        try:self.serial.close()
        finally:
            self.thread.join(timeout=1)
            if self.thread.is_alive():raise BoardError('UART reader stop unverified')
            self.rx.close();self.tx.close()
        return dict(closed=True,reader_stopped=True)


def serial_factory(port):
    import serial
    from serial.tools import list_ports
    matches=[p for p in list_ports.comports() if (p.vid,p.pid)==(0x10c4,0xea60)]
    if len(matches)!=1 or matches[0].device.upper()!=port:raise BoardError('Expected one requested CP210x port')
    return serial.Serial(port=port,baudrate=BAUD,timeout=.05,write_timeout=.5)


class Controller:
    def __init__(self,run,binding,*,cfg,observer_factory,workload,serial_opener=serial_factory,
                 ready_check=lambda:None,client_check=clients_stopped,clock=time.monotonic,
                 sleeper=time.sleep,display_hold_seconds=8):
        if (isinstance(display_hold_seconds,bool) or not isinstance(display_hold_seconds,(int,float)) or
                not math.isfinite(display_hold_seconds) or not 0<=display_hold_seconds<=10):
            raise ValueError('Result display hold must be finite in0..10s')
        self.run,self.binding=Path(run),binding;self.cfg=cfg;self.observer_factory=observer_factory
        self.workload,self.serial_opener,self.ready_check,self.client_check=workload,serial_opener,ready_check,client_check
        self.clock=clock;self.started=clock();self.program_started=None;self.observer=None;self.link=None
        self.sleeper,self.display_hold_seconds=sleeper,float(display_hold_seconds)
        self.result_visible_since=None
        self.fault=None;self.fault_lock=threading.Lock();self.phase='starting';self.hb_stop=threading.Event()
    def trip(self,reason):
        with self.fault_lock:
            if self.fault is None:self.fault=str(reason)
        (self.run/'STOP').write_text(self.fault,encoding='utf-8')
    def check(self):
        if self.fault or (self.run/'STOP').exists() or (self.run/'WATCHDOG_CANCEL').exists():
            raise BoardError(self.fault or 'STOP/cancel requested')
        if self.program_started is not None and self.clock()-self.program_started>=ACTIVE_MAX:
            raise TimeoutError('285s from program-start active deadline')
        if self.observer is not None:self.observer.check()
    def heartbeat(self):
        while not self.hb_stop.is_set():
            try:write_json(self.run/'heartbeat.json',dict(pid=os.getpid(),epoch=time.time(),monotonic=self.clock(),phase=self.phase,
                                                       program_started_monotonic=self.program_started))
            except BaseException as error:self.trip('Heartbeat publication: '+repr(error));return
            self.hb_stop.wait(.25)
    def progress(self,row):
        self.check()
        if not isinstance(row,dict):raise BoardError('Workload progress must be a dict')
        # Phase5 is emitted by the board only after the pixel-domain OSD ACK.
        # Snapshot readback follows it and counts toward the display interval.
        if row.get('phase')==5 and row.get('node')==119 and self.result_visible_since is None:
            self.result_visible_since=self.clock()
        with (self.run/'workload_progress.jsonl').open('a',encoding='utf-8') as out:
            out.write(json.dumps(dict(monotonic=self.clock(),record=row),ensure_ascii=False)+'\n')
    def display_result(self):
        # Only the already verified real result is held.  This never adds time
        # to the285s deadline. Reserve the existing20s natural OT drain plus3s;
        # otherwise display may permit a new poll too late to finish safely.
        self.check()
        if self.program_started is None:raise BoardError('Display hold before program')
        started=self.clock();remaining=ACTIVE_MAX-(started-self.program_started)
        visible_since=self.result_visible_since if self.result_visible_since is not None else started
        elapsed_before_hold=max(0.,started-visible_since)
        allowed=min(max(0.,self.display_hold_seconds-elapsed_before_hold),max(0.,remaining-NORMAL_COMPLETION_RESERVE))
        self.phase='display_result'
        row=dict(started_monotonic=started,planned_seconds=allowed,deadline_seconds_unchanged=ACTIVE_MAX,
                 reserved_cleanup_seconds=NORMAL_COMPLETION_RESERVE,requested_seconds=self.display_hold_seconds,
                 visible_since_monotonic=visible_since,elapsed_before_hold_seconds=elapsed_before_hold,
                 timing_origin='OSD_commit_ack' if self.result_visible_since is not None else 'workload_complete')
        write_json(self.run/'display_result_started.json',row)
        while True:
            self.check();left=started+allowed-self.clock()
            if left<=0:break
            self.sleeper(min(.05,left))
        self.check();row['observed_seconds']=self.clock()-started
        row['observed_total_display_seconds']=self.clock()-visible_since
        return row
    def execute(self):
        result=dict(passed=False,scope=SCOPE,cleanup={},native_clients_stopped_before_reset=False,
                    actual_temperature_collected=False,thermal_pass=None,flash_written=False,coremark_executed=False,
                    PC_inference_executed=False,automatic_program_retries=0,automatic_RUN_retries=0)
        hb=threading.Thread(target=self.heartbeat,name='ai-board-heartbeat',daemon=True);hb.start()
        attempted=False
        try:
            self.ready_check();self.check();self.phase='baseline'
            result['baseline']=self.cfg.baseline(self.check)
            if result['baseline']['over_temp'] or result['baseline']['crc_error'] or result['baseline']['id_error']:
                raise BoardError('Native baseline OT/CRC/ID not zero')
            self.check();self.phase='programming';self.program_started=self.clock();attempted=True
            write_json(self.run/'program_started.json',dict(monotonic=self.program_started,epoch=time.time(),pid=os.getpid()))
            frozen=self.run/'ai_camera_frozen.sbit'
            if sha(frozen)!=self.binding['bitstream_sha256']:raise BoardError('Frozen bitstream changed')
            result['program_status']=self.cfg.program(frozen,self.check)
            p=result['program_status']
            if p['over_temp'] or not p['done'] or not p['done_i'] or p['crc_error'] or p['id_error']:
                raise BoardError('Native programmed OT/DONE/CRC/ID status invalid')
            self.check();self.link=QueuedSerial(self.serial_opener('COM11'),self.run,self.trip,check=self.check)
            self.observer=self.observer_factory(self.run,PORT,cfg=self.cfg,on_fault=self.trip)
            self.observer.start();self.phase='workload'
            result['workload']=self.workload(self.link,self.run,self.check,progress_callback=self.progress)
            self.check()
            if not isinstance(result['workload'],dict) or result['workload'].get('passed') is not True:
                raise BoardError('Board workload did not pass')
            result['result_display']=self.display_result()
            result['passed']=True
        except BaseException as error:result.update(passed=False,error=repr(error))
        finally:
            self.phase='cleanup';uart_ok=True;observer_ok=True
            try:write_json(self.run/'cleanup_started.json',dict(monotonic=self.clock(),epoch=time.time(),pid=os.getpid()))
            except BaseException as error:result.update(passed=False,cleanup_progress_error=repr(error))
            try:
                if self.link is not None:result['UART_stop']=self.link.close()
            except BaseException as error:uart_ok=False;result['UART_stop_error']=repr(error)
            try:
                if self.observer is not None:
                    result['OT_stop']=self.observer.stop(complete_current=result['passed'] is True,check=self.check)
                    observer_ok=result['OT_stop'].get('stopped') is True
                    if result['OT_stop'].get('fault') or result['OT_stop'].get('sample_count',0)<1:result['passed']=False
            except BaseException as error:observer_ok=False;result['OT_stop_error']=repr(error)
            try:
                children=self.client_check(self.run);result['native_clients_stop']=children
                safe=uart_ok and observer_ok and children.get('stopped') is True
                result['native_clients_stopped_before_reset']=safe
                if attempted and safe:result['cleanup']=self.cfg.reset('controller')
                elif attempted:raise BoardError('Native/UART owner stop unverified; concurrent reset forbidden')
                else:result['no_program_attempted']=True
            except BaseException as error:result['cleanup_error']=repr(error)
            result['sram_clear_verified']=cleanup_ok(result['cleanup'])
            result['passed']=result['passed'] and result['sram_clear_verified'] and uart_ok and observer_ok
            result.update(program_started_monotonic=self.program_started,finished_monotonic=self.clock(),
                          state='completed' if result['passed'] else ('failed_cleared' if result['sram_clear_verified'] else 'cleanup_unverified'))
            self.phase='finished';self.hb_stop.set();hb.join(timeout=1)
            write_json(self.run/'controller_result.json',result);write_json(self.run/'SESSION_FINISHED',result)
        return result


def wait_watchdog(run):
    until=time.monotonic()+10
    while time.monotonic()<until:
        owner=read_json(Path(run)/'watchdog_owner.json',{});ready=read_json(Path(run)/'WATCHDOG_READY',{})
        if (allowed_role(run,owner,'watchdog') and exact_process(owner) is not None and
                ready.get('watchdog_pid')==owner['pid'] and ready.get('controller_pid')==os.getpid()):return
        if (Path(run)/'STOP').exists():raise BoardError('STOP before independent watchdog ready')
        time.sleep(.025)
    raise BoardError('Independent watchdog readiness timeout; no program')


def controller(run):
    _,binding=qualified()
    if binding!=read_json(run/'input_binding.json'):raise BoardError('Controller input binding changed')
    until=time.monotonic()+3
    while not (run/'controller_owner.json').exists() and time.monotonic()<until:time.sleep(.025)
    owner=read_json(run/'controller_owner.json')
    if not allowed_role(run,owner,'controller') or owner['pid']!=os.getpid() or exact_process(owner) is None:
        raise BoardError('Controller own exact identity not published')
    runtime=load_runtime(binding)
    host=str(ROOT/'host')
    if host not in sys.path:sys.path.insert(0,host)
    work=load_module('_ai_camera_current_workload',ROOT/'host/camera_workload.py')
    cfg=native.NativeCFG(run,PORT,before_call=lambda:wait_server(runtime,run))
    return Controller(run,binding,cfg=cfg,observer_factory=runtime.observer,workload=work.run_workload,
                      ready_check=lambda:wait_watchdog(run)).execute()


class WatchdogPolicy:
    def __init__(self,started):self.started=started;self.notified=None;self.reason=None
    def step(self,now,*,heartbeat_age,program_started,stop,alive,cleared,cleanup_started=None):
        if cleared:return 'done'
        reason=('STOP' if stop else 'heartbeat expired' if heartbeat_age>=HEARTBEAT_MAX else
                'active285s deadline' if cleanup_started is None and program_started is not None and now-program_started>=ACTIVE_MAX else
                'program never started' if cleanup_started is None and program_started is None and now-self.started>=60 else
                'controller cleanup exceeded grace' if cleanup_started is not None and now-cleanup_started>=CLEANUP_GRACE else
                'watchdog total budget reserve' if now-self.started>=WATCHDOG_MAX-75 else None)
        if reason and self.notified is None:self.notified=now;self.reason=reason;return 'notify'
        if not alive or self.notified is not None and now-self.notified>=CLEANUP_GRACE:return 'fallback'
        return 'wait'


def fallback(run,runtime,source,*,terminator=stop_registered,cfg=None):
    row=dict(source=source,passed=False,cleanup={},native_clients_stopped_before_reset=False,fallback_reset_attempted=True)
    try:
        rows=terminator(run);row['terminated_registered']=rows
        if not rows or any(r.get('stopped') is not True for r in rows):raise BoardError('Exact takeover unverified; no reset')
        row['native_clients_stopped_before_reset']=True
        cfg=cfg or native.NativeCFG(run,PORT,before_call=lambda:wait_server(runtime,run))
        row['cleanup']=cfg.reset(source);row['sram_clear_verified']=cleanup_ok(row['cleanup']);row['passed']=row['sram_clear_verified']
    except BaseException as error:row.update(error=repr(error),sram_clear_verified=False)
    return row


def watchdog(run):
    started=time.monotonic()
    _,binding=qualified()
    if binding!=read_json(run/'input_binding.json'):raise BoardError('Watchdog gate binding changed')
    owner=read_json(run/'controller_owner.json')
    if not allowed_role(run,owner,'controller') or exact_process(owner) is None:raise BoardError('Unowned controller')
    until=time.monotonic()+3
    while not (run/'watchdog_owner.json').exists() and time.monotonic()<until:time.sleep(.025)
    own=read_json(run/'watchdog_owner.json')
    if not allowed_role(run,own,'watchdog') or own['pid']!=os.getpid() or exact_process(own) is None:
        raise BoardError('Watchdog exact own identity not published')
    runtime=load_runtime(binding);policy=WatchdogPolicy(started)
    write_json(run/'WATCHDOG_READY',dict(watchdog_pid=os.getpid(),controller_pid=owner['pid'],active_max_seconds=ACTIVE_MAX,total_max_seconds=WATCHDOG_MAX))
    result=dict(passed=False,fallback_reset_attempted=False)
    try:
        while True:
            now=time.monotonic();hb=read_json(run/'heartbeat.json',{})
            stamp=hb.get('monotonic')
            age=now-stamp if isinstance(stamp,(int,float)) and math.isfinite(stamp) else now-policy.started
            if hb and (hb.get('pid')!=owner['pid'] or not isinstance(stamp,(int,float)) or
                       not math.isfinite(stamp) or stamp>now+.1):age=float('inf')
            prog=read_json(run/'program_started.json',{})
            program_started=prog.get('monotonic')
            if prog and (prog.get('pid')!=owner['pid'] or not isinstance(program_started,(int,float)) or
                         not math.isfinite(program_started) or program_started>now):
                age=float('inf');program_started=None
            cleanup=read_json(run/'cleanup_started.json',{})
            cleanup_started=cleanup.get('monotonic')
            if cleanup and (cleanup.get('pid')!=owner['pid'] or not isinstance(cleanup_started,(int,float)) or
                            not math.isfinite(cleanup_started) or cleanup_started>now):
                age=float('inf');cleanup_started=None
            action=policy.step(now,heartbeat_age=age,program_started=program_started,
                               stop=(run/'STOP').exists(),alive=exact_process(owner) is not None,cleared=session_cleanup(run)['verified'],
                               cleanup_started=cleanup_started)
            if action=='done':result.update(passed=True,sram_clear_verified=True,normal_controller_cleanup=True);break
            if action=='notify':(run/'WATCHDOG_CANCEL').write_text(policy.reason,encoding='utf-8')
            if action=='fallback':result=fallback(run,runtime,'watchdog');break
            time.sleep(.05)
    except BaseException as error:result.update(error=repr(error))
    result.update(reason=policy.reason,notified_monotonic=policy.notified)
    write_json(run/'watchdog_result.json',result);return result


def completion_ok(controller_record,cleanup,server_closed,watchdog_record,controller_returncode,watchdog_returncode,*,cancelled=False,supervision_error=False):
    return (controller_record.get('passed') is True and cleanup.get('verified') is True and server_closed is True and
            watchdog_record.get('passed') is True and not watchdog_record.get('fallback_reset_attempted') and
            watchdog_record.get('notified_monotonic') is None and controller_returncode==0 and watchdog_returncode==0 and
            not cancelled and not supervision_error)


def run_board():
    bit,binding=qualified()  # All failures up to here cause no run/device creation.
    runtime=load_runtime(binding)
    if not runtime.board.port_available(PORT):raise BoardError('Dedicated JTAG port occupied; no reuse')
    run=ROOT/'runs'/(datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'_'+uuid.uuid4().hex[:8]+'_ai_camera')
    run.mkdir(parents=True,exist_ok=False)
    shutil.copy2(bit,run/'ai_camera_frozen.sbit')
    if sha(run/'ai_camera_frozen.sbit')!=binding['bitstream_sha256']:raise BoardError('Frozen copy mismatch; no server start')
    write_json(run/'input_binding.json',binding)
    result=dict(passed=False,run=str(run),scope=SCOPE,binding=binding,flash_written=False,coremark_executed=False,PC_inference_executed=False)
    server=runtime.board.ServerManager(run,PORT);c=w=None;began=time.monotonic()
    try:
        server.ensure()
        c=runtime.board.spawn_owned(command('controller',run),run,run/'controller.log',run/'controller_owner.json')
        w=runtime.board.spawn_owned(command('watchdog',run),run,run/'watchdog.log',run/'watchdog_owner.json')
        print('AI_CAMERA_BOARD_START',str(run),flush=True)
        early=None
        while time.monotonic()-began<OUTER_MAX:
            try:server.ensure()
            except BaseException as error:
                result.setdefault('server_error',repr(error));(run/'STOP').write_text('Owned server fault',encoding='ascii')
            if c.poll() is not None and w.poll() is not None:break
            if w.poll() is not None and not session_cleanup(run)['verified']:
                if early is None:early=time.monotonic();(run/'STOP').write_text('Watchdog exited early',encoding='ascii')
                result['watchdog_early_exit']=True
                if c.poll() is not None or time.monotonic()-early>=CLEANUP_GRACE:break
            if time.monotonic()-began>=WATCHDOG_MAX:
                (run/'STOP').write_text('Outer total deadline',encoding='ascii');result['outer_deadline_stop']=True
            time.sleep(.05)
        else:result['outer_deadline_expired']=True
    except BaseException as error:
        result['error']=repr(error);(run/'STOP').write_text('Outer exception',encoding='ascii')
    finally:
        # The watchdog owns cleanup while live. Outer fallback runs only after
        # it has ended, or after exact watchdog termination at the outer bound.
        if w is not None and w.poll() is None:
            until=time.monotonic()+CLEANUP_GRACE
            while w.poll() is None and time.monotonic()<until:
                try:server.ensure()
                except Exception:pass
                time.sleep(.05)
            if w.poll() is None:
                owner=read_json(run/'watchdog_owner.json',{})
                result['watchdog_stop']=stop_exact(owner) if allowed_role(run,owner,'watchdog') else dict(stopped=False)
        watchdog_dead=w is None or w.poll() is not None
        if watchdog_dead and not session_cleanup(run)['verified']:
            result['fallback']=fallback(run,runtime,'outer_fallback');write_json(run/'outer_fallback_result.json',result['fallback'])
        clear=session_cleanup(run);result['cleanup']=clear
        result['server_close']=server_lifecycle.close_server(server,cleared=clear['verified'],watchdog_ended=watchdog_dead,native=native)
        result['controller']=read_json(run/'controller_result.json',{});result['watchdog']=read_json(run/'watchdog_result.json',{})
        result['controller_returncode']=None if c is None else c.poll();result['watchdog_returncode']=None if w is None else w.poll()
        result['passed']=completion_ok(result['controller'],clear,result['server_close']['closed'],result['watchdog'],
                                        result['controller_returncode'],result['watchdog_returncode'],
                                        cancelled=(run/'STOP').exists() or (run/'WATCHDOG_CANCEL').exists(),
                                        supervision_error=any(k in result for k in ['error','server_error','watchdog_early_exit','outer_deadline_stop','outer_deadline_expired']))
        try:result['qualified_inputs_unchanged']=qualified()[1]==binding
        except Exception as error:result.update(qualified_inputs_unchanged=False,gate_after_error=repr(error))
        result['passed']=result['passed'] and result['qualified_inputs_unchanged']
        result.update(state='completed' if result['passed'] else ('failed_cleared' if clear['verified'] else 'cleanup_unverified'),finished_local=datetime.now().isoformat())
        write_json(run/'wrapper_result.json',result);write_json(ROOT/'evidence/ai_board_control/active_board_run.json',result)
        print('AI_CAMERA_BOARD_END',result['state'],str(run),flush=True)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--dependencies',action='store_true')
    ap.add_argument('--check-only',action='store_true')
    ap.add_argument('--role',choices=['wrapper','controller','watchdog'],default='wrapper')
    ap.add_argument('--run-dir',type=Path)
    ap.add_argument('--port',default='COM11')
    args=ap.parse_args()
    if args.port!='COM11':raise BoardError('Only explicitly bound COM11 is accepted')
    if args.dependencies:
        print(json.dumps(runtime_dependencies(),indent=2));return 0
    if args.check_only:
        _,binding=qualified();print('AI_CAMERA_BOARD_GATE_PASS',binding['gate_sha256']);return 0
    if args.role=='wrapper':
        if args.run_dir is not None:raise BoardError('Wrapper creates its own private run')
        result=run_board()
    else:
        if args.run_dir is None:raise BoardError('Private run required')
        run=args.run_dir.resolve();base=ROOT/'runs'
        if run==base or not run.is_relative_to(base) or not run.is_dir():raise BoardError('Run escaped board_runs')
        result=controller(run) if args.role=='controller' else watchdog(run)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
