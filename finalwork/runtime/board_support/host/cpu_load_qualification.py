"""Fail-closed qualification and one CPU/DDR board-session state machine.

Import is inert. Dependencies are injectable for offline tests. No CoreMark,
Flash, AI RUN, unsolicited UART retries or application DTR/RTS changes exist.
"""
from __future__ import annotations

from datetime import datetime
import math
import os
from pathlib import Path
import queue
import re
import shutil
import socket
import threading
import time

from native_cfg import (NativeCFG, clear_verified, exact_process, normalized,
                        read_json, sha, snapshot, stop_exact, write_json)

ROOT = Path(__file__).resolve().parents[1]
FIRMWARE_SHA = '795e88337ef81a67c1836a745587feb0eb4ed53b3e5078904a084eec61569cda'
SERVER = Path(os.environ.get('J5_PDS_BIN', r'D:\FPGA2\PDS_2022.2-SP6.4\bin')) / 'cdt_js.exe'
CASE_NAMES = ('duplicate64', 'duplicate_changed', 'input_pattern_a', 'input_pattern_b', 'input_bad_sha')
HEARTBEAT_INTERVAL_SECONDS = .25
HEARTBEAT_TIMEOUT_SECONDS = 8
JDRP_STARTUP_SECONDS = 60
PROOFS = (
    'synth_rom/result.json', 'evidence/load_guard_tests/result.json',
    'evidence/load_integration/result.json', 'evidence/ddr_reset_tests/result.json',
    'evidence/load_qualification/result.json', 'evidence/host_cpu_ddr_tests/result.json',
    'evidence/jdrp_host_tests/result.json', 'evidence/board_control_tests/result.json',
    'evidence/board_control_tests/windows_publish_result.json')
REQUIRED_INPUTS = set(PROOFS) | {
    'routed_timing.json', 'pds/report_timing/test_ddr.rtr', 'pds/report_timing/rtr.db',
    'pds/place_route/test_ddr.prr', 'pds/synthesize/test_ddr_syn.vm',
    'host/protocol.py', 'host/cpu_uart_ddr_checks.py', 'host/test_cpu_uart_ddr_checks.py',
    'host/source_provenance.json', 'host/native_cfg.py', 'host/cpu_load_qualification.py',
    'host/jdrp_monitor.py', 'tools/run_cpu_load_board.py', 'tools/cpu_load_watchdog.py',
    'sim/board_control/test_board_control.py', 'sim/board_control/test_windows_publish.py'}
HASH_MAP_KEYS = {'source_hashes', 'input_hashes', 'source_sha256', 'output_sha256', 'artifact_hashes'}
READ_ONLY_DEPENDENCY_ROOTS = (
    Path(r'E:\study1\FPGA\A_AI_host_handoff_20261028'),
    Path(r'E:\study1\FPGA\test\J5_IO_20261029'),
    Path(r'E:\study1\FPGA\test\J5_VIDEO_SOAK_20261030'),
    Path(r'D:\FPGA2\PDS_2022.2-SP6.4'),
    Path(r'D:\RISC-V\iverilog'))


class QualificationError(RuntimeError):
    pass


class BoardFailure(RuntimeError):
    pass


class BoardCancelled(BoardFailure):
    pass


def checked_path(base, name):
    base = Path(base).resolve()
    path = (base / name).resolve()
    if path == base or not path.is_relative_to(base):
        raise QualificationError('Input escaped candidate: ' + str(name))
    return path


def verify_map(base, mapping):
    if not isinstance(mapping, dict) or not mapping:
        raise QualificationError('Missing nonempty input hash map')
    for name, digest in mapping.items():
        path = checked_path(base, name)
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest) or not path.is_file() or sha(path) != digest:
            raise QualificationError('Qualified input hash changed: ' + str(path))


def verify_dependency_map(root, mapping):
    """Embedded proofs may use explicitly authorized, read-only vendor/parent data.

    Relative paths retain strict candidate containment. Absolute dependencies
    require the candidate or one exact named root above, plus a complete SHA.
    This policy does not apply to manifest/identity maps, which stay local.
    """
    if not isinstance(mapping, dict) or not mapping:
        raise QualificationError('Missing dependency hash map')
    root = Path(root).resolve()
    allowed = [root, *(p.resolve() for p in READ_ONLY_DEPENDENCY_ROOTS)]
    for name, digest in mapping.items():
        original = Path(name)
        if original.is_absolute():
            path = original.resolve()
            if not any(path != base and path.is_relative_to(base) for base in allowed):
                raise QualificationError('Read-only proof dependency outside explicit roots: ' + str(path))
        else:
            path = checked_path(root, name)
        if (not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest)
                or not path.is_file() or sha(path) != digest):
            raise QualificationError('Read-only proof dependency changed: ' + str(path))


def verify_embedded(root, item):
    """Verify recorded executable/source/log bindings, never arbitrary JSON names."""
    if isinstance(item, list):
        for value in item:
            verify_embedded(root, value)
    elif isinstance(item, dict):
        for key in HASH_MAP_KEYS:
            if isinstance(item.get(key), dict):
                verify_dependency_map(root, item[key])
        if 'path' in item and 'sha256' in item:
            verify_dependency_map(root, {item['path']: item['sha256']})
        for key in ('log', 'vvp', 'netlist'):
            if isinstance(item.get(key), str) and key + '_sha256' in item:
                verify_dependency_map(root, {item[key]: item[key + '_sha256']})
        for key, value in item.items():
            if key not in HASH_MAP_KEYS:
                verify_embedded(root, value)


def qualified_inputs(root=ROOT):
    """Read-only, before ports/processes/run creation. Requires a final root seal."""
    root = Path(root).resolve()
    try:
        manifest = read_json(root / 'evidence/bitstream.json')
        identity = read_json(root / 'identity.json')
        hashes = manifest.get('qualification_sha256', {})
        if not REQUIRED_INPUTS.issubset(hashes):
            raise QualificationError('Missing final CPU_LOAD qualification bindings: ' + repr(sorted(REQUIRED_INPUTS - set(hashes))))
        verify_map(root, hashes)
        if sha(root / 'identity.json') != manifest['identity_sha256']:
            raise QualificationError('Sealed identity mismatch')
        expected = {'device': 'PG2L200H/-6/FBB676', 'clock_mhz': 100,
                    'setup_uncertainty_ns': .5, 'hold_uncertainty_ns': .2,
                    'diagnostic_mode': 0, 'cpu_load_mode': 1,
                    'video_enabled': False, 'load_limit_seconds': 300,
                    'firmware_sha256': FIRMWARE_SHA}
        for key, value in expected.items():
            if identity.get(key) != value or (isinstance(value, bool) and type(identity.get(key)) is not bool):
                raise QualificationError('Unexpected CPU_LOAD identity: ' + key)
        if any(type(identity.get(key)) is not int for key in ('clock_mhz', 'diagnostic_mode', 'cpu_load_mode', 'load_limit_seconds')):
            raise QualificationError('CPU_LOAD mode/frequency/duration types are invalid')
        verify_map(root / 'src', identity['all_source_files'])
        verify_map(root / 'constraints', identity['constraints'])
        verify_map(root / 'pds', identity['scripts'])
        if sha(root / 'src/firmware/production.bin') != FIRMWARE_SHA:
            raise QualificationError('Production ROM changed')
        bit = checked_path(root / 'pds', manifest['bitstream'])
        if (bit.suffix.lower() != '.sbit' or type(manifest['size']) is not int or manifest['size'] <= 100000
                or bit.stat().st_size != manifest['size'] or sha(bit) != manifest['sha256']):
            raise QualificationError('Sealed SRAM bitstream changed')
        route_hash = sha(root / 'pds/place_route/test_ddr_pnr.adf')
        if route_hash != manifest['routed_db_sha256']:
            raise QualificationError('Routed database changed')
        timing = read_json(root / 'routed_timing.json')
        if (timing.get('passed') is not True or timing.get('failed_groups') or
                Path(timing['report']).resolve() != root / 'pds/report_timing/test_ddr.rtr' or
                not all(isinstance(timing.get(k), (int, float)) and math.isfinite(timing[k]) and timing[k] >= 0
                        for k in ('cpu_setup_ns', 'cpu_hold_ns'))):
            raise QualificationError('Routed timing failed')
        groups = timing.get('groups')
        if not groups or any(not math.isfinite(g['slack_ns']) or g['slack_ns'] < 0 or g.get('failed_endpoints', 0) != 0 for g in groups):
            raise QualificationError('Routed timing group failed/missing')
        proofs = {}
        for name in PROOFS:
            proof = read_json(root / name)
            if proof.get('passed') is not True:
                raise QualificationError('Offline proof failed: ' + name)
            verify_embedded(root, proof)
            proofs[name] = proof
        fs = proofs['evidence/board_control_tests/windows_publish_result.json']
        fs_cases = {'preserved_old_writer_real_regression_red', 'preserved_old_reader_real_regression_red',
                    'real_transient_lock_release_green', 'real_persistent_lock_fails_bounded_and_preserves_complete_tmp',
                    'real_transient_deny_read_release_green', 'real_persistent_deny_read_default',
                    'real_persistent_deny_read_raise', 'real_missing_corrupt_nonsharing_access_semantics_unchanged',
                    'real_shared_readers_atomic_sequence_stress', 'real_three_writer_unique_tmp_serialization'}
        if (fs.get('platform') != 'win32' or fs.get('red_only') is not False
                or fs.get('windows_native_sharing_conflict_verified') is not True
                or fs.get('old_writer_regression_red') is not True or fs.get('old_reader_regression_red') is not True
                or {c.get('name') for c in fs.get('cases', [])} != fs_cases
                or any(c.get('passed') is not True for c in fs.get('cases', []))):
            raise QualificationError('Real Windows file-sharing regression incomplete')
        rom = proofs['synth_rom/result.json']
        if (rom.get('words') != 16384 or rom.get('negative_check', {}).get('passed') is not True
                or rom.get('netlist_sha256') != sha(root / 'pds/synthesize/test_ddr_syn.vm')
                or rom.get('active_build_report_sha256') != manifest['identity_sha256']
                or rom.get('firmware_binary_sha256') != FIRMWARE_SHA):
            raise QualificationError('Actual synthesized ROM binding failed')
        load = proofs['evidence/load_qualification/result.json']
        if (load.get('qualification_ready') is not True or load.get('routed_db_sha256') != route_hash
                or load.get('physical_proof', {}).get('passed') is not True
                or load.get('source_constraint_scope', {}).get('passed') is not True
                or load.get('exception_inventory', {}).get('passed') is not True
                or not all(load.get('functional_reset', {}).get(k, {}).get('passed') is True for k in ('DDR', 'guard'))):
            raise QualificationError('Actual CPU_LOAD physical/source/reset proof incomplete')
        required_load_sources = {str(root / p) for p in (
            'identity.json', 'pds/place_route/test_ddr_pnr.adf', 'src/test_ddr.v',
            'src/rtl/thermal/thermal_load_guard.v', 'src/rtl/thermal/thermal_load_monitor.v',
            'constraints/thermal_load.fdc', 'tools/qualify_cpu_load_route.py', 'tools/cpu_load_physical_proof.py')}
        if not required_load_sources.issubset(load.get('input_hashes', {})):
            raise QualificationError('Current CPU_LOAD source proof bindings missing')
        if not re.search(r'Use of ADC\s*\|\s*1\s*\|', (root / 'pds/place_route/test_ddr.prr').read_text(encoding='utf-8')):
            raise QualificationError('Exactly one implemented ADC required')
        integration = proofs['evidence/load_integration/result.json']
        rows = integration.get('results', [])
        if not {'cpu_load_loader', 'loader', 'ddr_mac_normal', 'ddr_mac_badread', 'diagnostic_stages', 'diagnostic_cpu_wait'}.issubset({r.get('case') for r in rows}) or any(r.get('passed') is not True for r in rows):
            raise QualificationError('Current full-top regression cases incomplete')
        provenance = read_json(root / 'host/source_provenance.json')
        verify_dependency_map(root, {provenance['production_ELF']: provenance['production_ELF_sha256']})
        if (provenance.get('production_binary_sha256') != FIRMWARE_SHA or
                sha(root / 'host/protocol.py') != provenance.get('protocol_copy_sha256')):
            raise QualificationError('Production host/ELF source proof changed')
        return bit, {'bitstream_sha256': manifest['sha256'], 'identity_sha256': manifest['identity_sha256'],
                     'routed_db_sha256': route_hash, 'manifest_sha256': sha(root / 'evidence/bitstream.json'),
                     'qualification_hashes': dict(hashes), 'clock_mhz': 100, 'firmware_sha256': FIRMWARE_SHA}
    except (KeyError, TypeError, ValueError, OSError) as error:
        raise QualificationError('Incomplete CPU_LOAD qualification: ' + repr(error)) from error


def validate(case, port, server_port):
    if case not in CASE_NAMES:
        raise ValueError('Unknown CPU/DDR case')
    if not re.fullmatch(r'COM[1-9][0-9]{0,3}', port or ''):
        raise ValueError('Explicit Windows COM port required')
    if type(server_port) is not int or not 1024 <= server_port <= 65535:
        raise ValueError('Explicit server port in1024..65535 required')


def port_available(port):
    import psutil
    if any(row.status == psutil.CONN_LISTEN and row.laddr.port == port for row in psutil.net_connections(kind='tcp')):
        return False
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
                s.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            s.bind(('127.0.0.1', port))
        return True
    except OSError:
        return False


def serial_factory(port):
    from serial.tools import list_ports
    import serial
    matches = [p for p in list_ports.comports() if (p.vid, p.pid) == (0x10c4, 0xea60)]
    if len(matches) != 1 or matches[0].device.upper() != port:
        raise BoardFailure('Expected unique requested CP210x port')
    # Opening may cause OS driver modem initialization. Application never sets
    # DTR/RTS and never resets/flushes RX, preserving early startup bytes.
    return serial.Serial(port=port, baudrate=115200, timeout=.05, write_timeout=.5)


class QueuedSerial:
    """Exactly one reader owns real UART RX; protocol consumes only this queue."""
    timeout = .05
    write_timeout = .5

    def __init__(self, serial, run, on_error):
        self.serial, self.run, self.on_error = serial, Path(run), on_error
        self.stop_event = threading.Event()
        self.queue, self.buffer = queue.Queue(), bytearray()
        self.rx = (self.run / 'raw_rx.bin').open('xb')
        self.tx = (self.run / 'raw_tx.bin').open('xb')
        self.thread = threading.Thread(target=self._read, name='cpu-uart-reader', daemon=True)
        self.tx_lock = threading.Lock()
        self.thread.start()

    def _read(self):
        try:
            while not self.stop_event.is_set():
                data = self.serial.read(4096)
                if not isinstance(data, bytes):
                    raise BoardFailure('Serial returned non-byte RX')
                if data:
                    self.rx.write(data)
                    self.rx.flush()
                    self.queue.put(data)
        except Exception as error:
            if not self.stop_event.is_set():
                self.on_error('UART reader: ' + repr(error))

    def read(self, n):
        if not self.buffer:
            try:
                self.buffer.extend(self.queue.get(timeout=self.timeout))
            except queue.Empty:
                return b''
        data = bytes(self.buffer[:n])
        del self.buffer[:n]
        return data

    def write(self, data):
        with self.tx_lock:
            count = self.serial.write(data)
            if type(count) is int and 0 <= count <= len(data):
                self.tx.write(data[:count])
                self.tx.flush()
            return count

    def close(self):
        self.stop_event.set()
        try:
            self.serial.close()
        finally:
            self.thread.join(timeout=1)
            if self.thread.is_alive():
                raise BoardFailure('UART reader failed to stop')
            self.rx.close()
            self.tx.close()


def cleanup_record_verified(record):
    return (isinstance(record, dict) and record.get('sram_clear_verified') is True
            and clear_verified(record.get('status')))


def session_cleanup(run):
    """Accept controller OR independent fallback; never forge a controller marker."""
    for filename, source in [('SESSION_FINISHED', 'controller'), ('watchdog_result.json', 'watchdog'),
                             ('outer_fallback_result.json', 'outer_fallback')]:
        record = read_json(Path(run) / filename, {})
        clear = record.get('cleanup', {})
        if (clear.get('source') == source and cleanup_record_verified(clear)
                and (source != 'controller' or record.get('jdrp_stopped_before_cfg_reset') is True)):
            return {'verified': True, 'source': source, 'cleanup': clear}
    return {'verified': False, 'source': None}


class Controller:
    def __init__(self, run, case, port, server_port, frozen_bit, binding, *, cfg=None,
                 monitor_factory=None, uart_factory=serial_factory, case_runner=None,
                 watchdog_alive=None, clock=time.monotonic, sleeper=time.sleep, server_ready_check=None,
                 runtime_watchdog_alive=None, host_temperature_monitor=True):
        if type(host_temperature_monitor) is not bool:
            raise ValueError('host_temperature_monitor must be an explicit boolean')
        self.host_temperature_monitor = host_temperature_monitor
        self.run, self.case, self.port = Path(run), case, port
        self.server_port, self.bit, self.binding = server_port, Path(frozen_bit), binding
        self.cfg = cfg or NativeCFG(self.run, server_port, before_call=lambda: wait_for_owned_server(self.run, server_port))
        self.monitor_factory, self.uart_factory, self.case_runner = monitor_factory, uart_factory, case_runner
        self.watchdog_alive = watchdog_alive or self._watchdog_alive
        self.runtime_watchdog_alive = runtime_watchdog_alive or watchdog_alive or self._watchdog_runtime_alive
        self.watchdog_owner_snapshot = None
        self.server_ready_check = server_ready_check or (lambda: wait_for_owned_server(self.run, server_port))
        self.clock, self.sleeper = clock, sleeper
        self.cancel, self.exit_threads, self.observer_stop, self.ready_event = (threading.Event() for _ in range(4))
        self.lock = threading.RLock()
        self.reason, self.cancelled = None, False
        self.monitor = self.link = self.heartbeat = self.observer = None
        self.watchdog_watcher = None
        self.watchdog_check_started = None
        self.watchdog_check_inflight = False
        self.watchdog_check_timeout = HEARTBEAT_TIMEOUT_SECONDS
        self.heartbeat_stats = {'sequence': 0, 'maximum_loop_gap_seconds': 0}
        self.record = {'case': case, 'state': 'starting', 'passed': False, 'binding': binding,
                       'flash_written': False, 'AI_RUN_sent': False, 'coremark_executed': False,
                       'application_modem_line_toggles': False, 'program_attempted': False,
                       'board_programmed': False, 'cleanup': {},
                       'host_temperature_monitor_enabled': host_temperature_monitor,
                       'diagnostic_without_host_temperature_monitor': not host_temperature_monitor,
                       'jdrp_started': False, 'jdrp_ready_before_payload': None,
                       'thermal_pass': False if host_temperature_monitor else None,
                       'thermal_verification': 'pending' if host_temperature_monitor else 'unverified_host_monitor_disabled',
                       'heartbeat_timeout_seconds': HEARTBEAT_TIMEOUT_SECONDS,
                       'runtime_watchdog_identity': 'Independent PID/create-time checker; full executable/command/cwd identity before board access',
                       'started_local': datetime.now().isoformat()}

    def save(self):
        with self.lock:
            write_json(self.run / 'controller_result.json', self.record)

    def trip(self, reason, cancelled=False):
        with self.lock:
            if not self.cancel.is_set():
                self.reason, self.cancelled = str(reason), cancelled
                self.record['guard_reason'] = self.reason
            self.cancel.set()

    def check(self):
        if (self.run / 'STOP').exists():
            self.trip('user/external STOP', True)
        if (self.run / 'WATCHDOG_CANCEL').exists():
            self.trip('independent watchdog cancellation', (self.run / 'STOP').exists())
        if self.cancel.is_set():
            raise (BoardCancelled if self.cancelled else BoardFailure)(self.reason)

    def _watchdog_alive(self):
        owner = read_json(self.run / 'watchdog_owner.json', {})
        if exact_process(owner) is None:
            return False
        self.watchdog_owner_snapshot = owner
        return True

    def _watchdog_runtime_alive(self):
        """Initial full owner stays fixed; no repeated exe/cmdline/cwd lookups."""
        import psutil
        owner = self.watchdog_owner_snapshot
        if not owner:
            return False
        try:
            process = psutil.Process(owner['pid'])
            return process.pid == owner['pid'] and abs(process.create_time() - owner['create_time']) <= .000001
        except (psutil.Error, KeyError, TypeError, ValueError, OSError):
            return False

    def _watchdog_liveness(self):
        """Any blocking process metadata is isolated from heartbeat writes.

        Heartbeat observes this worker's inflight age and fails closed at8s;
        a wedged identity check cannot remain silently trusted indefinitely.
        """
        status = {'checks': 0, 'maximum_check_seconds': 0, 'inflight': False}
        while not self.exit_threads.is_set():
            self.watchdog_check_started = self.clock()
            self.watchdog_check_inflight = True
            try:
                status.update(inflight=True, started_monotonic=self.watchdog_check_started)
                write_json(self.run / 'watchdog_liveness.json', status)
                alive = self.runtime_watchdog_alive()
                completed = self.clock()
                elapsed = max(0, completed - self.watchdog_check_started)
                status.update(checks=status['checks'] + 1, inflight=False,
                              last_check_seconds=elapsed, last_completed_monotonic=completed,
                              maximum_check_seconds=max(status['maximum_check_seconds'], elapsed), alive=bool(alive))
                write_json(self.run / 'watchdog_liveness.json', status)
                if not alive:
                    self.trip('independent watchdog exited or PID creation identity changed')
                    break
            except Exception as error:
                self.trip('watchdog liveness checker failed: ' + repr(error))
                status.update(inflight=False, error=repr(error))
                write_json(self.run / 'watchdog_liveness.json', status)
                break
            finally:
                self.watchdog_check_inflight = False
            self.exit_threads.wait(HEARTBEAT_INTERVAL_SECONDS)

    def _heartbeat(self):
        previous = None
        while not self.exit_threads.is_set():
            try:
                now = self.clock()
                gap = 0 if previous is None else max(0, now - previous)
                previous = now
                self.heartbeat_stats = {'sequence': self.heartbeat_stats['sequence'] + 1,
                    'maximum_loop_gap_seconds': max(self.heartbeat_stats['maximum_loop_gap_seconds'], gap)}
                write_json(self.run / 'heartbeat.json', {'epoch': time.time(), 'monotonic': now, 'pid': os.getpid(),
                           'interval_seconds': HEARTBEAT_INTERVAL_SECONDS, 'timeout_seconds': HEARTBEAT_TIMEOUT_SECONDS,
                           **self.heartbeat_stats})
                if (self.run / 'STOP').exists():
                    self.trip('user/external STOP', True)
                if (self.run / 'WATCHDOG_CANCEL').exists():
                    self.trip('independent watchdog cancellation', (self.run / 'STOP').exists())
                if (self.watchdog_check_inflight and self.watchdog_check_started is not None
                        and now - self.watchdog_check_started >= self.watchdog_check_timeout):
                    self.trip('watchdog liveness check stalled beyond8s; independent heartbeat remains active')
            except Exception as error:
                self.trip('heartbeat failure: ' + repr(error))
            self.exit_threads.wait(HEARTBEAT_INTERVAL_SECONDS)

    def _observe(self):
        # This sole thread owns monitor.ready/poll. Main owns stop only after join.
        started = self.clock()
        try:
            while not self.observer_stop.is_set():
                if not self.ready_event.is_set():
                    if self.monitor.ready():
                        self.ready_event.set()
                    elif self.clock() - started >= JDRP_STARTUP_SECONDS:
                        raise BoardFailure(f'JDRP not ready within{JDRP_STARTUP_SECONDS}s initial startup')
                else:
                    self.monitor.poll()
                self.observer_stop.wait(.05)
        except Exception as error:
            self.trip('JDRP observer: ' + repr(error))

    def execute(self, *, wait_ready=True):
        """Caller created unique run and independently spawned watchdog first."""
        touched = False
        try:
            if wait_ready:
                deadline = self.clock() + 10
                while not ((self.run / 'WATCHDOG_READY').exists() and (self.run / 'watchdog_owner.json').exists()):
                    self.check()
                    if self.clock() >= deadline:
                        raise BoardFailure('WATCHDOG_READY missing within10s')
                    self.sleeper(.025)
            if not self.watchdog_alive():
                raise BoardFailure('Independent watchdog is not alive')
            if wait_ready:
                ready = read_json(self.run / 'WATCHDOG_READY', {})
                owner = read_json(self.run / 'watchdog_owner.json', {})
                if ready.get('watchdog_pid') != owner.get('pid') or ready.get('controller_pid') != os.getpid():
                    raise BoardFailure('WATCHDOG_READY does not identify this exact session')
            self.heartbeat = threading.Thread(target=self._heartbeat, name='cpu-heartbeat', daemon=True)
            self.heartbeat.start()
            self.watchdog_watcher = threading.Thread(target=self._watchdog_liveness, name='cpu-watchdog-liveness', daemon=True)
            self.watchdog_watcher.start()
            self.check()
            self.record['state'] = 'baseline'
            self.save()
            touched = True
            baseline = self.cfg.baseline(self.check)
            self.record['baseline'] = baseline
            if baseline.get('over_temp') or not clear_verified(baseline):
                raise BoardFailure('Baseline OT/error or FPGA was not cold/cleared')
            # UART is opened before programming; no flush/reset_input_buffer.
            self.link = QueuedSerial(self.uart_factory(self.port), self.run, self.trip)
            self.check()
            if sha(self.bit) != self.binding['bitstream_sha256']:
                raise BoardFailure('Frozen bitstream changed before programming')
            self.record.update(state='programming', program_attempted=True, program_started_monotonic=self.clock())
            (self.run / 'PROGRAM_ATTEMPTED').write_text(datetime.now().isoformat(), encoding='ascii')
            self.save()
            programmed = self.cfg.program(self.bit, self.check)
            self.record['program_status'] = programmed
            self.record['board_programmed'] = True
            if programmed.get('over_temp'):
                raise BoardFailure('NativeCFG reports Logos2 over_temp after program')
            self.check()
            if self.host_temperature_monitor:
                self.server_ready_check()
                self.check()
                if self.monitor_factory is None:
                    from jdrp_monitor import JdrpMonitor
                    self.monitor_factory = JdrpMonitor
                self.monitor = self.monitor_factory(self.server_port, self.run, code_shift=4,
                                                    on_guard=lambda reason: self.trip('JDRP guard: ' + str(reason)), max_seconds=300)
                self.monitor.start()
                self.record['jdrp_started'] = True
                self.observer = threading.Thread(target=self._observe, name='cpu-jdrp-observer', daemon=True)
                self.observer.start()
                self.record['state'] = 'waiting_jdrp_ready'
                self.save()
                deadline = self.clock() + JDRP_STARTUP_SECONDS
                while not self.ready_event.wait(.025):
                    self.check()
                    if self.clock() >= deadline:
                        raise BoardFailure(f'JDRP not ready within{JDRP_STARTUP_SECONDS}s initial startup')
            self.check()
            if self.case_runner is None:
                from cpu_uart_ddr_checks import run_case
                self.case_runner = run_case
            self.record.update(state='cpu_uart_ddr', jdrp_ready_before_payload=True if self.host_temperature_monitor else None)
            self.save()
            application = self.case_runner(self.case, self.link, self.run / 'application', cancel_check=self.check,
                                           timeout_seconds=3, commit_timeout_seconds=20, maximum_seconds=120)
            self.check()
            self.record['application'] = application
            if application.get('passed') is not True:
                raise BoardFailure('CPU/DDR case did not pass its explicit verdict')
            self.record['application_passed'] = True
        except BaseException as error:
            self.record['error'] = repr(error)
            self.record['cancelled'] = self.cancelled or isinstance(error, BoardCancelled)
        finally:
            # JDRP and CFG may not own JTAG concurrently. Never clear until the
            # observer exited AND the exactly owned debugger is confirmed stopped.
            self.observer_stop.set()
            observer_dead = True
            if self.observer is not None:
                self.observer.join(timeout=1)
                observer_dead = not self.observer.is_alive()
            debugger_stopped = self.monitor is None
            if self.monitor is not None and observer_dead:
                try:
                    stopped = self.monitor.stop()
                    self.record['jdrp_stop'] = stopped
                    debugger_stopped = stopped.get('owned_process_stopped') is True
                    if stopped.get('guard_errors') or stopped.get('guard_event'):
                        self.record['error'] = self.record.get('error') or 'JDRP guard recorded during cleanup'
                except BaseException as error:
                    self.record['jdrp_stop_error'] = repr(error)
            self.record['jdrp_stopped_before_cfg_reset'] = debugger_stopped and observer_dead
            if touched and debugger_stopped and observer_dead:
                try:
                    self.record['cleanup'] = self.cfg.reset('controller')
                except BaseException as error:
                    self.record['cleanup_error'] = repr(error)
            if self.link is not None:
                try:
                    self.link.close()
                except BaseException as error:
                    self.record['serial_close_error'] = repr(error)
            self.exit_threads.set()
            if self.heartbeat is not None:
                self.heartbeat.join(timeout=1)
            if self.watchdog_watcher is not None:
                self.watchdog_watcher.join(timeout=1)
                self.record['watchdog_liveness_thread_stopped'] = not self.watchdog_watcher.is_alive()
                if self.watchdog_watcher.is_alive():
                    self.record['error'] = self.record.get('error') or 'watchdog liveness worker failed to stop after cleanup'
            self.record['heartbeat_stats'] = dict(self.heartbeat_stats)
            cleared = cleanup_record_verified(self.record['cleanup'])
            # A true OT remains a failed thermal result even when reset succeeds.
            cleanup_ot = self.record['cleanup'].get('status', {}).get('over_temp') is True
            success = (self.record.get('application_passed') is True and not self.record.get('error')
                       and not self.cancel.is_set() and cleared and debugger_stopped and observer_dead
                       and not cleanup_ot and not self.record.get('serial_close_error'))
            state = ('completed' if success else ('cancelled_cleared' if self.record.get('cancelled') else 'failed_cleared')) if cleared else 'cleanup_unverified'
            self.record.update(state=state, passed=success, sram_clear_verified=cleared,
                               thermal_pass=success if self.host_temperature_monitor else None,
                               thermal_verification=('monitored_pass' if success else 'monitored_failure') if self.host_temperature_monitor else 'unverified_host_monitor_disabled',
                               verdict=('CPU_UART_DDR_DIAGNOSTIC_PASS' if not self.host_temperature_monitor else 'CPU_UART_DDR_MONITORED_PASS') if success else 'CPU_UART_DDR_FAIL',
                               finished_local=datetime.now().isoformat())
            self.save()
            write_json(self.run / 'SESSION_FINISHED', self.record)
        return self.record


class WatchdogPolicy:
    """Pure policy. STOP/HB/200s request45s cleanup; dead controller immediate."""
    def __init__(self, started, *, active_max=200, heartbeat_max=HEARTBEAT_TIMEOUT_SECONDS, grace=45):
        self.started, self.active_max, self.heartbeat_max, self.grace = started, active_max, heartbeat_max, grace
        self.notified, self.reason = None, None

    def step(self, now, *, alive, stop, heartbeat_age, cleanup_verified):
        if cleanup_verified:
            return 'finished'
        if not alive:
            self.reason = self.reason or 'controller died before verified cleanup'
            return 'fallback'
        reason = 'STOP' if stop else ('heartbeat expired' if heartbeat_age >= self.heartbeat_max else ('active200s deadline' if now - self.started >= self.active_max else None))
        if reason is not None and self.notified is None:
            self.notified, self.reason = now, reason
            return 'notify'
        if self.notified is not None and now - self.notified >= self.grace:
            return 'fallback'
        return 'wait'


def allowed_child_owner(run, owner):
    """Whitelist exact registered commands. Server is a sibling and forbidden."""
    run = Path(run).resolve()
    try:
        command, exe = owner['cmdline'], Path(owner['exe']).resolve()
        if len(command) == 5 and exe.name.lower() == 'cdt_cfg_shell.exe':
            script = Path(command[2]).resolve()
            work = Path(command[4]).resolve()
            return (command[1] == '-file' and command[3] == '-work_dir' and script.parent == work
                    and work.is_relative_to(run / 'native') and script.name == 'command.tcl'
                    and normalized(exe) == normalized(Path(r'D:\FPGA2\PDS_2022.2-SP6.4\bin\cdt_cfg_shell.exe')))
        if len(command) == 3 and exe.name.lower() == 'cdt_dbg.exe':
            script = Path(command[2]).resolve()
            return command[1] == '-file' and script.is_relative_to(run / 'jdrp_monitor') and normalized(exe) == normalized(Path(r'D:\FPGA2\PDS_2022.2-SP6.4\bin\cdt_dbg.exe'))
    except (KeyError, TypeError, ValueError, OSError):
        pass
    return False


def allowed_controller_owner(run, owner):
    try:
        command = owner['cmdline']
        # This single opt-in diagnostic switch may appear only once at the end.
        if len(command) == 15 and command[-1] == '--no-host-temperature-monitor':
            command = command[:-1]
        if (len(command) != 14 or normalized(command[0]) != normalized(owner['exe'])
                or Path(owner['exe']).stem.lower() not in ('python', 'pythonw', 'python3')
                or command[1:7] != ['-B', '-X', 'utf8', str(ROOT / 'tools/run_cpu_load_board.py'), '--controller', '--case']
                or command[8] != '--port' or command[10] != '--server-port'
                or command[12] != '--run-dir' or command[13] != str(Path(run).resolve())):
            return False
        validate(command[7], command[9], int(command[11]))
        return True
    except (KeyError, TypeError, ValueError, OSError):
        return False


def terminate_registered(run, *, process_factory=None, stop_fn=stop_exact, process_iter=None):
    """Seal controller spawning before exact-client takeover; never name-kill.

    A live controller is suspended/reverified before child discovery. A dead
    controller requires a bounded-identity PPID scan, including unregistered
    clients. Any uncertainty yields stopped=false, forbidding concurrent CFG.
    """
    import psutil
    run = Path(run).resolve()
    records, discovered = [], []
    controller = read_json(run / 'controller_owner.json', {})
    if not allowed_controller_owner(run, controller):
        return [{'kind': 'controller', 'stopped': False, 'reason': 'controller owner command is outside this exact run'}]
    lookup = process_factory or psutil.Process
    iterate = process_iter or psutil.process_iter
    suspension_attempted = False

    def probe_controller():
        try:
            candidate = lookup(controller['pid'])
        except (psutil.NoSuchProcess, ProcessLookupError):
            return None
        # An occupied old PID with another creation time must not be scanned,
        # resumed, stopped, or treated as the deceased controller's family.
        if abs(candidate.create_time() - controller['create_time']) > .000001:
            raise BoardFailure('controller PID was reused; takeover refused')
        if exact_process(controller, lookup) is None:
            raise BoardFailure('controller executable/command/cwd identity changed or unavailable')
        return candidate

    def failed(reason):
        record = {'kind': 'controller_takeover', 'stopped': False, 'reason': str(reason),
                  'suspension_attempted': suspension_attempted}
        if suspension_attempted:
            # Restore only the still-exact controller after a failed takeover,
            # so it can honor STOP and perform its own cleanup. Never claim it
            # or a partially suspended process was successfully stopped.
            own = exact_process(controller, lookup)
            if own is not None:
                try:
                    own.resume()
                    record['exact_controller_resumed'] = True
                except Exception as error:
                    record['resume_error'] = repr(error)
            else:
                record['resume_refused_identity_unavailable'] = True
        records.append(record)
        return records

    def capture(child):
        row = snapshot(child)
        if row['create_time'] <= controller['create_time']:
            raise BoardFailure('discovered child predates recorded controller')
        if allowed_child_owner(run, row):
            discovered.append(row)
        elif Path(row['exe']).name.lower() in ('cdt_cfg_shell.exe', 'cdt_dbg.exe'):
            raise BoardFailure('unknown JTAG child command or foreign run; no process touched')

    try:
        proc = probe_controller()
        if proc is not None:
            suspension_attempted = True
            proc.suspend()  # All controller threads, including child creation.
            frozen = probe_controller()
            if frozen is None:
                raise BoardFailure('controller exited during suspension; discovery incomplete')
            for child in frozen.children(recursive=True):
                capture(child)
            mode = 'suspended_exact_controller'
        else:
            # Only inspect PPID first. Unrelated processes never have their
            # executable/arguments queried or receive termination signals.
            for child in iterate():
                try:
                    parent = child.ppid()
                    if parent != controller['pid'] or child.create_time() <= controller['create_time']:
                        continue
                    capture(child)
                except psutil.NoSuchProcess:
                    continue  # A vanished process cannot contend with CFG.
            if probe_controller() is not None:
                raise BoardFailure('old controller PID reappeared during orphan discovery')
            mode = 'confirmed_dead_controller_exact_ppid_scan'
        owners = list((run / 'native').glob('*/ownership.json')) if (run / 'native').exists() else []
        debugger_owner = run / 'jdrp_monitor/ownership.json'
        if debugger_owner.exists():
            owners.append(debugger_owner)
        registered = []
        for path in owners:
            row = read_json(path)
            if not allowed_child_owner(run, row):
                raise BoardFailure('invalid registered JTAG owner command: ' + str(path))
            registered.append(row)
        if proc is not None:
            stopped = stop_fn(controller, lookup)
            records.append({'kind': 'controller', 'discovery_mode': mode, **stopped})
            if stopped.get('stopped') is not True:
                return failed('exact suspended controller termination unverified')
        else:
            records.append({'kind': 'controller', 'stopped': True, 'pid': controller['pid'],
                            'discovery_mode': mode, 'reason': 'old controller PID confirmed absent'})
        seen = set()
        for owner in registered + discovered:
            identity = (owner['pid'], owner['create_time'])
            if identity in seen:
                continue
            seen.add(identity)
            records.append({'kind': owner.get('kind', 'jtag_client'), **stop_fn(owner, lookup)})
        return records
    except Exception as error:
        return failed(repr(error))


def wait_for_owned_server(run, port, seconds=4, *, clock=time.monotonic, sleeper=time.sleep):
    """Wait for outer owner to replace only its exited server generation."""
    import psutil
    until = clock() + seconds
    while clock() < until:
        owner = read_json(Path(run) / 'server_current.json', {})
        p = exact_process(owner)
        listeners = [r for r in psutil.net_connections(kind='tcp') if r.status == psutil.CONN_LISTEN and r.laddr.port == port]
        if p is not None and listeners and all(r.pid == owner['pid'] for r in listeners):
            return
        if listeners and any(r.pid != owner.get('pid') for r in listeners):
            raise BoardFailure('JTAG port taken by another process; no reuse/termination')
        sleeper(.025)
    raise BoardFailure(f'Own JTAG server was not available within bounded{seconds}s readiness window')


def run_watchdog(run, server_port, *, cfg=None, process_factory=None, clock=time.monotonic,
                 sleeper=time.sleep, terminator=terminate_registered, heartbeat_clock=time.time):
    """Independent process entry implementation; all policy inputs are mockable."""
    run = Path(run).resolve()
    controller_owner = read_json(run / 'controller_owner.json')
    if exact_process(controller_owner, process_factory) is None:
        raise BoardFailure('Refuse readiness for an unowned controller')
    if not allowed_controller_owner(run, controller_owner):
        raise BoardFailure('Controller command does not belong to this run')
    record = {'source': 'watchdog', 'passed': False, 'cleanup': {}, 'fallback_reset_attempted': False,
              'controller_pid': controller_owner['pid'], 'started_epoch': heartbeat_clock(),
              'heartbeat_timeout_seconds': HEARTBEAT_TIMEOUT_SECONDS}
    cfg = cfg or NativeCFG(run, server_port, before_call=lambda: wait_for_owned_server(run, server_port))
    policy = WatchdogPolicy(clock())
    write_json(run / 'WATCHDOG_READY', {'controller_pid': controller_owner['pid'],
                                       'watchdog_pid': os.getpid(), 'active_max_seconds': 200,
                                       'cleanup_grace_seconds': 45, 'heartbeat_timeout_seconds': HEARTBEAT_TIMEOUT_SECONDS})
    try:
        while True:
            verified = session_cleanup(run)
            hb = read_json(run / 'heartbeat.json', {})
            age = max(0, heartbeat_clock() - hb.get('epoch', record['started_epoch']))
            if hb and hb.get('pid') != controller_owner['pid']:
                age = float('inf')
            action = policy.step(clock(), alive=exact_process(controller_owner, process_factory) is not None,
                                 stop=(run / 'STOP').exists(), heartbeat_age=age, cleanup_verified=verified['verified'])
            if action == 'finished':
                record.update(passed=True, sram_clear_verified=True, cleanup_source=verified['source'],
                              observed_cleanup=verified['cleanup'], normal_controller_cleanup=True)
                break
            if action == 'notify':
                (run / 'WATCHDOG_CANCEL').write_text(policy.reason, encoding='utf-8')
                record.update(reason=policy.reason, notified_monotonic=policy.notified)
                write_json(run / 'watchdog_progress.json', record)
            if action == 'fallback':
                (run / 'WATCHDOG_CANCEL').write_text(policy.reason, encoding='utf-8')
                record.update(reason=policy.reason, fallback_reset_attempted=True)
                stopped = terminator(run, process_factory=process_factory)
                record['terminated_registered'] = stopped
                if any(row.get('stopped') is not True for row in stopped):
                    raise BoardFailure('Exact controller/JTAG child termination unverified; refusing concurrent CFG reset')
                record['cleanup'] = cfg.reset('watchdog')
                record['sram_clear_verified'] = cleanup_record_verified(record['cleanup'])
                record['passed'] = record['sram_clear_verified']
                break
            sleeper(.05)
    except BaseException as error:
        record['error'] = repr(error)
        record['sram_clear_verified'] = False
    finally:
        clear = record.get('cleanup', {})
        record['thermal_pass'] = False  # Watchdog cleanup never certifies the application or temperature.
        fallback_state = 'cancelled_cleared' if policy.reason == 'STOP' else 'failed_cleared'
        record['state'] = (fallback_state if record.get('fallback_reset_attempted') else 'completed') if record.get('sram_clear_verified') else 'cleanup_unverified'
        record['finished_epoch'] = heartbeat_clock()
        write_json(run / 'watchdog_result.json', record)
    return record
