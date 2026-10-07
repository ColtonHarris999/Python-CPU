#!/usr/bin/env python3.14
"""Program measured by Callgrind. Instrumentation stays off until asked.

Only ``sys`` and ``ctypes`` are imported before the measured ``compile``.
Importing ``argparse`` / ``json`` / ``traceback`` runs a lot of Python and
would make the first user ``compile()`` a warm one. Those modules are
imported after instrumentation stops.

``--instr-atstart=no``. An ``arm`` dump proves startup was not counted,
then instrumentation is stopped and started again so the simulated caches
are flushed before the cold compile.
"""

from __future__ import annotations

import ctypes
import sys


class _Buf:
    def __init__(self) -> None:
        self.parts: list[str] = []

    def write(self, text: str) -> int:
        self.parts.append(text)
        return len(text)

    def flush(self) -> None:
        return None


def _args(argv: list[str]) -> tuple[str, str, str, bool]:
    marker = program = status = None
    cold_only = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--cold-only":
            cold_only = True
        elif arg in ("--marker", "--program", "--status"):
            i += 1
            if i >= len(argv):
                raise SystemExit(f"missing value for {arg}")
            if arg == "--marker":
                marker = argv[i]
            elif arg == "--program":
                program = argv[i]
            else:
                status = argv[i]
        else:
            raise SystemExit(f"unknown argument {arg}")
        i += 1
    if not marker or not program or not status:
        raise SystemExit("need --marker, --program, and --status")
    return marker, program, status, cold_only


def _write_status(path: str, payload: dict) -> None:
    import json

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)


def main(argv: list[str] | None = None) -> int:
    marker, program, status_path, cold_only = _args(list(sys.argv[1:] if argv is None else argv))
    lib = ctypes.CDLL(marker)
    lib.baseline_start.argtypes = []
    lib.baseline_stop.argtypes = []
    lib.baseline_dump.argtypes = [ctypes.c_char_p]

    with open(program, encoding="utf-8") as fh:
        source = fh.read()
    status: dict = {"status": "ok", "stdout": "", "exception": None, "message": None}

    def dump(label: str) -> None:
        lib.baseline_dump(label.encode())

    # Startup ran with instrumentation off. ``arm`` is the residue of
    # turning it on. Stopping and starting flushes the simulated caches
    # so the cold compile begins from an empty cache.
    lib.baseline_start()
    dump("arm")
    lib.baseline_stop()
    lib.baseline_start()

    try:
        code = compile(source, program, "exec")
    except SyntaxError as exc:
        dump("compile_cold")
        lib.baseline_stop()
        status["status"] = "compile_error"
        status["exception"] = "SyntaxError"
        status["message"] = f"{exc.msg} (line {exc.lineno})"
        _write_status(status_path, status)
        return 0
    dump("compile_cold")
    if not cold_only:
        compile(source, program, "exec")
        dump("compile_warm")

    def run_once() -> None:
        namespace = {"__name__": "__main__", "__file__": program}
        buf = _Buf()
        saved = sys.stdout
        sys.stdout = buf
        try:
            exec(code, namespace)
        finally:
            sys.stdout = saved
            status["stdout"] = "".join(buf.parts)

    try:
        run_once()
    except BaseException as exc:  # noqa: BLE001 - the profile is the result
        dump("run_cold")
        lib.baseline_stop()
        status["status"] = "runtime_error"
        status["exception"] = type(exc).__name__
        status["message"] = str(exc)
        _write_status(status_path, status)
        return 0
    dump("run_cold")
    if not cold_only:
        try:
            run_once()
        except BaseException as exc:  # noqa: BLE001
            dump("run_warm")
            lib.baseline_stop()
            status["status"] = "runtime_error"
            status["exception"] = type(exc).__name__
            status["message"] = str(exc)
            status["warm_failed"] = True
            _write_status(status_path, status)
            return 0
        dump("run_warm")
    lib.baseline_stop()
    _write_status(status_path, status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
