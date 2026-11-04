"""One freshly downloaded SRAM CPU/DDR case with owned JTAG and fallback.

Import is inert. Public --case accepts the five frozen protocol checks. No
automatic upload/program retry, Flash, AI RUN or CoreMark operation exists.
Host JDRP temperature monitoring defaults on. The explicit diagnostic opt-out
retains STOP, watchdog, SRAM cleanup and the unchanged bitstream protections;
its thermal result remains unverified.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import ipaddress
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / 'host') not in sys.path:
    sys.path.insert(0, str(ROOT / 'host'))
from cpu_load_qualification import (BoardFailure, CASE_NAMES, Controller, SERVER,
    NativeCFG, allowed_child_owner, cleanup_record_verified, exact_process, normalized, port_available,
    qualified_inputs, read_json, session_cleanup, sha, snapshot, stop_exact,
    terminate_registered, validate, wait_for_owned_server, write_json)


class ServerManager:
    """Own exact server generations; replace only an exited own PID on free port."""
    def __init__(self, run, port, *, executable=SERVER, popen=subprocess.Popen,
                 process_factory=None, available=port_available, clock=time.monotonic,
                 sleeper=time.sleep, transition_grace=2.0):
        self.run, self.port, self.exe = Path(run), port, Path(executable)
        self.popen, self.process_factory, self.available = popen, process_factory, available
        self.clock, self.sleeper, self.generations = clock, sleeper, []
        self.transition_grace = transition_grace
        self.last_state = None

    def _proc(self, pid):
        if self.process_factory:
            return self.process_factory(pid)
        import psutil
        return psutil.Process(pid)

    def _pid_exists(self, pid):
        try:
            return self._proc(pid) is not None
        except Exception:
            return False

    def _connections(self):
        import psutil
        return psutil.net_connections(kind='tcp')

    def _listeners(self):
        import psutil
        return [r for r in self._connections() if r.status == psutil.CONN_LISTEN and r.laddr.port == self.port]

    @staticmethod
    def _endpoint(address):
        try:
            ip = ipaddress.ip_address(address.ip)
            if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
                ip = ip.ipv4_mapped
            return str(ip), int(address.port)
        except (AttributeError, TypeError, ValueError):
            return None

    def _busy_clients(self, owner):
        """Require an exact saved own client and matching TCP connection ends.

        A missing LISTEN snapshot alone never proves failure or busy. A known
        foreign client on our server is rejected rather than adopted.
        """
        import psutil
        files = list((self.run / 'native').glob('*/ownership.json')) if (self.run / 'native').exists() else []
        files += [self.run / 'jdrp_monitor/ownership.json']
        clients = {}
        for file in files:
            client = read_json(file, {})
            if allowed_child_owner(self.run, client) and exact_process(client, self.process_factory) is not None:
                clients[client['pid']] = client
        rows = [r for r in self._connections() if r.status == psutil.CONN_ESTABLISHED]
        busy = []
        for server_row in rows:
            local, remote = self._endpoint(server_row.laddr), self._endpoint(server_row.raddr)
            if server_row.pid != owner['pid'] or not local or not remote or local[1] != self.port:
                continue
            if not ipaddress.ip_address(local[0]).is_loopback or not ipaddress.ip_address(remote[0]).is_loopback:
                raise BoardFailure('Non-loopback client connected to owned JTAG server')
            peers = [r for r in rows if self._endpoint(r.laddr) == remote and self._endpoint(r.raddr) == local]
            known = [r for r in peers if r.pid is not None]
            if any(r.pid not in clients for r in known):
                raise BoardFailure('Established JTAG client is not an exact owned Native/DBG process')
            if known and all(r.pid in clients for r in known):
                busy.extend(r.pid for r in known)
        return sorted(set(busy))

    def _state(self, state, owner, **fields):
        identity = (state, owner.get('pid'), tuple(fields.get('client_pids', [])))
        if identity == self.last_state:
            return
        self.last_state = identity
        record = {'state': state, 'pid': owner.get('pid'), 'epoch': time.time(),
                  'monotonic': self.clock(), **fields}
        with (self.run / 'server_lifecycle.jsonl').open('a', encoding='utf-8') as out:
            import json
            out.write(json.dumps(record, ensure_ascii=False) + '\n')
        if self.generations:
            self.generations[-1]['last_state'] = record
            self.save()

    def save(self):
        write_json(self.run / 'server_generations.json', {'port': self.port, 'generations': self.generations})

    def ensure(self):
        if self.generations:
            current = self.generations[-1]['owner']
            deadline = self.clock() + self.transition_grace
            while True:
                owned = exact_process(current, self.process_factory)
                listeners = self._listeners()
                if any(row.pid != current['pid'] for row in listeners):
                    raise BoardFailure('Foreign PID occupies JTAG listener; no reuse, restart or termination')
                if owned is not None:
                    if listeners:
                        self._state('listening', current)
                        return current
                    clients = self._busy_clients(current)
                    if clients:
                        self._state('busy_owned_client', current, client_pids=clients)
                        return current
                    self._state('disconnect_or_exit_transition', current, grace_seconds=self.transition_grace)
                else:
                    if self._pid_exists(current['pid']):
                        raise BoardFailure('Old JTAG PID exists with changed ownership; no restart or stop')
                    self.generations[-1].setdefault('observed_exited_epoch', time.time())
                    if not listeners and self.available(self.port):
                        self._state('own_pid_exited_port_free', current)
                        break
                    self._state('own_pid_exited_wait_port_release', current, grace_seconds=self.transition_grace)
                if self.clock() >= deadline:
                    raise BoardFailure('Owned JTAG server has neither listener nor exact established client after bounded lifecycle grace')
                self.sleeper(.025)
        if not self.available(self.port):
            raise BoardFailure('JTAG port occupied; no reuse, restart or foreign-process termination')
        if not self.exe.is_file():
            raise BoardFailure('JTAG server executable missing')
        folder = self.run / 'server' / ('generation_%03d' % len(self.generations))
        folder.mkdir(parents=True, exist_ok=False)
        command = [str(self.exe), '-port', str(self.port), '-work_dir', str(folder)]
        with (folder / 'server.log').open('wb') as out:
            process = self.popen(command, cwd=folder, stdout=out, stderr=subprocess.STDOUT,
                                 creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        owner = snapshot(self._proc(process.pid))
        if (normalized(owner['exe']) != normalized(self.exe) or owner['cmdline'] != command
                or normalized(owner['cwd']) != normalized(folder)):
            raise BoardFailure('New JTAG server identity mismatch')
        self.generations.append({'owner': owner, 'command': command, 'exe_sha256': sha(self.exe),
                                 'started_epoch': time.time()})
        self.save()
        write_json(folder / 'ownership.json', owner)
        write_json(self.run / 'server_current.json', owner)
        deadline = self.clock() + 10
        while self.clock() < deadline:
            if exact_process(owner, self.process_factory) is None:
                raise BoardFailure('Newly owned server exited before readiness; no launch retry')
            listeners = self._listeners()
            if listeners:
                if any(r.pid != owner['pid'] for r in listeners):
                    raise BoardFailure('JTAG listener differs from exact owned server')
                self._state('listening', owner)
                return owner
            self.sleeper(.05)
        raise BoardFailure('Own JTAG server listener timeout10s')

    def close(self, *, cleared, watchdog_ended):
        if not cleared or not watchdog_ended:
            return {'closed': False, 'reason': 'Clear evidence or watchdog termination unverified; own server retained'}
        results = []
        for generation in self.generations:
            owner = generation['owner']
            if not self._pid_exists(owner['pid']):
                results.append({'stopped': True, 'pid': owner['pid'], 'already_exited': True})
            else:
                results.append(stop_exact(owner, self.process_factory))
        self.save()
        return {'closed': all(r['stopped'] for r in results), 'generations': results}


def spawn_owned(command, cwd, log, owner_file):
    import psutil
    with Path(log).open('wb') as out:
        process = subprocess.Popen(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    owner = snapshot(psutil.Process(process.pid))
    if owner['cmdline'] != command or normalized(owner['cwd']) != normalized(cwd) or normalized(owner['exe']) != normalized(command[0]):
        raise BoardFailure('Spawned Python child identity mismatch')
    write_json(owner_file, owner)
    return process


def outer_fallback(run, port, *, cfg=None, terminator=terminate_registered):
    """Used only when independent watchdog has exited; owns its own evidence."""
    record = {'source': 'outer_fallback', 'passed': False, 'cleanup': {}, 'thermal_pass': False}
    try:
        record['terminated_registered'] = terminator(run)
        if any(r.get('stopped') is not True for r in record['terminated_registered']):
            raise BoardFailure('Exact child termination failed; no concurrent CFG reset')
        cfg = cfg or NativeCFG(run, port, before_call=lambda: wait_for_owned_server(run, port))
        record['cleanup'] = cfg.reset('outer_fallback')
        record['passed'] = cleanup_record_verified(record['cleanup'])
        record['sram_clear_verified'] = record['passed']
    except BaseException as error:
        record['error'] = repr(error)
    record['state'] = 'failed_cleared' if record['passed'] else 'cleanup_unverified'
    write_json(Path(run) / 'outer_fallback_result.json', record)
    return record


def supervise(run, port, controller, watchdog, server, *, clock=time.monotonic,
              sleeper=time.sleep, fallback=outer_fallback, maximum_seconds=310):
    """Total wrapper budget includes initial server readiness (~10+310=320s)."""
    start, early_exit_at, deadline_stop_at = clock(), None, None
    record = {}
    while clock() - start < maximum_seconds:
        try:
            server.ensure()
        except Exception as error:
            if 'server_error' not in record:
                record['server_error'] = repr(error)
                (Path(run) / 'STOP').write_text('owned JTAG server unavailable', encoding='ascii')
        clear = session_cleanup(run)
        c_done, w_done = controller.poll() is not None, watchdog.poll() is not None
        if c_done and w_done:
            if not clear['verified']:
                record['fallback'] = fallback(run, port)
            break
        if w_done and not clear['verified']:
            if early_exit_at is None:
                early_exit_at = clock()
                record['watchdog_early_exit'] = True
                (Path(run) / 'STOP').write_text('independent watchdog exited early;45s controller cleanup grace', encoding='ascii')
            if c_done or clock() - early_exit_at >= 45:
                record['fallback'] = fallback(run, port)
                break
        if clock() - start >= maximum_seconds - 75 and deadline_stop_at is None:
            deadline_stop_at = clock()
            record['outer_deadline_stop'] = True
            (Path(run) / 'STOP').write_text('outer deadline approaching; cleanup grace', encoding='ascii')
        sleeper(.05)
    else:
        record['outer_deadline_expired'] = True
        (Path(run) / 'STOP').write_text('outer deadline expired; independent cleanup remains owner', encoding='ascii')
    record.update(controller_returncode=controller.poll(), watchdog_returncode=watchdog.poll(),
                  cleanup=session_cleanup(run))
    return record


def controller_command(root, run, case, port, server_port, host_temperature_monitor=True):
    command = [sys.executable, '-B', '-X', 'utf8', str(Path(root) / 'tools/run_cpu_load_board.py'),
               '--controller', '--case', case, '--port', port, '--server-port', str(server_port), '--run-dir', str(run)]
    if not host_temperature_monitor:
        command.append('--no-host-temperature-monitor')
    return command


def run_board(case, port='COM11', server_port=65444, root=ROOT, *, host_temperature_monitor=True):
    if type(host_temperature_monitor) is not bool:
        raise ValueError('host_temperature_monitor must be an explicit boolean')
    validate(case, port, server_port)
    root = Path(root).resolve()
    bit, binding = qualified_inputs(root)  # No directory, serial or process before gate.
    if not port_available(server_port):
        raise BoardFailure('JTAG server port occupied; refusing any reuse')
    base = (root.parent / 'board_runs').resolve()
    token = datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '_' + uuid.uuid4().hex[:6]
    run = base / (token + '_cpu_' + case)
    if not run.is_relative_to(base) or run == base:
        raise BoardFailure('Run escaped board_runs')
    run.mkdir(parents=True, exist_ok=False)
    frozen = run / 'cpu_load_frozen.sbit'
    shutil.copy2(bit, frozen)
    if sha(frozen) != binding['bitstream_sha256']:
        raise BoardFailure('Frozen copy mismatch')
    write_json(run / 'input_binding.json', binding)
    result = {'run': str(run), 'case': case, 'port': port, 'server_port': server_port,
              'state': 'starting', 'passed': False, 'binding': binding, 'automatic_retries': 0,
              'flash_written': False, 'AI_RUN_sent': False, 'coremark_executed': False,
              'host_temperature_monitor_enabled': host_temperature_monitor,
              'diagnostic_without_host_temperature_monitor': not host_temperature_monitor,
              'thermal_pass': False if host_temperature_monitor else None,
              'thermal_verification': 'pending' if host_temperature_monitor else 'unverified_host_monitor_disabled',
              'started_local': datetime.now().isoformat()}
    write_json(root / 'evidence/active_board_run.json', result)
    write_json(run / 'wrapper_result.json', result)
    server = ServerManager(run, server_port)
    controller = watchdog = None
    try:
        server.ensure()
        command = controller_command(root, run, case, port, server_port, host_temperature_monitor)
        controller = spawn_owned(command, run, run / 'controller.log', run / 'controller_owner.json')
        wd_command = [sys.executable, '-B', '-X', 'utf8', str(root / 'tools/cpu_load_watchdog.py'),
                      '--run-dir', str(run), '--server-port', str(server_port)]
        watchdog = spawn_owned(wd_command, run, run / 'watchdog.log', run / 'watchdog_owner.json')
        result.update(state='running', controller_pid=controller.pid, watchdog_pid=watchdog.pid)
        write_json(root / 'evidence/active_board_run.json', result)
        result['supervision'] = supervise(run, server_port, controller, watchdog, server)
    except BaseException as error:
        result['error'] = repr(error)
        (run / 'STOP').write_text('outer wrapper exception', encoding='ascii')
        # Keep ownership active while clients clean; no blind second download.
        if controller is not None:
            until = time.monotonic() + 45
            while controller.poll() is None and time.monotonic() < until:
                try:
                    server.ensure()
                except Exception:
                    pass
                time.sleep(.05)
        if watchdog is None or watchdog.poll() is not None:
            if not session_cleanup(run)['verified']:
                result['fallback'] = outer_fallback(run, server_port)
    finally:
        # Wait only for watchdog completion; if still alive at a hard deadline,
        # retain JTAG rather than obstruct its independent clear operation.
        if watchdog is not None and watchdog.poll() is None and session_cleanup(run)['verified']:
            try:
                watchdog.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
        clear = session_cleanup(run)
        wd_ended = watchdog is None or watchdog.poll() is not None
        result['cleanup'] = clear
        result['server_close'] = server.close(cleared=clear['verified'], watchdog_ended=wd_ended)
        c_result = read_json(run / 'controller_result.json', {})
        result['controller_result'] = c_result
        result.update(controller_returncode=None if controller is None else controller.poll(),
                      watchdog_returncode=None if watchdog is None else watchdog.poll())
        result['passed'] = (c_result.get('passed') is True and clear['verified'] and result['server_close']['closed']
                            and controller is not None and controller.poll() == 0 and watchdog is not None and watchdog.poll() == 0
                            and not result.get('error') and not result.get('supervision', {}).get('watchdog_early_exit')
                            and not result.get('supervision', {}).get('outer_deadline_stop')
                            and not result.get('supervision', {}).get('server_error'))
        watchdog_cancelled = read_json(run / 'watchdog_result.json', {}).get('reason') == 'STOP'
        result['state'] = ('completed' if result['passed'] else ('cancelled_cleared' if c_result.get('cancelled') or watchdog_cancelled else 'failed_cleared')) if clear['verified'] else 'cleanup_unverified'
        result['thermal_pass'] = c_result.get('thermal_pass', False) if host_temperature_monitor else None
        result['thermal_verification'] = c_result.get('thermal_verification', 'unverified') if host_temperature_monitor else 'unverified_host_monitor_disabled'
        result['verdict'] = ('CPU_UART_DDR_DIAGNOSTIC_PASS' if not host_temperature_monitor else 'CPU_UART_DDR_MONITORED_PASS') if result['passed'] else 'CPU_UART_DDR_FAIL'
        result['finished_local'] = datetime.now().isoformat()
        write_json(run / 'wrapper_result.json', result)
        write_json(root / 'evidence/active_board_run.json', result)
        print('CPU_LOAD_BOARD_END', result['state'], str(run), flush=True)
    return result


def controller_main(args):
    run = args.run_dir.resolve()
    base = (ROOT.parent / 'board_runs').resolve()
    if not run.is_relative_to(base) or run == base:
        raise BoardFailure('Controller run escaped board_runs')
    # Controller launch race: parent publishes exact owner immediately after
    # spawn, before watchdog readiness. No board access occurs during gate.
    _, binding = qualified_inputs(ROOT)
    if binding != read_json(run / 'input_binding.json'):
        raise BoardFailure('Controller qualification differs from frozen outer binding')
    controller = Controller(run, args.case, args.port, args.server_port, run / 'cpu_load_frozen.sbit', binding,
                            host_temperature_monitor=not args.no_host_temperature_monitor)
    record = controller.execute()
    return 0 if record['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=CASE_NAMES, required=True)
    parser.add_argument('--port', default='COM11')
    parser.add_argument('--server-port', type=int, default=65444)
    parser.add_argument('--no-host-temperature-monitor', action='store_true',
                        help='Explicit CPU/UART/DDR diagnostic: skip host JDRP temperature monitoring; temperature remains unverified')
    parser.add_argument('--controller', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--run-dir', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        validate(args.case, args.port, args.server_port)
        if args.controller:
            if args.run_dir is None:
                raise ValueError('Internal controller requires run-dir')
            return controller_main(args)
        if args.run_dir is not None:
            raise ValueError('Public entry creates its own unique run directory')
        return 0 if run_board(args.case, args.port, args.server_port,
                             host_temperature_monitor=not args.no_host_temperature_monitor)['passed'] else 1
    except Exception as error:
        print('CPU_LOAD_PREFLIGHT_OR_CONTROL_FAILED', repr(error), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
