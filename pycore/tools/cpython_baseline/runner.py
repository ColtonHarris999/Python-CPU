"""Run one program under Callgrind and split compile / dispatch / execution.

Cold compile and the first ``exec`` are what PyCore's report compares
against (the device runs each phase once, from a reset). Warm compile and
a second ``exec`` of the same code object are the steady state pyperf
keeps: the second execution is where PEP 659 specialization has rewritten
hot instructions. The garbage collector stays on. ``PYTHONHASHSEED`` is
pinned because a single simulated run cannot average hash randomization
the way a 20-process pyperformance job does.
"""

from __future__ import annotations

import dis
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import types
from pathlib import Path

from cpython_baseline.callgrind import load_dumps
from cpython_baseline.cycle_model import add_events, phase_view, sub_events
from cpython_baseline.dispatch import eval_frame_symbol, find_libpython, libpython_dispatch
from cpython_baseline.machine import Machine

_HARNESS = Path(__file__).resolve().parent / "harness.py"
_MARKER_SRC = Path(__file__).resolve().parent / "marker.c"
_EVAL = "_PyEval_EvalFrameDefault"


def ensure_marker(build_dir: Path) -> Path:
    build_dir.mkdir(parents=True, exist_ok=True)
    out = build_dir / "libbaseline_marker.so"
    if out.exists() and out.stat().st_mtime >= _MARKER_SRC.stat().st_mtime:
        return out
    gcc = shutil.which("gcc")
    if gcc is None:
        raise RuntimeError("gcc is required to build the Callgrind marker library")
    subprocess.run(
        [gcc, "-shared", "-fPIC", "-O2", "-o", str(out), str(_MARKER_SRC)],
        check=True,
    )
    return out


def _iter_code(code: types.CodeType):
    yield code
    for const in code.co_consts:
        if isinstance(const, types.CodeType):
            yield from _iter_code(const)


def code_stats(code: types.CodeType) -> dict:
    objects = units = instrs = 0
    for co in _iter_code(code):
        objects += 1
        units += len(co.co_code) // 2
        instrs += sum(1 for _ in dis.get_instructions(co))
    return {"code_objects": objects, "code_units": units, "instructions": instrs}


def count_bytecodes(code: types.CodeType, filename: str) -> int | None:
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

    namespace = {"__name__": "__main__", "__file__": filename}
    saved = sys.stdout
    mon.use_tool_id(tool, "cpython-baseline")
    mon.register_callback(tool, mon.events.INSTRUCTION, on_instr)
    try:
        sys.stdout = io.StringIO()
        mon.set_events(tool, mon.events.INSTRUCTION)
        try:
            exec(code, namespace)
        except BaseException:  # noqa: BLE001 - count whatever ran
            pass
        finally:
            mon.set_events(tool, 0)
    finally:
        sys.stdout = saved
        mon.register_callback(tool, mon.events.INSTRUCTION, None)
        mon.free_tool_id(tool)
    return count


def preflight(source: str, filename: str) -> dict:
    """Native compile and exec, so the simulated run is not the first to fail."""
    try:
        code = compile(source, filename, "exec")
    except SyntaxError as exc:
        return {
            "status": "compile_error",
            "exception": "SyntaxError",
            "message": f"{exc.msg} (line {exc.lineno})",
            "stdout": "",
            "code": None,
            "bytecodes_executed": None,
        }
    stats = code_stats(code)
    namespace = {"__name__": "__main__", "__file__": filename}
    buf = io.StringIO()
    saved = sys.stdout
    sys.stdout = buf
    try:
        exec(code, namespace)
    except BaseException as exc:  # noqa: BLE001
        sys.stdout = saved
        return {
            "status": "runtime_error",
            "exception": type(exc).__name__,
            "message": str(exc),
            "stdout": buf.getvalue(),
            "code": stats,
            "bytecodes_executed": count_bytecodes(compile(source, filename, "exec"), filename),
        }
    finally:
        sys.stdout = saved
    return {
        "status": "ok",
        "exception": None,
        "message": None,
        "stdout": buf.getvalue(),
        "code": stats,
        "bytecodes_executed": count_bytecodes(compile(source, filename, "exec"), filename),
    }


def _check_geometry(machine: Machine, caches: dict[str, tuple[int, int, int]]) -> None:
    expected = {
        "I1": (machine.l1i.size_bytes, machine.l1i.line_bytes, machine.l1i.associativity),
        "D1": (machine.l1d.size_bytes, machine.l1d.line_bytes, machine.l1d.associativity),
        "LL": (machine.llc.size_bytes, machine.llc.line_bytes, machine.llc.associativity),
    }
    for name, want in expected.items():
        got = caches.get(name)
        if got != want:
            raise RuntimeError(
                f"Callgrind simulated {name} as {got}, not {want}. "
                "The tool prints a host-cache warning and then applies "
                "--I1/--D1/--LL; the dump header is what was actually used."
            )


def _sum_addrs(profile, addresses: set[int]) -> dict[str, int]:
    parts = [profile.addrs[addr] for addr in addresses if addr in profile.addrs]
    return add_events(parts) if parts else add_events([])


def _top_functions(profile, limit: int = 8) -> list[dict]:
    ranked = sorted(profile.functions.items(), key=lambda item: -item[1]["Ir"])
    out = []
    for name, events in ranked[:limit]:
        if events["Ir"] <= 0:
            continue
        out.append({"function": name, "instructions": events["Ir"]})
    return out


def _jit_state() -> dict:
    jit = getattr(sys, "_jit", None)
    if jit is None:
        return {"available": False, "enabled": False}
    return {
        "available": bool(getattr(jit, "is_available", lambda: False)()),
        "enabled": bool(getattr(jit, "is_enabled", lambda: False)()),
    }


def python_identity() -> dict:
    return {
        "version": platform.python_version(),
        "implementation": platform.python_implementation(),
        "executable": sys.executable,
        "jit": _jit_state(),
        "hash_seed": os.environ.get("PYTHONHASHSEED"),
        "gc": "on",
    }


def measure(
    program: Path,
    machine: Machine,
    work: Path,
    *,
    cold_only: bool = False,
    python: str | None = None,
) -> dict:
    """Simulate ``program`` on ``machine`` and return the baseline record."""
    program = program.resolve()
    source = program.read_text(encoding="utf-8")
    native = preflight(source, str(program))
    notes: list[str] = []
    if native["status"] == "compile_error":
        return {
            "program": str(program),
            "status": "compile_error",
            "message": native["message"],
            "notes": notes,
        }

    valgrind = shutil.which("valgrind")
    if valgrind is None:
        raise RuntimeError("valgrind is not installed (needed for the cache and branch simulation)")
    objdump = shutil.which("objdump")
    readelf = shutil.which("readelf")
    if objdump is None or readelf is None:
        raise RuntimeError("binutils (objdump and readelf) are required to locate the dispatch edge")

    libpython = find_libpython()
    entry_addr, _entry_size = eval_frame_symbol(libpython)
    addresses, sites = libpython_dispatch(libpython)
    if sites < 1:
        notes.append("no jump-table dispatch sites found; interpret falls back to the whole eval frame")

    work.mkdir(parents=True, exist_ok=True)
    marker = ensure_marker(work)
    dump_dir = Path(tempfile.mkdtemp(prefix="cg-", dir=work))
    prefix = "callgrind.out"
    status_path = dump_dir / "status.json"
    log_path = dump_dir / "valgrind.log"
    cmd = [
        valgrind,
        "--tool=callgrind",
        "--cache-sim=yes",
        "--branch-sim=yes",
        "--instr-atstart=no",
        "--dump-instr=yes",
        f"--I1={machine.l1i.callgrind()}",
        f"--D1={machine.l1d.callgrind()}",
        f"--LL={machine.llc.callgrind()}",
        f"--callgrind-out-file={dump_dir / prefix}",
        f"--log-file={log_path}",
        python or sys.executable,
        str(_HARNESS),
        "--marker",
        str(marker),
        "--program",
        str(program),
        "--status",
        str(status_path),
    ]
    if cold_only:
        cmd.append("--cold-only")
    env = os.environ.copy()
    env["PYTHONHASHSEED"] = "0"
    env["PYTHON_JIT"] = "0"
    started = time.perf_counter()
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=600)
    elapsed = time.perf_counter() - started
    if not status_path.is_file():
        log_tail = log_path.read_text(encoding="utf-8", errors="replace")[-2000:] if log_path.is_file() else ""
        raise RuntimeError(
            f"callgrind produced no status (exit {proc.returncode}).\n{log_tail}\n{proc.stderr[-1000:]}"
        )
    simulated = json.loads(status_path.read_text(encoding="utf-8"))
    profiles = load_dumps(
        dump_dir, prefix, keep_addrs=addresses, keep_fn=_EVAL, entry_addr=entry_addr
    )
    if "compile_cold" not in profiles or "run_cold" not in profiles:
        have = ", ".join(sorted(profiles)) or "(none)"
        raise RuntimeError(f"missing phase dumps (have {have})")
    _check_geometry(machine, profiles["compile_cold"].caches)

    arm = profiles.get("arm")
    if arm is not None and arm.summary["Ir"] > 100_000:
        notes.append(
            f"instrumentation arm counted {arm.summary['Ir']} instructions; "
            "startup may have leaked into the measurement"
        )

    penalties = machine.penalties
    mhz = machine.frequency_mhz

    def view(events: dict[str, int]) -> dict:
        return phase_view(events, penalties, mhz)

    phases = {
        "compile_cold": view(profiles["compile_cold"].summary),
    }
    if "compile_warm" in profiles:
        phases["compile_warm"] = view(profiles["compile_warm"].summary)
    phases["run_cold"] = view(profiles["run_cold"].summary)
    if "run_warm" in profiles:
        phases["run_warm"] = view(profiles["run_warm"].summary)

    run_profile = profiles["run_cold"]
    dispatch_events = _sum_addrs(run_profile, addresses)
    eval_events = run_profile.functions.get(_EVAL, add_events([]))
    method = "jump_table_edge"
    if sites < 1 or dispatch_events["Ir"] == 0:
        method = "eval_frame_exclusive"
        dispatch_events = dict(eval_events)
        notes.append(
            "interpret is the exclusive cost of _PyEval_EvalFrameDefault "
            "(dispatch plus inline opcode bodies); the jump-table edge was not separated"
        )
    inline_events, inline_neg = sub_events(eval_events, dispatch_events)
    helper_events, helper_neg = sub_events(run_profile.summary, eval_events)
    run_events, run_neg = sub_events(run_profile.summary, dispatch_events)
    for label, neg in (
        ("inline", inline_neg),
        ("helpers", helper_neg),
        ("run", run_neg),
    ):
        if neg:
            notes.append(f"{label} event subtraction clamped negative {', '.join(neg)}")

    phases["interpret"] = view(dispatch_events)
    phases["run"] = view(run_events)
    breakdown = {
        "dispatch": view(dispatch_events),
        "inline_opcodes": view(inline_events),
        "c_helpers": view(helper_events),
    }

    bytecodes = native["bytecodes_executed"]
    per_bc = None
    if bytecodes:
        per_bc = {
            "dispatch": phases["interpret"]["cycles"] / bytecodes,
            "exec": phases["run_cold"]["cycles"] / bytecodes,
            "inline_and_helpers": phases["run"]["cycles"] / bytecodes,
        }

    if simulated.get("stdout") != native["stdout"]:
        notes.append("stdout under Callgrind differed from the native preflight")

    record = {
        "schema_version": 1,
        "program": str(program),
        "status": simulated.get("status", native["status"]),
        "exception": simulated.get("exception"),
        "message": simulated.get("message"),
        "stdout": simulated.get("stdout", ""),
        "bytecodes_executed": bytecodes,
        "code": native["code"],
        "cycles_per_bytecode": per_bc,
        "dispatch": {
            "method": method,
            "sites": sites,
            "function": _EVAL,
            "libpython": str(libpython),
        },
        "phases": phases,
        "run_cold_breakdown": breakdown,
        "top_functions": {
            "compile_cold": _top_functions(profiles["compile_cold"]),
            "run_cold": _top_functions(run_profile),
        },
        "instrumentation_arm_instructions": None if arm is None else arm.summary["Ir"],
        "callgrind": profiles["compile_cold"].creator,
        "sim_seconds": elapsed,
        "notes": notes,
        "compare_to_pycore": ["compile_cold", "interpret", "run"],
    }
    # Drop the bulky dumps once the record is built. A failed run leaves them.
    shutil.rmtree(dump_dir, ignore_errors=True)
    return record
