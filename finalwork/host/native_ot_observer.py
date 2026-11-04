"""Sample native Logos2 configuration OT while the sole UART owner works.

Import is inert. This observer uses no debugger, ADC temperature or register
profile. Only the candidate's unchanged NativeCFG adapter starts native children. check()
returns the last completed sample (None during initial startup), or raises a
sticky NativeOTObserverError. ready_event marks the first accepted sample.
stop()['stopped'] must be True before any caller issues a CFG reset.
"""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import threading
import time

LOCAL_NATIVE = Path(__file__).with_name('native_cfg.py')
_spec = importlib.util.spec_from_file_location('_ai_camera_local_native_cfg', LOCAL_NATIVE)
native = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(native)
_spec = importlib.util.spec_from_file_location('_ai_camera_native_client_lifecycle',Path(__file__).with_name('native_client_lifecycle.py'))
lifecycle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lifecycle)


class NativeOTObserverError(RuntimeError):
    pass


class _StopRequested(Exception):
    pass


class NativeOTObserver:
    def __init__(self, run, port, cfg, on_fault, *, clock=time.monotonic,
                 period_seconds=10.0, max_age_seconds=25.0, join_seconds=5.0,
                 waiter=None, process_factory=None):
        if not callable(on_fault) or not callable(clock):
            raise ValueError('Explicit fault callback and clock required')
        if not 1 <= period_seconds <= 10 or not 20 <= max_age_seconds <= 30 or not 0 < join_seconds <= 5:
            raise ValueError('Bounded 1..10s cadence, 20..30s age and <=5s join required')
        self.run = Path(run).resolve()
        if Path(cfg.run).resolve() != self.run or cfg.port != port:
            raise ValueError('CFG must belong to the exact run and server port')
        self.port, self.cfg, self.on_fault = port, cfg, on_fault
        self.clock, self.period = clock, float(period_seconds)
        self.max_age, self.join_seconds = float(max_age_seconds), float(join_seconds)
        self.waiter = waiter or (lambda event, seconds: event.wait(seconds))
        self.process_factory = process_factory or getattr(cfg, 'process_factory', None)
        self.folder = self.run / 'native_ot_observer'
        self.stop_event, self.ready_event = threading.Event(), threading.Event()
        self.finish_event = threading.Event()
        self.lock = threading.RLock()
        self.thread = None
        self.started = None
        self.last_sample = None
        self.fault = None
        self.callback_error = None
        self.attempts = []
        self.stop_record = None
        self.in_flight_label = None

    def _snapshot(self):
        with self.lock:
            reads = [row for row in self.attempts if row.get('read_succeeded')]
            return dict(started_monotonic=self.started, sample_count=len(reads),
                        ot_asserted_samples=sum(row.get('over_temp') is True for row in reads),
                        read_failures=sum(row.get('read_failed') is True for row in self.attempts),
                        cancelled_reads=sum(row.get('cancelled') is True for row in self.attempts),
                        accepted_samples=sum(row.get('accepted') is True for row in self.attempts),
                        attempts=len(self.attempts), last_sample=copy.deepcopy(self.last_sample),
                        fault=self.fault, callback_error=self.callback_error,
                        period_seconds=self.period, maximum_sample_age_seconds=self.max_age,
                        host_temperature_values_collected=False, ADC_or_JDRP_used=False,
                        mapping='Native Logos2 configuration status bit 27',
                        stopped=copy.deepcopy(self.stop_record))

    def _save(self):
        native.write_json(self.folder / 'result.json', self._snapshot())

    def _trip(self, reason):
        with self.lock:
            first = self.fault is None
            if first:
                self.fault = str(reason)
        if first:
            try:
                self.on_fault(str(reason))
            except BaseException as error:
                with self.lock:
                    self.callback_error = repr(error)
        try:
            self._save()
        except BaseException:
            # The caller still receives the sticky in-memory failure even if
            # evidence storage itself failed. Never turn it into an OT zero.
            pass

    def _cancel(self):
        if self.stop_event.is_set():
            raise _StopRequested('Native OT observer stop requested')
        with self.lock:
            fault = self.fault
        if fault is not None:
            raise NativeOTObserverError(fault)

    def start(self):
        with self.lock:
            if self.thread is not None:
                raise NativeOTObserverError('Native OT observer cannot be started twice')
            self.folder.mkdir(parents=True, exist_ok=False)
            self.started = self.clock()
            self.thread = threading.Thread(target=self._worker, name='native-ot-observer', daemon=True)
            self._save()
            self.thread.start()
        return self

    def _append(self, row):
        with self.lock:
            self.attempts.append(row)
            if row.get('read_succeeded'):
                self.last_sample = copy.deepcopy(row)
            with (self.folder / 'samples.jsonl').open('a', encoding='utf-8') as output:
                output.write(json.dumps(row, ensure_ascii=False) + '\n')
                output.flush()
        self._save()

    def _worker(self):
        try:
            sequence = 0
            while True:
                # Claim one request before normal stop can close scheduling.
                # No later loop iteration may create a fresh native request.
                with self.lock:
                    if self.stop_event.is_set() or self.finish_event.is_set():break
                    began = self.clock()
                    label = 'ot_poll_%05d' % sequence
                    sequence += 1
                    self.in_flight_label = label
                    row = dict(sequence=sequence - 1, label=label, started_monotonic=began,
                               ended_monotonic=None, read_succeeded=False, accepted=False,
                               raw=None, over_temp=None, read_failed=False, cancelled=False)
                try:
                    self._cancel()
                    output = self.cfg.call(label, 'cfg_read_device_property -device_index 0 -mode 3',
                                           20, self._cancel)
                    # NativeCFG already checks exit code and E: output; keep
                    # this check explicit for injected/test adapters as well.
                    import re
                    if re.search(r'^\s*E:', output, re.M):
                        raise NativeOTObserverError('Native OT command reported E:')
                    parsed = native.status(output)
                    log = self.run / 'native' / label / 'command.log'
                    row.update(parsed, ended_monotonic=self.clock(), read_succeeded=True,
                               log=str(log), log_sha256=native.sha(log))
                    if row['ended_monotonic'] - began > self.max_age:
                        raise NativeOTObserverError('Native OT read exceeded maximum age')
                    if parsed['over_temp']:
                        raise NativeOTObserverError('Native configuration over_temp=1')
                    if not parsed['done'] or not parsed['done_i']:
                        raise NativeOTObserverError('Native OT observation lost DONE/DONE_I')
                    if parsed['crc_error'] or parsed['id_error']:
                        raise NativeOTObserverError('Native OT observation reports CRC/ID error')
                    row['accepted'] = True
                    self._append(row)
                    self.ready_event.set()
                except _StopRequested as error:
                    row.update(ended_monotonic=self.clock(), cancelled=True, error=str(error))
                    self._append(row)
                    break
                except BaseException as error:
                    row.update(ended_monotonic=self.clock(), read_failed=not row['read_succeeded'], error=repr(error))
                    self._append(row)
                    self._trip('Native OT observation failed: ' + repr(error))
                    break
                finally:
                    with self.lock:self.in_flight_label=None
                remaining = max(0.0, self.period - (self.clock() - began))
                self.waiter(self.finish_event, remaining)
        except BaseException as error:
            self._trip('Native OT observer worker failed: ' + repr(error))

    def check(self):
        with self.lock:
            thread, began = self.thread, self.started
            sample, fault = copy.deepcopy(self.last_sample), self.fault
        if thread is None:
            raise NativeOTObserverError('Native OT observer has not started')
        if fault is not None:
            raise NativeOTObserverError(fault)
        age = self.clock() - (sample['ended_monotonic'] if sample else began)
        if not self.stop_event.is_set() and age > self.max_age:
            self._trip('Native OT sample missing/stale beyond %.1fs' % self.max_age)
        elif not self.stop_event.is_set() and not self.finish_event.is_set() and not thread.is_alive():
            self._trip('Native OT observer ended unexpectedly')
        with self.lock:
            if self.fault is not None:
                raise NativeOTObserverError(self.fault)
        return sample

    def _clients_stopped(self):
        """No PID alone is accepted, and this method never kills a process."""
        records = []
        for row in list(self.attempts):
            folder = self.run / 'native' / row['label']
            owner_file = folder / 'ownership.json'
            result_file = folder / 'process_result.json'
            if not owner_file.exists():
                # An intentional cancellation before NativeCFG.Popen creates
                # no child. Every other missing owner is unverified.
                records.append(dict(label=row['label'], stopped=bool(row.get('cancelled')),
                                    reason='cancelled_before_spawn' if row.get('cancelled') else 'missing ownership'))
                continue
            try:
                owner = native.read_json(owner_file)
                command = owner['cmdline']
                expected = [str(native.SHELL), '-file', str(folder / 'command.tcl'), '-work_dir', str(folder)]
                if (command != expected or native.normalized(owner['exe']) != native.normalized(native.SHELL)
                        or native.normalized(owner['cwd']) != native.normalized(folder)):
                    raise NativeOTObserverError('Native OT child ownership mismatch')
                process_result = native.read_json(result_file,{})
                completed=lifecycle.completed_client(owner,process_result,process_factory=self.process_factory)
                records.append(dict(label=row['label'],**completed))
            except BaseException as error:
                records.append(dict(label=row['label'], stopped=False, reason=repr(error)))
        return all(row['stopped'] for row in records), records

    def stop(self, *, complete_current=False, check=None):
        """Normal cleanup drains one started status; error cleanup cancels it.

        finish_event prevents the next poll and wakes an idle period wait.
        stop_event remains the cancellation signal seen by NativeCFG. Keeping
        those distinct avoids killing cfg_connect while its server owns USB.
        The caller's live STOP/OT/285s check and an additional20s bound apply
        throughout the drain. A failed drain is cancelled, recorded and raised;
        it never authorizes the controller to reset concurrently.
        """
        if type(complete_current) is not bool or (complete_current and not callable(check)):
            raise ValueError('Natural completion requires an explicit live safety check')
        began=self.clock();error=None
        with self.lock:
            self.finish_event.set()
            if not complete_current:self.stop_event.set()
        thread = self.thread
        if complete_current:
            try:
                while thread is not None and thread.is_alive():
                    check()
                    if self.clock()-began>=20:
                        raise TimeoutError('Native OT natural completion exceeded20s cleanup bound')
                    thread.join(timeout=.025)
                check()
            except BaseException as caught:
                error=caught;self.stop_event.set()
        if thread is not None and (not complete_current or error is not None):
            thread.join(timeout=self.join_seconds)
        thread_stopped = thread is None or not thread.is_alive()
        if thread_stopped:
            clients_stopped, children = self._clients_stopped()
        else:
            clients_stopped, children = False, []
        record = dict(stopped=thread_stopped and clients_stopped, thread_stopped=thread_stopped,
                      native_clients_stopped=clients_stopped, children=children,
                      sample_count=self._snapshot()['sample_count'], fault=self.fault,
                      ever_ready=self.ready_event.is_set(), started=self.started is not None,
                      normal_completion_requested=complete_current,
                      natural_completion_verified=complete_current and error is None and thread_stopped and clients_stopped,
                      waited_seconds=self.clock()-began)
        if error is not None:record['completion_error']=repr(error)
        if not record['stopped']:
            self._trip('Native OT observer/client stop unverified; CFG reset prohibited')
            record['fault'] = self.fault
        with self.lock:
            self.stop_record = copy.deepcopy(record)
        if self.started is not None:
            self._save()
        if error is not None:raise error
        return record
