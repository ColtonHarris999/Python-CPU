#!/usr/bin/env python3.14
"""Run the host unit tests and record each test's wall time.

Arguments are the same as ``python -m unittest`` (``discover -s pycore/tests``).
The benchmark file is written whether the suite passes or fails.
"""

from __future__ import annotations

import pathlib
import sys
import time
import unittest

from bench_report import write_benchmark

# `python -m unittest` puts the working directory on sys.path. Running this
# file as a script puts pycore/tools there instead, which hides `import pycore`.
_ROOT = pathlib.Path(__file__).resolve().parents[2]
for _entry in (str(_ROOT), ""):
    if _entry not in sys.path:
        sys.path.insert(0, _entry)


class _TimingResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity, *, rows: list[dict]):
        super().__init__(stream, descriptions, verbosity)
        self._rows = rows
        self._t0 = 0.0

    def startTest(self, test) -> None:
        self._t0 = time.perf_counter()
        super().startTest(test)

    def stopTest(self, test) -> None:
        wall = time.perf_counter() - self._t0
        status, detail = "PASS", ""
        for kind, bucket in (("FAIL", self.failures), ("ERROR", self.errors)):
            for case, tb in bucket:
                if case is test:
                    status = kind
                    detail = tb.strip().splitlines()[-1] if tb else ""
        for case, reason in self.skipped:
            if case is test:
                status, detail = "SKIP", reason
        self._rows.append({
            "status": status,
            "area": "host",
            "name": str(test),
            "wall_s": round(wall, 6),
            "detail": detail,
        })
        super().stopTest(test)


class _TimingRunner(unittest.TextTestRunner):
    def __init__(self, rows: list[dict]):
        super().__init__(verbosity=1)
        self._rows = rows

    def run(self, test):
        result = _TimingResult(self.stream, self.descriptions, self.verbosity, rows=self._rows)
        unittest.registerResult(result)
        result.failfast = self.failfast
        result.buffer = self.buffer
        start = time.perf_counter()
        startTestRun = getattr(result, "startTestRun", None)
        if startTestRun is not None:
            startTestRun()
        try:
            test(result)
        finally:
            stopTestRun = getattr(result, "stopTestRun", None)
            if stopTestRun is not None:
                stopTestRun()
        stop = time.perf_counter()
        result.printErrors()
        self.stream.writeln(result.separator2)
        self.stream.writeln(f"Ran {result.testsRun} test{'s' if result.testsRun != 1 else ''} "
                             f"in {stop - start:.3f}s")
        self.stream.writeln()
        if result.wasSuccessful():
            self.stream.writeln("OK")
        return result


def main(argv: list[str] | None = None) -> int:
    rows: list[dict] = []
    started = time.perf_counter()
    program = unittest.main(
        module=None,
        argv=argv or sys.argv,
        exit=False,
        testRunner=_TimingRunner(rows),
    )
    elapsed = time.perf_counter() - started
    result = program.result
    failed = len(result.failures) + len(result.errors)
    skipped = len(result.skipped)
    passed = result.testsRun - failed - skipped
    path = write_benchmark(
        "host-tests", rows, elapsed_s=elapsed, passed=passed, failed=failed,
    )
    print(f"benchmark: {path}")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
