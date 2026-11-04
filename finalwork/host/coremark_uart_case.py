"""One bounded, already-qualified CoreMark UART invocation. Import is inert.

No serial/JTAG opening, programming, retry, or cleanup lives here. The outer
controller owns thermal readiness, the sole UART reader, watchdog and reset.
"""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import secrets
import time

from coremark_uart_parser import CaptureError, CRC, make_command, mode_nonce, parse_uart, VALIDATED


def ready_line(source_id):
    if not isinstance(source_id, str) or not re.fullmatch(r'[0-9a-f]{64}', source_id):
        raise CaptureError('Frozen SOURCE_ID must contain64 lowercase hex digits')
    return ('J5_COREMARK_READY V=1 SEQ=00000000 SOURCE_ID=' + source_id +
            ' CPU_HZ=100000000 ITERATIONS=5000 DATA_SIZE=2000 ISA=RV32I COMMAND_BYTES=32')


class StreamValidator:
    """Bound every line to this image/mode/nonce before accepting a finish."""
    def __init__(self, mode, nonce, source_id):
        mode_nonce(mode, nonce)
        self.mode, self.nonce, self.source_id = mode, nonce, source_id
        seed = 0 if mode == 'P' else 0x3415
        token = f'MODE={mode} NONCE={nonce:08x}'
        name = 'performance' if mode == 'P' else 'validation'
        self.patterns = [re.escape(ready_line(source_id)),
            re.escape('CM5_BEGIN SEQ=00000001 ' + token),
            re.escape(f'CM5_SEEDS SEQ=00000002 {token} SEED1={seed:08x} SEED2={seed:08x} SEED3=00000066 SEED4=00001388 SEED5=00000000 CPU_HZ=100000000 ITERATIONS=5000'),
            re.escape(f'2K {name} run parameters for coremark.'),
            r'CoreMark Size\s*:\s*666', r'Total ticks\s*:\s*[0-9]+',
            r'Total time \(secs\)\s*:\s*[0-9]+', r'Iterations/Sec\s*:\s*[0-9]+',
            r'Iterations\s*:\s*5000', r'Compiler version\s*:\s*GCC [ -~]+',
            r'Compiler flags\s*:\s*[ -~]+', r'Memory location\s*:\s*STATIC SRAM']
        for key, value in CRC[mode].items():
            prefix = 'seedcrc' if key == 'seedcrc' else '[0]' + key
            self.patterns.append(re.escape(prefix) + r'\s*:\s*0x' + value)
        self.patterns += [r'\[0\]crcfinal\s*:\s*0x[0-9a-f]{4}', re.escape(VALIDATED),
            r'EXACT_CYCLES_HEX=[0-9a-f]{16} CPU_HZ=100000000 ITERATIONS=5000 SEQ=00000003 ' + re.escape(token),
            r'CACHE_COUNTERS IC_ACCESS=[0-9a-f]{8} IC_MISS=[0-9a-f]{8} DC_ACCESS=[0-9a-f]{8} DC_MISS=[0-9a-f]{8}',
            re.escape('AI_CPU_COREMARK_FINISHED SEQ=00000004 ' + token + ' RETURN=00000000')]
        self.index = 0

    @property
    def finished(self):
        return self.index == len(self.patterns)

    def feed(self, raw):
        if not isinstance(raw, bytes) or not raw.endswith(b'\n') or len(raw) > 4096:
            raise CaptureError('Incomplete/oversized UART line')
        try:
            line = raw[:-1].removesuffix(b'\r').decode('ascii')
        except UnicodeDecodeError as exc:
            raise CaptureError('Non-ASCII CoreMark UART') from exc
        if self.finished or not re.fullmatch(self.patterns[self.index], line):
            raise CaptureError(f'Unexpected CoreMark record at index{self.index}: {line[:100]!r}')
        index = self.index
        self.index += 1
        return 'ready' if index == 0 else ('begin' if index == 1 else ('finished' if self.finished else 'record'))


def run_case(mode, link, out_dir, *, source_id, cancel_check,
             timeout_seconds=3, commit_timeout_seconds=20, maximum_seconds=120,
             clock=time.monotonic, sleeper=time.sleep, nonce=None, on_event=None):
    """Controller-compatible adapter; max budget includes startup and quiet tail.

    The production loader's timeout keyword names are accepted for injection
    compatibility. CoreMark uses30s READY/BEGIN and120s total, not a3s result
    timeout: the benchmark deliberately has no UART output while it runs.
    """
    nonce = (secrets.randbelow(0xffffffff) + 1) if nonce is None else nonce
    mode_nonce(mode, nonce)
    validator = StreamValidator(mode, nonce, source_id)
    if type(maximum_seconds) not in (int, float) or not 1 <= maximum_seconds <= 120:
        raise CaptureError('CoreMark adapter requires a finite total budget<=120s')
    if getattr(link, 'timeout', None) is None or not 0 < link.timeout <= .1:
        raise CaptureError('Already-open UART requires finite read timeout<=0.1s')
    if getattr(link, 'write_timeout', None) is None or not 0 < link.write_timeout <= .5:
        raise CaptureError('Already-open UART requires finite write timeout<=0.5s')
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=False)
    started = clock()
    result = {'passed': False, 'mode': mode, 'nonce': nonce, 'source_id': source_id,
              'scope': 'Real transport invocation only; outer controller binds hardware, thermal and cleanup',
              'benchmark_requested': False, 'coremark_executed': False, 'board_tested': False,
              'command_attempted': False, 'automatic_retries': 0, 'AI_RUN_sent': False,
              'data_location': 'local SRAM through active D-Cache; physical DDR tested separately',
              'started_local': datetime.now().isoformat()}
    capture, pending = bytearray(), bytearray()
    command = make_command(mode, nonce)
    finish_at = begin_deadline = None

    def check():
        if cancel_check():
            raise CaptureError('Outer cancellation requested; no further UART bytes')
        now = clock()
        if now - started >= maximum_seconds:
            raise CaptureError('CoreMark bounded UART invocation deadline')
        if validator.index == 0 and now - started >= min(30, maximum_seconds):
            raise CaptureError('CoreMark READY deadline')
        if validator.index == 1 and begin_deadline is not None and now >= begin_deadline:
            raise CaptureError('CoreMark BEGIN deadline')

    try:
        with (out / 'uart_rx.bin').open('xb') as rx, (out / 'uart_tx.bin').open('xb') as tx, (out / 'events.jsonl').open('x', encoding='utf-8') as events:
            def event(kind, **fields):
                row = {'event': kind, 'elapsed_seconds': clock()-started, **fields}
                events.write(json.dumps(row) + '\n'); events.flush()
                if on_event is not None:
                    on_event(dict(row))
            while True:
                check()
                data = link.read(4096)
                if not isinstance(data, bytes):
                    raise CaptureError('UART read returned non-byte data')
                if data:
                    rx.write(data); rx.flush()
                    capture.extend(data); pending.extend(data)
                    if len(capture) > 131072 or len(pending) > 8192:
                        raise CaptureError('CoreMark UART exceeded bounded capture/line size')
                    while b'\n' in pending:
                        raw, _, remaining = pending.partition(b'\n')
                        pending[:] = remaining
                        kind = validator.feed(bytes(raw) + b'\n')
                        event(kind, record_index=validator.index-1)
                        if kind == 'ready':
                            # Receiving any pre-command result bytes is invalid.
                            if pending:
                                raise CaptureError('Unexpected UART following READY before command')
                            check()
                            result['command_attempted'] = True
                            event('command_attempt', bytes=len(command), command_hex=command.hex())
                            # Controller event persistence may block briefly;
                            # a guard/STOP raised during it must prevent magic.
                            check()
                            count = link.write(command)
                            if type(count) is int and 0 <= count <= len(command):
                                tx.write(command[:count]); tx.flush()
                            if count != len(command) or type(count) is not int:
                                raise CaptureError('Partial or invalid command write; no resend allowed')
                            result['benchmark_requested'] = True
                            begin_deadline = clock() + 30
                            event('command_written', bytes=count)
                        elif kind == 'begin':
                            if not result['benchmark_requested']:
                                raise CaptureError('BEGIN before command')
                            result['coremark_executed'] = True
                        elif kind == 'finished':
                            finish_at = clock()
                    if validator.finished and pending:
                        raise CaptureError('Trailing partial UART after CoreMark finish')
                if validator.finished and not pending and clock()-finish_at >= .25:
                    break
                sleeper(.005)
            parsed = parse_uart(bytes(capture), mode, nonce, source_id)
            result.update(parsed, benchmark_requested=True, coremark_executed=True,
                          command_attempted=True, status='strict_CPU_UART_result_accepted')
    except BaseException as error:
        result.update(error_type=type(error).__name__, error=str(error), status='failed_requires_controller_clear')
        raise
    finally:
        result.update(finished_local=datetime.now().isoformat(), elapsed_seconds=clock()-started,
                      records_accepted=validator.index, received_bytes=len(capture),
                      evidence_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                       for p in out.iterdir() if p.is_file() and p.name != 'result.json'})
        (out / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    return result
