#!/usr/bin/env python3.14
"""Run a Python file on stock CPython and measure compile / run cost.

This is the "standard 3.14 environment" half of ``pycore_cli.py exec``. It
runs in its own interpreter (the CLI launches it as a subprocess) so the
program sees a clean ``__main__`` namespace and nothing from the PyCore
tooling is imported.

For both phases -- ``compile(source, filename, "exec")`` and ``exec(code)``
-- it records wall time and, where the kernel exposes them, hardware CPU
cycles and retired machine instructions through ``perf_event_open``. When
hardware counters are not available (macOS, most VMs and containers) the
cycle figure is estimated from wall time and the nominal clock, and the
report says so.

It also counts CPython bytecode instructions executed by the program with
``sys.monitoring`` (a second, separate run, so the tracing overhead never
lands in the timings), which is the closest like-for-like number to the
instructions PyCore issues.

Output: one JSON object on the ``--json`` path (or stdout).
"""

from __future__ import annotations

import argparse
import ctypes
import dis
import io
import json
import os
import platform
import struct
import sys
import time
import traceback
import types

# ---------------------------------------------------------------------------
# Hardware counters (Linux perf_event_open, user space only)
# ---------------------------------------------------------------------------

_PERF_SYSCALL = {"x86_64": 298, "amd64": 298, "aarch64": 241, "arm64": 241}
_PERF_TYPE_HARDWARE = 0
_PERF_COUNT_HW_CPU_CYCLES = 0
_PERF_COUNT_HW_INSTRUCTIONS = 1
_PERF_EVENT_IOC_ENABLE = 0x2400
_PERF_EVENT_IOC_DISABLE = 0x2401
_PERF_EVENT_IOC_RESET = 0x2403


class _PerfCounter:
    """One user-space hardware counter on the calling thread, or unusable."""

    def __init__(self, config: int) -> None:
        self.fd = -1
        if sys.platform != "linux":
            return
        nr = _PERF_SYSCALL.get(platform.machine().lower())
        if nr is None:
            return
        try:
            libc = ctypes.CDLL(None, use_errno=True)
        except OSError:
            return
        attr = bytearray(128)
        struct.pack_into("IIQ", attr, 0, _PERF_TYPE_HARDWARE, len(attr), config)
        # disabled | exclude_kernel | exclude_hv
        struct.pack_into("Q", attr, 40, (1 << 0) | (1 << 5) | (1 << 6))
        buf = (ctypes.c_char * len(attr)).from_buffer(attr)
        fd = libc.syscall(nr, buf, 0, -1, -1, 0)
        if fd < 0:
            return
        self.fd = fd
        self._ioctl = libc.ioctl

    @property
    def ok(self) -> bool:
        return self.fd >= 0

    def start(self) -> None:
        self._ioctl(self.fd, _PERF_EVENT_IOC_RESET, 0)
        self._ioctl(self.fd, _PERF_EVENT_IOC_ENABLE, 0)

    def stop(self) -> int:
        self._ioctl(self.fd, _PERF_EVENT_IOC_DISABLE, 0)
        return struct.unpack("q", os.read(self.fd, 8))[0]


def _nominal_hz() -> float | None:
    """Best-effort nominal CPU clock, for estimating cycles from wall time."""
    env = os.environ.get("PYCORE_HOST_GHZ")
    if env:
        try:
            return float(env) * 1e9
        except ValueError:
            pass
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as fh:
            for line in fh:
                if line.lower().startswith("cpu mhz"):
                    return float(line.split(":", 1)[1]) * 1e6
    except OSError:
        pass
    if sys.platform == "darwin":
        import subprocess

        for key in ("hw.cpufrequency", "hw.tbfrequency"):
            try:
                out = subprocess.run(
                    ["sysctl", "-n", key], capture_output=True, text=True, check=True
                ).stdout.strip()
                hz = float(out)
                if key == "hw.cpufrequency" and hz > 0:
                    return hz
            except (OSError, ValueError, subprocess.CalledProcessError):
                continue
    return None


def _cpu_name() -> str:
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as fh:
            for line in fh:
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


class _Meter:
    """Measure a callable: wall ns plus hardware cycles/instructions if any."""

    def __init__(self) -> None:
        self.cycles = _PerfCounter(_PERF_COUNT_HW_CPU_CYCLES)
        self.instrs = _PerfCounter(_PERF_COUNT_HW_INSTRUCTIONS)

    @property
    def hardware(self) -> bool:
        return self.cycles.ok

    def measure(self, fn):
        if self.cycles.ok:
            self.cycles.start()
        if self.instrs.ok:
            self.instrs.start()
        t0 = time.perf_counter_ns()
        try:
            value = fn()
        finally:
            t1 = time.perf_counter_ns()
            cyc = self.cycles.stop() if self.cycles.ok else None
            ins = self.instrs.stop() if self.instrs.ok else None
        return value, {"ns": t1 - t0, "cycles": cyc, "machine_instrs": ins}


def _best(samples: list[dict]) -> dict:
    """Pick the fastest sample (least perturbed by the host)."""
    return min(samples, key=lambda s: s["cycles"] if s["cycles"] is not None else s["ns"])


# ---------------------------------------------------------------------------
# Bytecode statistics
# ---------------------------------------------------------------------------


def _iter_code(co: types.CodeType):
    yield co
    for const in co.co_consts:
        if isinstance(const, types.CodeType):
            yield from _iter_code(const)


def _code_stats(code: types.CodeType) -> dict:
    n_code = 0
    n_units = 0
    n_instrs = 0
    for co in _iter_code(code):
        n_code += 1
        n_units += len(co.co_code) // 2
        n_instrs += sum(1 for _ in dis.get_instructions(co))
    return {
        "code_objects": n_code,
        # Code units include inline CACHE entries; instructions do not.
        "code_units": n_units,
        "instructions": n_instrs,
    }


def _count_bytecodes(code: types.CodeType, filename: str) -> int | None:
    """Bytecode instructions executed under ``exec`` (sys.monitoring)."""
    mon = getattr(sys, "monitoring", None)
    if mon is None:
        return None
    tool = None
    for cand in range(mon.DEBUGGER_ID, mon.OPTIMIZER_ID + 1):
        if mon.get_tool(cand) is None:
            tool = cand
            break
    if tool is None:
        return None
    count = 0

    def on_instr(_code, _offset):
        nonlocal count
        count += 1

    ns = {"__name__": "__main__", "__file__": filename}
    saved = sys.stdout
    mon.use_tool_id(tool, "pycore-host-reference")
    mon.register_callback(tool, mon.events.INSTRUCTION, on_instr)
    try:
        sys.stdout = io.StringIO()
        mon.set_events(tool, mon.events.INSTRUCTION)
        try:
            exec(code, ns)
        except BaseException:  # noqa: BLE001 - the timed run already reported it
            pass
        finally:
            mon.set_events(tool, 0)
    finally:
        sys.stdout = saved
        mon.register_callback(tool, mon.events.INSTRUCTION, None)
        mon.free_tool_id(tool)
    return count


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def run_reference(
    source: str, filename: str, *, compile_reps: int = 20, run_reps: int = 5
) -> dict:
    meter = _Meter()
    out: dict = {
        "python": platform.python_version(),
        "implementation": platform.python_implementation(),
        "cpu": _cpu_name(),
        "hardware_counters": meter.hardware,
        "nominal_hz": _nominal_hz(),
    }

    # --- compile -----------------------------------------------------------
    samples = []
    code = None
    try:
        code, first = meter.measure(lambda: compile(source, filename, "exec"))
        samples.append(first)
        for _ in range(compile_reps - 1):
            _, s = meter.measure(lambda: compile(source, filename, "exec"))
            samples.append(s)
    except SyntaxError as exc:
        out["status"] = "compile_error"
        out["exception"] = "SyntaxError"
        out["message"] = f"{exc.msg} (line {exc.lineno})"
        out["stdout"] = ""
        return out
    out["compile"] = {"first": samples[0], "best": _best(samples), "reps": len(samples)}
    out["code"] = _code_stats(code)

    # --- run (timed, stdout captured) -----------------------------------------
    ns = {"__name__": "__main__", "__file__": filename}
    buf = io.StringIO()
    saved = sys.stdout
    exc_info = None
    sys.stdout = buf
    try:
        _, run_m = meter.measure(lambda: exec(code, ns))
    except BaseException as exc:  # noqa: BLE001 - report, don't crash
        run_m = None
        exc_info = exc
    finally:
        sys.stdout = saved
    out["stdout"] = buf.getvalue()
    if exc_info is not None:
        out["status"] = "runtime_error"
        out["exception"] = type(exc_info).__name__
        out["message"] = str(exc_info)
        out["traceback"] = "".join(
            traceback.format_exception(type(exc_info), exc_info, exc_info.__traceback__)
        )
    else:
        out["status"] = "ok"
        # Re-run in fresh namespaces (output discarded) for a warm figure;
        # the first run above is the cold one PyCore is compared against.
        samples = [run_m]
        budget = time.perf_counter_ns() + 500_000_000
        while len(samples) < run_reps and time.perf_counter_ns() < budget:
            sys.stdout = io.StringIO()
            try:
                _, s = meter.measure(
                    lambda: exec(code, {"__name__": "__main__", "__file__": filename})
                )
                samples.append(s)
            except BaseException:  # noqa: BLE001 - non-idempotent program
                break
            finally:
                sys.stdout = saved
        out["run"] = {"first": run_m, "best": _best(samples), "reps": len(samples)}

    out["bytecodes_executed"] = _count_bytecodes(code, filename)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", help="Python file to run")
    parser.add_argument("--filename", help="Name to compile under (default: path)")
    parser.add_argument("--json", help="Write the JSON result here (default stdout)")
    parser.add_argument("--compile-reps", type=int, default=20)
    args = parser.parse_args(argv)

    with open(args.source, encoding="utf-8") as fh:
        source = fh.read()
    result = run_reference(
        source, args.filename or args.source, compile_reps=max(1, args.compile_reps)
    )
    text = json.dumps(result, indent=2)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
