"""Transport fixtures only; no device, subprocess, RTL or benchmark execution."""
from pathlib import Path
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'host'))
import coremark_uart_case as c
PREP = Path(__file__).resolve().parent / 'fixtures'
spec = importlib.util.spec_from_file_location('fixture_source', PREP / 'test_uart_parser.py')
fixtures = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixtures)


class Clock:
    def __init__(self): self.now = 0
    def __call__(self): return self.now
    def sleep(self, seconds): self.now += max(seconds, .025)


class Link:
    timeout = .05
    write_timeout = .5
    def __init__(self, data, *, chunk=19, written=32, clock=None, slow=False):
        self.ready, self.results = data.split(b'\n', 1)
        self.ready += b'\n'; self.writes = []; self.chunk = chunk
        self.written, self.clock, self.slow = written, clock, slow
    def read(self, n):
        if self.ready:
            value, self.ready = self.ready[:self.chunk], self.ready[self.chunk:]
            return value
        if self.writes and self.results:
            if self.slow: self.clock.now += 2
            value, self.results = self.results[:self.chunk], self.results[self.chunk:]
            return value
        return b''
    def write(self, data): self.writes.append(data); return self.written


class Tests(unittest.TestCase):
    def run_one(self, data=None, mode='P', **options):
        clock = Clock()
        link = Link(fixtures.fixture(mode) if data is None else data, clock=clock,
                    **options.pop('link_options', {}))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'application'
            try:
                result = c.run_case(mode, link, path, source_id=fixtures.IDENTITY,
                    nonce=fixtures.NONCE, cancel_check=options.pop('cancel', lambda: None),
                    clock=clock, sleeper=clock.sleep, **options)
            except BaseException:
                self.last_result = json.loads((path / 'result.json').read_text()) if path.exists() else None
                self.last_writes = link.writes
                raise
            self.assertEqual(result['evidence_sha256']['uart_tx.bin'], hashlib.sha256(link.writes[0]).hexdigest())
            self.assertFalse(result['board_tested'])
            self.assertEqual(len(link.writes), 1)
            self.assertEqual(len(link.writes[0]), 32)
            self.assertEqual(c.parse_uart((path / 'uart_rx.bin').read_bytes(), mode, fixtures.NONCE, fixtures.IDENTITY)['cycles'], result['cycles'])
            return result

    def test_P_and_V_arbitrary_chunks(self):
        for mode in ('P', 'V'):
            for chunk in (1, 19, 185, 4096):
                with self.subTest(mode=mode, chunk=chunk):
                    self.assertTrue(self.run_one(mode=mode, link_options={'chunk':chunk})['passed'])

    def test_CRLF(self):
        self.assertTrue(self.run_one(fixtures.fixture().replace(b'\n', b'\r\n'))['passed'])

    def test_wrong_ready_sends_zero_bytes(self):
        for value in (b'2'*64, b'1'*63+b'z'):
            with self.assertRaises(c.CaptureError):
                self.run_one(fixtures.fixture().replace(fixtures.IDENTITY.encode(), value, 1))
            self.assertEqual(self.last_writes, [])
            self.assertFalse(self.last_result['command_attempted'])

    def test_bad_record_fields(self):
        data = fixtures.fixture()
        mutations = [data.replace(b'NONCE=12345678', b'NONCE=12345679', 1),
            data.replace(b'MODE=P', b'MODE=V', 1),
            data.replace(b'SEQ=00000001', b'SEQ=00000002', 1),
            data.replace(b'SEED3=00000066', b'SEED3=00000067', 1),
            data.replace(b'0xe714', b'0x0000'),
            data.replace(b'RETURN=00000000', b'RETURN=00000001'),
            data.replace(b'IC_ACCESS=00000100', b'IC_ACCESS=00000000'),
            data.replace(b'-march=rv32i ', b'-march=rv32im '),
            data.replace(b'Total ticks      : 2000000000', b'Total ticks      : 2000000001'),
            fixtures.fixture(cycles=999999999),
            data + b'EXTRA\n', data + b'partial', data.replace(b'GCC 15', b'GCC\xff15')]
        for mutated in mutations:
            with self.subTest(mutation=mutated[-70:]), self.assertRaises(c.CaptureError):
                self.run_one(mutated)

    def test_partial_write_not_retried(self):
        for count in (0, 1, 31, None, True, 33):
            with self.subTest(count=count), self.assertRaises(c.CaptureError):
                self.run_one(link_options={'written':count})
            self.assertEqual(len(self.last_writes), 1)
            self.assertFalse(self.last_result['coremark_executed'])

    def test_missing_ready_bounded(self):
        with self.assertRaises(c.CaptureError):
            self.run_one(b'\n')
        self.assertEqual(self.last_writes, [])

    def test_missing_begin_bounded(self):
        with self.assertRaisesRegex(c.CaptureError, 'BEGIN deadline'):
            self.run_one(fixtures.fixture().split(b'\n', 1)[0] + b'\n')
        self.assertEqual(len(self.last_writes), 1)

    def test_missing_finish_bounded(self):
        with self.assertRaisesRegex(c.CaptureError, 'deadline'):
            self.run_one(b'\n'.join(fixtures.fixture().split(b'\n')[:-2])+b'\n')

    def test_cancellation_before_command(self):
        def cancel(): raise RuntimeError('STOP fixture')
        with self.assertRaisesRegex(RuntimeError, 'STOP fixture'):
            self.run_one(cancel=cancel)
        self.assertEqual(self.last_writes, [])

    def test_truthy_cancel_before_command(self):
        with self.assertRaisesRegex(c.CaptureError, 'Outer cancellation'):
            self.run_one(cancel=lambda:True)
        self.assertEqual(self.last_writes, [])

    def test_cancel_during_command_attempt_callback_sends_zero_bytes(self):
        state={'cancel':False}
        def event(row):
            if row['event']=='command_attempt':state['cancel']=True
        with self.assertRaisesRegex(c.CaptureError,'Outer cancellation'):
            self.run_one(cancel=lambda:state['cancel'],on_event=event)
        self.assertEqual(self.last_writes,[])
        self.assertTrue(self.last_result['command_attempted'])
        self.assertFalse(self.last_result['benchmark_requested'])

    def test_slow_output_still_hard_total_budget(self):
        with self.assertRaises(c.CaptureError):
            self.run_one(maximum_seconds=2, link_options={'slow':True})

    def test_invalid_input_has_no_directory(self):
        for kwargs in ({'source_id':'bad'}, {'nonce':0}, {'maximum_seconds':121}, {'mode':'X'}):
            defaults = dict(mode='P', source_id=fixtures.IDENTITY, nonce=fixtures.NONCE,
                            cancel_check=lambda:None)
            defaults.update(kwargs)
            with tempfile.TemporaryDirectory() as folder:
                out = Path(folder) / 'application'
                with self.assertRaises(c.CaptureError):
                    c.run_case(link=Link(fixtures.fixture()), out_dir=out, **defaults)
                self.assertFalse(out.exists())


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    out = ROOT / 'evidence/board_control_tests'
    out.mkdir(parents=True, exist_ok=True)
    paths = [Path(__file__), ROOT/'host/coremark_uart_case.py', ROOT/'host/coremark_uart_parser.py', PREP/'test_uart_parser.py', PREP/'uart_parser.py']
    record = {'passed': result.wasSuccessful(), 'test_methods': result.testsRun,
              'hardware_access': False, 'benchmark_executed':False,
              'synthetic_transport_fixtures_only':True,
              'source_sha256': {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
    (out/'uart_adapter_result.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    raise SystemExit(0 if result.wasSuccessful() else 1)
