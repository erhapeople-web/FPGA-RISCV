"""Bounded SRAM-only NativeCFG adapter. Import performs no hardware operation.

The Logos2 mapping is Fabric Configuration User Guide table16, pp101-102.
Debugger's first-generation Logos labels are deliberately not used here.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time

SHELL = Path(os.environ.get('J5_PDS_BIN', r'D:\FPGA2\PDS_2022.2-SP6.4\bin')) / 'cdt_cfg_shell.exe'
_PUBLISH_LOCKS = {}
_PUBLISH_LOCKS_GUARD = threading.Lock()


class NativeError(RuntimeError):
    pass


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, record, *, replace_timeout=1.0, clock=time.monotonic, sleeper=time.sleep):
    """Publish complete JSON with bounded Windows sharing-conflict retries.

    A reader without FILE_SHARE_DELETE may briefly prevent os.replace even
    when it only reads the destination. Retry that publication step <=1s;
    persistent failures raise with the complete private temporary file kept
    in error.preserved_temporary_path. No program/upload operation is retried.
    Same-path threads serialize, and every call has a unique own temp name.
    """
    if (isinstance(replace_timeout, bool) or not isinstance(replace_timeout, (int, float))
            or not math.isfinite(replace_timeout) or not 0 <= replace_timeout <= 1):
        raise ValueError('JSON replacement retry budget must be finite in0..1s')
    encoded = json.dumps(record, indent=2, ensure_ascii=False)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    parent = path.parent.resolve()
    path = parent / path.name
    key = os.path.normcase(str(path))
    with _PUBLISH_LOCKS_GUARD:
        lock = _PUBLISH_LOCKS.setdefault(key, threading.Lock())
    with lock:
        descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '.', suffix='.tmp', dir=parent)
        tmp = Path(name).resolve()
        if tmp.parent != parent:
            os.close(descriptor)
            raise ValueError('JSON temporary path escaped the explicitly selected parent')
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as output:
            output.write(encoded)
            output.flush()
        deadline, delay = clock() + replace_timeout, .005
        while True:
            try:
                # Only this call's exact private temporary file is consumed.
                # No wildcard/recursive cleanup and no other writer's file.
                os.replace(tmp, path)
                return
            except OSError as error:
                error.preserved_temporary_path = str(tmp)
                sharing = isinstance(error, PermissionError) or getattr(error, 'winerror', None) in (5, 32, 33)
                remaining = deadline - clock()
                if not sharing or remaining <= 0:
                    raise
                sleeper(min(delay, remaining))
                delay = min(.05, delay * 2)


def _read_utf8(path):
    try:
        return Path(path).read_text(encoding='utf-8')
    except PermissionError as original:
        if os.name != 'nt' or getattr(original, 'winerror', None) is not None:
            raise
        # CPython's CRT open can lose WinError32 and expose only errno13.
        # Confirm the native result instead of treating every ACL denial as
        # a sharing conflict. This fallback remains a plain read-only open.
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        create = kernel.CreateFileW
        create.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                           wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        create.restype = wintypes.HANDLE
        read = kernel.ReadFile
        read.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                         ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
        read.restype = wintypes.BOOL
        close = kernel.CloseHandle
        close.argtypes, close.restype = [wintypes.HANDLE], wintypes.BOOL
        handle = create(str(path), 0x80000000, 0x00000007, None, 3, 0x80, None)
        if handle == ctypes.c_void_p(-1).value:
            error = ctypes.WinError(ctypes.get_last_error())
            error.filename = str(path)
            raise error from original
        chunks = []
        try:
            while True:
                buffer, count = ctypes.create_string_buffer(65536), wintypes.DWORD()
                if not read(handle, buffer, len(buffer), ctypes.byref(count), None):
                    raise ctypes.WinError(ctypes.get_last_error())
                if not count.value:
                    break
                chunks.append(buffer.raw[:count.value])
        finally:
            close(handle)
        return b''.join(chunks).decode('utf-8')


def read_json(path, default=None, *, read_timeout=.25, clock=time.monotonic,
              sleeper=time.sleep, on_retry=None):
    """Read a complete current JSON snapshot; only WinError32/33 retry <=.25s.

    No previous data is cached. Exhausted conflicts, missing files, genuine
    permissions and invalid JSON retain the original default/raise semantics.
    """
    if (isinstance(read_timeout, bool) or not isinstance(read_timeout, (int, float))
            or not math.isfinite(read_timeout) or not 0 <= read_timeout <= .25
            or (on_retry is not None and not callable(on_retry))):
        raise ValueError('JSON read retry budget must be finite in0..0.25s')
    deadline, delay = clock() + read_timeout, .005
    while True:
        try:
            return json.loads(_read_utf8(path))
        except (OSError, ValueError) as error:
            remaining = deadline - clock()
            if isinstance(error, OSError) and getattr(error, 'winerror', None) in (32, 33) and remaining > 0:
                if on_retry is not None:
                    on_retry(error)
                sleeper(min(delay, remaining))
                delay = min(.025, delay * 2)
                continue
            if default is not None:
                return default
            raise


def normalized(path):
    return os.path.normcase(str(Path(path).resolve()))


def snapshot(process):
    return {'pid': process.pid, 'create_time': process.create_time(),
            'exe': process.exe(), 'cmdline': process.cmdline(), 'cwd': process.cwd()}


def exact_process(owner, process_factory=None):
    """A PID alone is never ownership. Missing/changed attributes fail closed."""
    if process_factory is None:
        import psutil
        process_factory = psutil.Process
    try:
        p = process_factory(owner['pid'])
        if (type(owner['pid']) is not int or p.pid != owner['pid'] or
                abs(p.create_time() - owner['create_time']) > .000001 or
                normalized(p.exe()) != normalized(owner['exe']) or
                p.cmdline() != owner['cmdline']):
            return None
        if 'cwd' in owner and normalized(p.cwd()) != normalized(owner['cwd']):
            return None
        return p
    except Exception:
        return None


def stop_exact(owner, process_factory=None, seconds=2):
    p = exact_process(owner, process_factory)
    if p is None:
        # Absence and ownership mismatch are distinct; never kill the new PID.
        try:
            import psutil
            exists = psutil.pid_exists(owner['pid']) if process_factory is None else process_factory(owner['pid']) is not None
        except Exception:
            exists = False
        return {'stopped': not exists, 'ownership_mismatch': bool(exists), 'pid': owner.get('pid')}
    try:
        p.terminate()
        try:
            p.wait(timeout=seconds)
        except Exception:
            # Recheck after waiting to protect against PID reuse.
            again = exact_process(owner, process_factory)
            if again is None:
                return {'stopped': False, 'ownership_mismatch': True, 'pid': owner['pid']}
            again.kill()
            again.wait(timeout=seconds)
        return {'stopped': True, 'pid': owner['pid']}
    except Exception as error:
        return {'stopped': False, 'pid': owner['pid'], 'error': repr(error)}


def status(text):
    chips = re.findall(r'^\s*(PG[A-Za-z0-9]+)\s*$', text, re.M)
    values = re.findall(r'Status Register:\s*0x([0-9a-fA-F]{1,8})\b', text)
    if chips != ['PG2L200H'] or len(values) != 1:
        raise NativeError('Expected one PG2L200H and exactly one native configuration status')
    n = int(values[0], 16)
    return {'raw': f'0x{n:08x}', 'over_temp': bool(n & (1 << 27)),
            'done': bool(n & (1 << 12)), 'done_i': bool(n & (1 << 13)),
            'crc_error': bool(n & 2), 'id_error': bool(n & 1),
            'mapping': 'Logos2 Configuration Guide table16'}


def clear_verified(row):
    """OT does not mask SRAM clear evidence, and is never a thermal pass."""
    if not isinstance(row, dict):
        return False
    try:
        n = int(row['raw'], 16)
    except (KeyError, TypeError, ValueError):
        return False
    if not 0 <= n <= 0xffffffff:
        return False
    expected = {'done': bool(n & (1 << 12)), 'done_i': bool(n & (1 << 13)),
                'crc_error': bool(n & 2), 'id_error': bool(n & 1),
                'over_temp': bool(n & (1 << 27))}
    return all(row.get(k) is v for k, v in expected.items()) and not (n & ((1 << 12) | (1 << 13) | 3))


class NativeCFG:
    def __init__(self, run_dir, server_port, *, shell=SHELL, popen=subprocess.Popen,
                 process_factory=None, clock=time.monotonic, sleeper=time.sleep, before_call=None):
        self.run = Path(run_dir).resolve()
        self.port, self.shell, self.popen = server_port, Path(shell), popen
        self.process_factory, self.clock, self.sleeper = process_factory, clock, sleeper
        self.before_call = before_call

    def call(self, label, body, timeout, cancel_check=None):
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,48}', label) or timeout not in (20, 30):
            raise ValueError('Unexpected NativeCFG label or budget')
        folder = self.run / 'native' / label
        folder.mkdir(parents=True, exist_ok=False)
        script, log = folder / 'command.tcl', folder / 'command.log'
        script.write_text(f'cfg_connect -ip 127.0.0.1 -port {self.port}\ncfg_scan_chain\n{body}\ncfg_disconnect\n', encoding='ascii')
        command = [str(self.shell), '-file', str(script), '-work_dir', str(folder)]
        if cancel_check:
            cancel_check()
        if self.before_call:
            self.before_call()
        if cancel_check:
            cancel_check()
        with log.open('wb') as out:
            p = self.popen(command, cwd=folder, stdout=out, stderr=subprocess.STDOUT,
                           creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            if self.process_factory is None:
                import psutil
                proc = psutil.Process(p.pid)
            else:
                proc = self.process_factory(p.pid)
            owner = snapshot(proc)
            if normalized(owner['exe']) != normalized(self.shell) or owner['cmdline'] != command or normalized(owner['cwd']) != normalized(folder):
                # Do not act on an unverified process; watchdog will refuse it too.
                raise NativeError('New NativeCFG process ownership mismatch')
            owner.update(kind='native_cfg', script=str(script), script_sha256=sha(script))
            write_json(folder / 'ownership.json', owner)
            started = self.clock()
            try:
                while p.poll() is None:
                    if cancel_check:
                        cancel_check()
                    if self.clock() - started >= timeout:
                        raise TimeoutError('NativeCFG ' + label + ' exceeded budget')
                    self.sleeper(.025)
            except BaseException:
                record = stop_exact(owner, self.process_factory, seconds=1)
                write_json(folder / 'interrupted.json', record)
                if not record['stopped']:
                    raise NativeError('Interrupted NativeCFG could not be stopped with exact ownership')
                raise
            finally:
                write_json(folder / 'process_result.json', {'returncode': p.poll(), 'owner': owner})
        output = log.read_text(encoding='utf-8', errors='replace')
        if p.returncode != 0 or re.search(r'^\s*E:', output, re.M):
            raise NativeError('NativeCFG command failed: ' + label)
        return output

    def baseline(self, cancel_check=None):
        return status(self.call('baseline', 'cfg_read_device_property -device_index 0 -mode 3', 20, cancel_check))

    def program(self, bit, cancel_check=None):
        bit = Path(bit).resolve()
        if any(c in str(bit) for c in '{}\r\n') or bit.suffix.lower() != '.sbit':
            raise ValueError('Unsafe bitstream pathname')
        output = self.call('program', 'cfg_assign_file -file {' + bit.as_posix() + '} -device_index 0\n'
                           'cfg_program -device_index 0\ncfg_read_device_property -device_index 0 -mode 3', 30, cancel_check)
        row = status(output)
        if ('The done bit is 1' not in output or 'Executing : cfg_program -device_index 0 successfully.' not in output
                or not row['done'] or not row['done_i'] or row['crc_error'] or row['id_error']):
            raise NativeError('Native SRAM program completion/status not verified')
        return row

    def reset(self, source='controller'):
        if source not in ('controller', 'watchdog', 'outer_fallback'):
            raise ValueError('Unexpected reset source')
        row = status(self.call(source + '_reset', 'cfg_reset_fpga -device_index 0\n'
                              'cfg_read_device_property -device_index 0 -mode 3', 20))
        return {'source': source, 'status': row, 'sram_clear_verified': clear_verified(row),
                'thermal_pass': False if row['over_temp'] else None}
