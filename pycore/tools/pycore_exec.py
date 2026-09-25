#!/usr/bin/env python3.14
"""Compile and run a Python file *on* PyCore, then compare with CPython 3.14.

``pycore_cli.py exec FILE`` and the interactive ``pycore_cli.py shell`` both
land here. Unlike ``run`` (host CPython compiles, the hart only executes),
this path hands PyCore the **source text**: a small boot harness calls the
resident on-device ``compile()`` and then ``exec()`` on the result, in a
fresh ``{"__name__": "__main__"}`` namespace. Whatever the program prints
streams to the terminal as the simulation produces it.

The harness brackets each phase with a PHASE_MARK console byte (see
``pycore/tb/tb_container.sv``); the testbench stamps each mark with the
cycle count and perf counters, so the report can split the run into boot,
compile and run. The same file is run on stock CPython 3.14 in a separate
interpreter (``host_reference.py``) for the golden output and for the
compile / run cost comparison.
"""

from __future__ import annotations

import codecs
import dataclasses
import json
import os
import pathlib
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ENSURE_SIM = REPO_ROOT / "tools" / "ensure_sim.py"
SIM_TWOCORE_BIN = REPO_ROOT / "build" / "sim_img_twocore" / "Vtb_container"
EXCORE_FW_HEX = REPO_ROOT / "build" / "excore_fw" / "list_grow.hex"
HOST_REFERENCE = pathlib.Path(__file__).resolve().parent / "host_reference.py"
DEFS_SVH = REPO_ROOT / "pycore" / "rtl" / "pycore_defs.svh"

DEFAULT_MAX_CYCLES = 200_000_000
DEFAULT_HEARTBEAT = 250_000
DEFAULT_PYCORE_MHZ = 100.0
DEFAULT_BUILD_DIR = "build/pycore_exec"

# Console bytes the harness writes as phase marks (tb PHASE_MARKS=1 swallows
# 0x01..0x07) and the SO/SI pair that frames harness metadata in stdout.
MARK_ENTRY, MARK_CALIBRATE, MARK_COMPILED, MARK_RAN = 1, 2, 3, 4
META_OPEN, META_CLOSE = "\x0e", "\x0f"

# Seeded exception classes, most specific first, for the harness's except
# clauses (isinstance() on an exception instance is not supported, but
# CHECK_EXC_MATCH walks the MRO).
EXCEPTION_ORDER = (
    "SyntaxError",
    "ZeroDivisionError",
    "ArithmeticError",
    "IndexError",
    "KeyError",
    "LookupError",
    "UnboundLocalError",
    "NameError",
    "TypeError",
    "ValueError",
    "AttributeError",
    "RuntimeError",
    "AssertionError",
    "StopIteration",
    "Exception",
)

# What a user most likely hit when a phase ends in a hardware trap.
TRAP_HINTS = {
    "TYPE": (
        "an operation on a type the hart does not support yet -- e.g. print() "
        "of a str longer than 15 bytes, a float, or a container; str * int; "
        "comparing mixed types"
    ),
    "DIV_ZERO": "division by zero (a hardware trap, not a catchable ZeroDivisionError yet)",
    "MEM_FAULT": (
        "a missing dict key, out-of-range or negative index, unbound name, "
        "recursion too deep, or heap exhausted"
    ),
    "CALL_FILTER": "a call shape the callee does not accept (e.g. keywords to a native builtin)",
    "ILLEGAL_OPCODE": "an opcode the hart does not implement",
    "ATTR_ERROR": "a missing attribute",
    "RAISE": "an exception that escaped every handler",
    "SLICE": "an unsupported slice (list/tuple slicing, or a step)",
}


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------


def _except_clauses(phase: str, ret: str | None) -> str:
    out = []
    for name in EXCEPTION_ORDER:
        out.append(f"    except {name} as e:\n")
        out.append(f"        _report_exc({phase!r}, {name!r}, e)\n")
        if ret is not None:
            out.append(f"        return {ret}\n")
    return "".join(out)


def build_harness(source_text: str, filename: str) -> str:
    """Boot module that compiles ``source_text`` on device, then runs it.

    Two ``try`` blocks live in separate functions: CPython emits
    ``JUMP_BACKWARD_NO_INTERRUPT`` for two in one function (D13).
    """
    return f'''\
"""pycore_exec harness: on-device compile() + exec() of a user file."""

SRC = {source_text!r}
FILENAME = {filename!r}


def _emit(v):
    k = _bi_code_kind(v)
    if k == 7 or k == 8:
        for c in v:
            _bi_print(c)
    elif k == 0 or k == 1 or k == 4:
        _bi_print(v)
    else:
        _bi_print("?")


def _report_exc(phase, name, e):
    _bi_print("\\x0e")
    _bi_print("exc:")
    _emit(phase)
    _bi_print(":")
    _emit(name)
    _bi_print(":")
    if len(e.args) > 0:
        _emit(e.args[0])
    _bi_print("\\x0f")


def _compile_phase():
    try:
        return compile(SRC, FILENAME, "exec")
{_except_clauses("compile", None)}    return None


def _run_phase(code):
    ns = {{"__name__": "__main__"}}
    try:
        exec(code, ns)
{_except_clauses("run", "1")}    return 0


def managed_entry():
    _bi_print("\\x01")
    _bi_print("\\x02")
    hm = _bi_heap_mark()
    cm = _bi_code_mark()
    code = _compile_phase()
    _bi_print("\\x03")
    hc = _bi_heap_mark()
    cc = _bi_code_mark()
    status = 2
    if code is not None:
        status = _run_phase(code)
    _bi_print("\\x04")
    hr = _bi_heap_mark()
    _bi_print("\\x0e")
    _bi_print("stats:")
    _bi_print(status)
    _bi_print(":")
    _bi_print(hc - hm)
    _bi_print(":")
    _bi_print(cc - cm)
    _bi_print(":")
    _bi_print(hr - hc)
    _bi_print("\\x0f")
    return 0


managed_entry()
'''


def prepare_source(path: pathlib.Path) -> tuple[str, list[str]]:
    """Source text both sides run, plus notes about any rewrite."""
    from pycore_cli import ensure_entry_call  # noqa: PLC0415 - avoid import cycle

    text = path.read_text(encoding="utf-8")
    notes = []
    prepared = ensure_entry_call(text, "managed_entry")
    if prepared != text:
        notes.append("appended a module-level managed_entry() call (it was defined but never called)")
    return prepared, notes


# ---------------------------------------------------------------------------
# Image + simulator
# ---------------------------------------------------------------------------


def _parse_meta(path: pathlib.Path) -> dict[str, str]:
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def build_device_image(harness_text: str, work: pathlib.Path) -> dict[str, str]:
    from image_from_source import (  # noqa: PLC0415 - heavy, CLI-only
        build_image_from_source_text,
        write_image_outputs,
    )

    work.mkdir(parents=True, exist_ok=True)
    harness_path = work / "harness.py"
    harness_path.write_text(harness_text, encoding="utf-8")
    image = build_image_from_source_text(harness_text, str(harness_path))
    write_image_outputs(
        image,
        program_hex=work / "program.hex",
        dmem_hex=work / "dmem.hex",
        meta=work / "image.meta",
        expected_tag=1,
        expected_value=0,
    )
    return _parse_meta(work / "image.meta")


def ensure_simulator(*, quiet: bool = False) -> pathlib.Path:
    """Build (once) the shared two-core tb_container, like ``run`` does."""
    python = os.environ.get("PYTHON", sys.executable)
    proc = subprocess.run(
        [python, str(ENSURE_SIM), "twocore"],
        cwd=REPO_ROOT,
        check=False,
        capture_output=quiet,
        text=True,
    )
    if proc.returncode != 0 or not SIM_TWOCORE_BIN.is_file():
        detail = (proc.stdout or "")[-2000:] + (proc.stderr or "")[-2000:] if quiet else ""
        raise RuntimeError(
            f"could not build the two-core simulator (tools/ensure_sim.py twocore "
            f"exit {proc.returncode}). Is Verilator >= 5.032 installed?\n{detail}"
        )
    return SIM_TWOCORE_BIN


def trap_names() -> dict[int, str]:
    names = {}
    try:
        text = DEFS_SVH.read_text(encoding="utf-8")
    except OSError:
        return names
    for m in re.finditer(r"PY_TRAP_([A-Z0-9_]+)\s*=\s*5'd(\d+);", text):
        names.setdefault(int(m.group(2)), m.group(1))
    return names


def hardware_limits(meta: dict[str, str]) -> dict[str, int]:
    """Free code RAM and heap left for a compiled program at boot."""
    text = DEFS_SVH.read_text(encoding="utf-8")

    def lp(name: str) -> int:
        m = re.search(rf"\b{name}\s*=\s*32'h([0-9A-Fa-f_]+);", text)
        return int(m.group(1).replace("_", ""), 16) if m else 0

    ram_limit = lp("PYCORE_CODE_RAM_SLOT_BASE") + lp("PYCORE_CODE_RAM_SLOTS")
    heap_limit = lp("PYCORE_HEAP_LIMIT")
    return {
        "code_ram_free_slots": ram_limit - int(meta.get("CODE_RAM_INIT_SLOT", "0")),
        "heap_free_bytes": heap_limit - int(meta.get("HEAP_INIT_PTR", "0")),
    }


_MARK_RE = re.compile(
    r"PHASE_MARK id=(\d+) cycle=(\d+) instr=(\d+) excore_traps=(\d+) "
    r"excore_wait=(\d+) l1i_hit=(\d+) l1i_miss=(\d+) l1d_hit=(\d+) l1d_miss=(\d+)"
)
_MARK_KEYS = (
    "cycle", "instr", "excore_traps", "excore_wait",
    "l1i_hit", "l1i_miss", "l1d_hit", "l1d_miss",
)
_HEARTBEAT_RE = re.compile(r"HEARTBEAT cycle=(\d+) instr=(\d+)")
_TRAP_RE = re.compile(r"program trapped \(code=(\d+)\) at cycle (\d+)")
_TIMEOUT_RE = re.compile(r"still running at MAX_CYCLES=(\d+)")
_PASS_RE = re.compile(r"^PASS: .* cycles=(\d+)", re.M)
_PERF_RE = re.compile(r"^PERF instr=(\d+) excore_traps=(\d+) excore_wait=(\d+)", re.M)


class _Console:
    """Program output and a one-line progress indicator on one terminal."""

    def __init__(self, stream, *, progress: bool) -> None:
        self.stream = stream
        self.progress = progress and sys.stderr.isatty()
        self.lock = threading.Lock()
        self._shown = False
        self._at_line_start = True
        self.wrote_output = False

    def _clear(self) -> None:
        if self._shown:
            sys.stderr.write("\r\x1b[2K")
            sys.stderr.flush()
            self._shown = False

    def status(self, text: str) -> None:
        if not self.progress:
            return
        with self.lock:
            if not self._at_line_start:
                return  # never paint over a half-printed program line
            sys.stderr.write("\r\x1b[2K\x1b[2m" + text + "\x1b[0m")
            sys.stderr.flush()
            self._shown = True

    def output(self, text: str) -> None:
        if not text:
            return
        with self.lock:
            self._clear()
            self.stream.write(text)
            self.stream.flush()
            self._at_line_start = text.endswith("\n")
            self.wrote_output = True

    def finish(self) -> None:
        with self.lock:
            self._clear()
            if not self._at_line_start:
                self.stream.write("\n")
                self.stream.flush()
                self._at_line_start = True


def _latin1_fallback(err: UnicodeDecodeError) -> tuple[str, int]:
    # The console sink writes a kind-1 (Latin-1) string one byte per code
    # point, so 'é' arrives as a lone 0xE9. Keep valid UTF-8 as UTF-8.
    return err.object[err.start:err.end].decode("latin-1"), err.end


codecs.register_error("pycore-latin1", _latin1_fallback)


class _StdoutTail(threading.Thread):
    """Follow the tb's console capture, strip harness metadata, echo the rest."""

    def __init__(self, path: pathlib.Path, console: _Console | None) -> None:
        super().__init__(daemon=True)
        self.path = path
        self.console = console
        self.stop_event = threading.Event()
        self.program_out: list[str] = []
        self.meta: list[str] = []
        self._decoder = codecs.getincrementaldecoder("utf-8")("pycore-latin1")
        self._in_meta = False
        self._meta_buf: list[str] = []

    def _feed(self, chunk: bytes, final: bool = False) -> None:
        text = self._decoder.decode(chunk, final=final)
        visible = []
        for ch in text:
            if self._in_meta:
                if ch == META_CLOSE:
                    self.meta.append("".join(self._meta_buf))
                    self._meta_buf = []
                    self._in_meta = False
                else:
                    self._meta_buf.append(ch)
            elif ch == META_OPEN:
                self._in_meta = True
            else:
                visible.append(ch)
        out = "".join(visible)
        if out:
            self.program_out.append(out)
            if self.console is not None:
                self.console.output(out)

    def run(self) -> None:
        fh = None
        try:
            while True:
                stopping = self.stop_event.is_set()
                if fh is None and self.path.exists():
                    fh = open(self.path, "rb")  # noqa: SIM115 - closed below
                if fh is not None:
                    chunk = fh.read()
                    if chunk:
                        self._feed(chunk)
                if stopping:
                    self._feed(b"", final=True)
                    return
                self.stop_event.wait(0.05)
        finally:
            if fh is not None:
                fh.close()


@dataclasses.dataclass
class DeviceResult:
    outcome: str = "unknown"  # ok | exception | compile_error | trap | timeout | sim_error
    marks: dict[int, dict[str, int]] = dataclasses.field(default_factory=dict)
    total_cycles: int | None = None
    total_instr: int | None = None
    trap_code: int | None = None
    trap_name: str | None = None
    trap_cycle: int | None = None
    trap_phase: str | None = None
    exception: dict[str, str] | None = None
    harness_status: int | None = None
    heap_compile: int | None = None
    code_slots: int | None = None
    heap_run: int | None = None
    stdout: str = ""
    wall_s: float = 0.0
    log_path: str = ""


def _phase_at(marks: dict[int, dict[str, int]]) -> str:
    if MARK_RAN in marks:
        return "harness epilogue"
    if MARK_COMPILED in marks:
        return "run"
    if MARK_CALIBRATE in marks:
        return "compile"
    return "boot"


def run_device(
    *,
    work: pathlib.Path,
    meta: dict[str, str],
    max_cycles: int,
    cache_en: int,
    mem_latency: int,
    heartbeat: int,
    console: _Console | None,
) -> DeviceResult:
    sim = ensure_simulator(quiet=True)
    stdout_path = work / "console.txt"
    if stdout_path.exists():
        stdout_path.unlink()
    log_path = work / "sim.log"
    cmd = [
        str(sim),
        f"+PROG_HEX={(work / 'program.hex').resolve()}",
        f"+DMEM_HEX={(work / 'dmem.hex').resolve()}",
        f"+CODE_RAM_HEX={(work / 'code_ram.hex').resolve()}",
        f"+FW_HEX={EXCORE_FW_HEX.resolve()}",
        "+BOOT_EN=1",
        "+CHECK_ENTRY_RETURN=1",
        f"+HEAP_INIT_PTR={meta['HEAP_INIT_PTR']}",
        f"+CODE_RAM_INIT_SLOT={meta['CODE_RAM_INIT_SLOT']}",
        "+EXPECTED_TAG=1",
        "+EXPECTED_VALUE=0",
        f"+MAX_CYCLES={max_cycles}",
        f"+CACHE_EN={cache_en}",
        f"+MEM_LATENCY={mem_latency}",
        f"+STDOUT_PATH={stdout_path.resolve()}",
        "+PHASE_MARKS=1",
        f"+HEARTBEAT={heartbeat}",
    ]
    res = DeviceResult(log_path=str(log_path))
    tail = _StdoutTail(stdout_path, console)
    tail.start()
    t0 = time.monotonic()
    phase_label = {0: "booting", MARK_ENTRY: "booting", MARK_CALIBRATE: "compiling",
                   MARK_COMPILED: "running", MARK_RAN: "finishing"}
    last = 0
    log_lines = []
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
    except OSError as exc:
        tail.stop_event.set()
        tail.join()
        res.outcome = "sim_error"
        res.exception = {"phase": "sim", "name": "OSError", "message": str(exc)}
        return res
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            log_lines.append(line)
            m = _MARK_RE.search(line)
            if m:
                mid = int(m.group(1))
                res.marks[mid] = dict(zip(_MARK_KEYS, map(int, m.groups()[1:])))
                last = mid
                if console is not None:
                    console.status(
                        f"[pycore] {phase_label.get(last, 'running')}... "
                        f"{res.marks[mid]['cycle']:,} cycles"
                    )
                continue
            m = _HEARTBEAT_RE.search(line)
            if m and console is not None:
                cyc = int(m.group(1))
                base = res.marks.get(last, {}).get("cycle", 0)
                console.status(
                    f"[pycore] {phase_label.get(last, 'running')}... "
                    f"{cyc - base:,} cycles in phase, {cyc:,} total "
                    f"({time.monotonic() - t0:.0f}s)"
                )
        proc.wait()
    except KeyboardInterrupt:
        proc.kill()
        proc.wait()
        res.outcome = "interrupted"
    finally:
        if proc.stdout is not None:
            proc.stdout.close()
        tail.stop_event.set()
        tail.join()
        if console is not None:
            console.finish()
    res.wall_s = time.monotonic() - t0
    log = "".join(log_lines)
    log_path.write_text(log, encoding="utf-8")

    res.stdout = "".join(tail.program_out)
    for item in tail.meta:
        kind, _, rest = item.partition(":")
        if kind == "exc":
            phase, _, rest = rest.partition(":")
            name, _, msg = rest.partition(":")
            res.exception = {"phase": phase, "name": name, "message": msg}
        elif kind == "stats":
            parts = rest.split(":")
            try:
                res.harness_status = int(parts[0])
                res.heap_compile = int(parts[1])
                res.code_slots = int(parts[2])
                res.heap_run = int(parts[3])
            except (IndexError, ValueError):
                pass

    if m := _PASS_RE.search(log):
        res.total_cycles = int(m.group(1))
    if m := _PERF_RE.search(log):
        res.total_instr = int(m.group(1))
    if res.outcome == "interrupted":
        return res
    if m := _TRAP_RE.search(log):
        res.outcome = "trap"
        res.trap_code = int(m.group(1))
        res.trap_cycle = int(m.group(2))
        res.total_cycles = res.trap_cycle
        res.trap_name = trap_names().get(res.trap_code, f"code {res.trap_code}")
        res.trap_phase = _phase_at(res.marks)
    elif m := _TIMEOUT_RE.search(log):
        res.outcome = "timeout"
        res.trap_phase = _phase_at(res.marks)
    elif res.harness_status == 0:
        res.outcome = "ok"
    elif res.harness_status == 1:
        res.outcome = "exception"
    elif res.harness_status == 2:
        res.outcome = "compile_error"
    else:
        res.outcome = "sim_error"
    return res


# ---------------------------------------------------------------------------
# Host reference
# ---------------------------------------------------------------------------


def run_host(prepared: pathlib.Path, filename: str, work: pathlib.Path, python: str) -> dict:
    out_json = work / "host.json"
    proc = subprocess.run(
        [python, str(HOST_REFERENCE), str(prepared), "--filename", filename,
         "--json", str(out_json)],
        cwd=prepared.parent,
        capture_output=True,
        text=True,
        check=False,
        timeout=600,
    )
    if proc.returncode != 0 or not out_json.is_file():
        return {"status": "tool_error", "message": (proc.stderr or proc.stdout)[-2000:]}
    return json.loads(out_json.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


def _n(v) -> str:
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:,.2f}"
    return f"{v:,}"


def _dur(seconds: float | None) -> str:
    if seconds is None:
        return "-"
    if seconds >= 1:
        return f"{seconds:.2f} s"
    if seconds >= 1e-3:
        return f"{seconds * 1e3:.2f} ms"
    return f"{seconds * 1e6:.1f} us"


def _pct(hit: int, miss: int) -> str:
    total = hit + miss
    return "-" if total == 0 else f"{100.0 * hit / total:.1f}%"


def _delta(marks, a: int, b: int, key: str) -> int | None:
    if a in marks and b in marks:
        return marks[b][key] - marks[a][key]
    return None


def device_phases(dev: DeviceResult) -> dict:
    """Per-phase counters from the marks, marker overhead subtracted."""
    marks = dev.marks
    overhead = _delta(marks, MARK_ENTRY, MARK_CALIBRATE, "cycle") or 0
    overhead_i = _delta(marks, MARK_ENTRY, MARK_CALIBRATE, "instr") or 0

    def phase(a: int, b: int) -> dict | None:
        cyc = _delta(marks, a, b, "cycle")
        if cyc is None:
            return None
        out = {k: _delta(marks, a, b, k) for k in _MARK_KEYS}
        out["cycle"] = max(0, cyc - overhead)
        out["instr"] = max(0, out["instr"] - overhead_i)
        return out

    phases = {
        "boot_cycles": marks.get(MARK_ENTRY, {}).get("cycle"),
        "marker_overhead_cycles": overhead,
        "compile": phase(MARK_CALIBRATE, MARK_COMPILED),
        "run": phase(MARK_COMPILED, MARK_RAN),
    }
    # A trap cuts a phase short: charge the cycles up to the trap to it.
    if dev.outcome in ("trap", "timeout") and dev.total_cycles is not None:
        start = {"compile": MARK_CALIBRATE, "run": MARK_COMPILED}.get(dev.trap_phase or "")
        if start in marks:
            phases[dev.trap_phase] = {
                "cycle": dev.total_cycles - marks[start]["cycle"], "partial": True,
            }
    return phases


def _host_cycles(meas: dict | None, hz: float | None) -> tuple[float | None, bool]:
    """(cycles, measured?) for a host measurement."""
    if not meas:
        return None, False
    if meas.get("cycles") is not None:
        return float(meas["cycles"]), True
    if hz:
        return meas["ns"] * hz / 1e9, False
    return None, False


def evaluate(dev: DeviceResult, host: dict | None) -> tuple[str, str]:
    """(verdict, detail) -- verdict is PASS / MISMATCH / UNSUPPORTED / TRAP / ..."""
    if dev.outcome == "interrupted":
        return "INTERRUPTED", "simulation stopped by Ctrl-C"
    if dev.outcome == "trap":
        hint = TRAP_HINTS.get(dev.trap_name or "", "")
        if dev.trap_name == "MEM_FAULT" and dev.trap_phase == "compile":
            hint = (
                "the on-device compiler ran out of heap (it keeps its whole "
                "working set, roughly 5-10 KB per source line); try a shorter file"
            )
        detail = (
            f"hardware trap {dev.trap_name} (code {dev.trap_code}) during {dev.trap_phase} "
            f"at cycle {_n(dev.trap_cycle)}"
        )
        return "TRAP", detail + (f"\n           likely: {hint}" if hint else "")
    if dev.outcome == "timeout":
        return "TIMEOUT", f"still {dev.trap_phase or 'running'} at --max-cycles; raise it and retry"
    if dev.outcome == "sim_error":
        return "SIM ERROR", f"simulator did not finish cleanly; see {dev.log_path}"
    if dev.outcome == "compile_error":
        exc = dev.exception or {}
        host_rejects = host is not None and host.get("status") == "compile_error"
        msg = f"{exc.get('name', 'error')}: {exc.get('message', '')}"
        if host_rejects:
            return "PASS", f"both compilers reject the program ({msg})"
        return "UNSUPPORTED", f"on-device compile() rejected it -- {msg}"
    if host is None:
        tail = f" (raised {dev.exception['name']})" if dev.exception else ""
        return "RAN", "CPython comparison off" + tail
    if host.get("status") == "tool_error":
        return "HOST ERROR", host.get("message", "")
    same_out = dev.stdout == host.get("stdout", "")
    if dev.outcome == "ok" and host.get("status") == "ok":
        if same_out:
            return "PASS", "output matches CPython"
        return "MISMATCH", "output differs from CPython"
    if dev.outcome == "exception" and host.get("status") == "runtime_error":
        dname = (dev.exception or {}).get("name")
        hname = host.get("exception")
        # Device except clauses stop at the first seeded ancestor.
        if same_out and dname == hname:
            return "PASS", f"output matches; both raised {dname}"
        if same_out:
            return "MISMATCH", f"output matches, but PyCore raised {dname} and CPython {hname}"
        return "MISMATCH", "output differs from CPython"
    if dev.outcome == "exception":
        exc = dev.exception or {}
        return "MISMATCH", f"PyCore raised {exc.get('name')}: {exc.get('message')}; CPython did not"
    if host.get("status") == "runtime_error":
        return "MISMATCH", f"CPython raised {host.get('exception')}: {host.get('message')}; PyCore did not"
    if host.get("status") == "compile_error":
        return "MISMATCH", f"CPython rejects the program ({host.get('message')}); PyCore ran it"
    return "MISMATCH", "unexpected outcome"


def _diff(a: str, b: str) -> str:
    import difflib  # noqa: PLC0415

    return "".join(
        difflib.unified_diff(
            b.splitlines(keepends=True), a.splitlines(keepends=True),
            fromfile="CPython stdout", tofile="PyCore stdout",
        )
    )


def render_report(
    *,
    source: pathlib.Path,
    prepared: str,
    dev: DeviceResult,
    host: dict | None,
    limits: dict[str, int],
    cfg: dict,
    notes: list[str],
) -> tuple[str, dict]:
    verdict, detail = evaluate(dev, host)
    ph = device_phases(dev)
    mhz = cfg["pycore_mhz"]
    hz = host.get("nominal_hz") if host else None
    hw = bool(host and host.get("hardware_counters"))

    lines: list[str] = []
    w = lines.append
    try:
        shown = source.resolve().relative_to(pathlib.Path.cwd())
    except ValueError:
        shown = source
    title = f" PyCore report: {shown} "
    w("")
    w("=" * 4 + title + "=" * max(4, 74 - len(title)))
    w(f"  Result   {verdict} -- {detail}")
    for note in notes:
        w(f"  Note     {note}")
    if verdict == "MISMATCH" and host is not None:
        diff = _diff(dev.stdout, host.get("stdout", ""))
        if diff:
            w("")
            w("  " + diff.replace("\n", "\n  ").rstrip())
    if dev.exception and dev.outcome == "exception":
        exc = dev.exception
        w(f"  Raised   {exc['name']}: {exc['message']}  (uncaught in the program, during {exc['phase']})")
    if host and host.get("status") == "runtime_error":
        w(f"  CPython  raised {host.get('exception')}: {host.get('message')}")

    src_lines = prepared.count("\n") + (0 if prepared.endswith("\n") else 1)
    w("")
    w(f"  Source   {src_lines} lines, {len(prepared.encode()):,} bytes")
    w(
        f"  PyCore   two-core hart, CACHE_EN={cfg['cache_en']} MEM_LATENCY={cfg['mem_latency']}; "
        f"wall-clock column assumes {mhz:g} MHz"
    )
    if host and host.get("status") != "tool_error":
        how = "hardware counters" if hw else (
            f"estimated at {hz / 1e9:.2f} GHz from wall time" if hz else "wall time only")
        w(f"  CPython  {host.get('implementation', 'CPython')} {host.get('python', '?')} "
          f"on {host.get('cpu', '?')}; cycles = {how}")

    # --- comparison table -------------------------------------------------
    comp = ph.get("compile") or {}
    # After a rejected compile the "run" span is only the harness epilogue.
    run = {} if dev.outcome == "compile_error" else (ph.get("run") or {})
    h_comp_meas = (host or {}).get("compile", {}).get("first")
    h_run_meas = (host or {}).get("run", {}).get("first")
    h_comp, _ = _host_cycles(h_comp_meas, hz)
    h_run, _ = _host_cycles(h_run_meas, hz)
    tilde = "" if hw else "~"

    def cyc_cell(v, partial=False):
        if v is None:
            return "-"
        return f"{_n(v)}{'+' if partial else ''}"

    def host_cell(v):
        return "-" if v is None else f"{tilde}{_n(int(v))}"

    def ratio(a, b):
        if not a or not b:
            return "-"
        return f"{a / b:,.1f}x"

    def secs(c):
        return None if c is None else c / (mhz * 1e6)

    rows = [
        ("compile", comp.get("cycle"), comp.get("partial"), h_comp, h_comp_meas),
        ("run", run.get("cycle"), run.get("partial"), h_run, h_run_meas),
    ]
    tot_dev = sum(r[1] for r in rows if r[1] is not None) if any(r[1] is not None for r in rows) else None
    tot_host = sum(r[3] for r in rows if r[3] is not None) if any(r[3] is not None for r in rows) else None
    tot_host_ns = sum(r[4]["ns"] for r in rows if r[4]) if any(r[4] for r in rows) else None
    w("")
    w(f"  {'':10}{'PyCore cycles':>16}{'@' + format(mhz, 'g') + ' MHz':>12}"
      f"{'CPython cycles':>18}{'CPython time':>14}{'PyCore/CPython':>16}")
    for name, dc, partial, hc, hm in rows:
        w(f"  {name:10}{cyc_cell(dc, partial):>16}{_dur(secs(dc)):>12}"
          f"{host_cell(hc):>18}{_dur(hm['ns'] / 1e9 if hm else None):>14}{ratio(dc, hc):>16}")
    partial_any = any(r[2] for r in rows)
    w(f"  {'total':10}{cyc_cell(tot_dev, partial_any):>16}{_dur(secs(tot_dev)):>12}"
      f"{host_cell(tot_host):>18}{_dur(tot_host_ns / 1e9 if tot_host_ns else None):>14}"
      f"{ratio(tot_dev, tot_host):>16}")
    if host and host.get("compile"):
        hb = host["compile"]["best"]
        rb = (host.get("run") or {}).get("best")
        warm = f"compile {_dur(hb['ns'] / 1e9)}"
        if rb:
            warm += f", run {_dur(rb['ns'] / 1e9)}"
        w(f"  {'':10}CPython figures are the first (cold) call; warm best: {warm}")

    # --- PyCore detail ------------------------------------------------------
    w("")
    w("  PyCore detail")
    w(f"    boot (reset -> harness entry)     {_n(ph.get('boot_cycles'))} cycles "
      f"(+{_n(ph.get('marker_overhead_cycles'))} per phase mark, subtracted)")
    for name, p in (("compile", comp), ("run", run)):
        if not p or p.get("partial"):
            if p and p.get("partial"):
                w(f"    {name:<8} stopped by the trap after {_n(p['cycle'])} cycles")
            continue
        instr = p["instr"]
        cpi = f"{p['cycle'] / instr:.1f}" if instr else "-"
        w(f"    {name:<8} {_n(instr)} bytecodes issued, {cpi} cycles/bytecode; "
          f"excore {_n(p['excore_traps'])} handoffs / {_n(p['excore_wait'])} cycles")
        w(f"    {'':<8} L1I hit {_pct(p['l1i_hit'], p['l1i_miss'])}, "
          f"L1D hit {_pct(p['l1d_hit'], p['l1d_miss'])}")
    if dev.code_slots is not None:
        host_code = (host or {}).get("code") or {}
        extra = ""
        if host_code:
            extra = (f" (CPython: {_n(host_code['instructions'])} instructions, "
                     f"{_n(host_code['code_units'])} code units with CACHE)")
        w(f"    compiled output                  {_n(dev.code_slots)} code-RAM slots{extra}")
        free = limits.get("heap_free_bytes") or 0
        share = f" ({100 * dev.heap_compile / free:.0f}% of free heap)" if free else ""
        w(f"    heap used                        compile {_n(dev.heap_compile)} B{share}, "
          f"run {_n(dev.heap_run)} B")
    if run and not run.get("partial") and src_lines and comp.get("cycle"):
        w(f"    compile throughput               {_n(comp['cycle'] // max(1, src_lines))} cycles/line")
    if host and host.get("bytecodes_executed") is not None and run and not run.get("partial"):
        hb = host["bytecodes_executed"]
        w(f"    CPython executed                 {_n(hb)} bytecodes in the run phase"
          f" (PyCore issued {_n(run['instr'])}: ROM builtins such as print() are bytecode on PyCore)")
    w(f"    free at boot                     {_n(limits.get('code_ram_free_slots'))} code-RAM slots, "
      f"{_n(limits.get('heap_free_bytes'))} B heap")
    sim_speed = (dev.total_cycles / dev.wall_s / 1e3) if dev.total_cycles and dev.wall_s else None
    w(f"    simulation                       {_n(dev.total_cycles)} cycles in {dev.wall_s:.1f} s"
      f" ({_n(sim_speed)} kHz); log {os.path.relpath(dev.log_path)}")
    w("=" * 78)

    report = {
        "source": str(source),
        "verdict": verdict,
        "detail": detail,
        "notes": notes,
        "config": cfg,
        "device": {
            **dataclasses.asdict(dev),
            "phases": ph,
            "limits": limits,
        },
        "host": host,
    }
    return "\n".join(lines), report


# ---------------------------------------------------------------------------
# Driver used by `pycore_cli.py exec` and `shell`
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class ExecConfig:
    max_cycles: int = DEFAULT_MAX_CYCLES
    cache_en: int = 1
    mem_latency: int = 4
    heartbeat: int = DEFAULT_HEARTBEAT
    pycore_mhz: float = DEFAULT_PYCORE_MHZ
    host: bool = True
    host_python: str = sys.executable
    build_dir: str = DEFAULT_BUILD_DIR
    progress: bool = True
    json_path: str | None = None


def exec_file(path: pathlib.Path, cfg: ExecConfig, *, out=sys.stdout) -> int:
    """Compile + run ``path`` on PyCore, compare with CPython, print a report.

    Returns 0 on PASS (or RAN without a host comparison), 1 otherwise.
    """
    from image_from_source import require_python_3_14  # noqa: PLC0415

    require_python_3_14()
    path = pathlib.Path(path)
    if not path.is_file():
        print(f"exec: {path}: file not found", file=out)
        return 1
    try:
        prepared, notes = prepare_source(path)
    except SyntaxError as exc:
        print(f"exec: {path}:{exc.lineno}: SyntaxError: {exc.msg}", file=out)
        return 1

    work = pathlib.Path(cfg.build_dir)
    if not work.is_absolute():
        work = REPO_ROOT / work
    work.mkdir(parents=True, exist_ok=True)
    prepared_path = work / "program.py"
    prepared_path.write_text(prepared, encoding="utf-8")

    host = None
    if cfg.host:
        host = run_host(prepared_path, path.name, work, cfg.host_python)

    try:
        meta = build_device_image(build_harness(prepared, path.name), work)
    except (ValueError, RuntimeError) as exc:
        print(f"exec: could not build the boot image: {exc}", file=out)
        return 1
    limits = hardware_limits(meta)

    console = _Console(out, progress=cfg.progress)
    print(f"--- PyCore output ({path.name}) ---", file=out, flush=True)
    try:
        dev = run_device(
            work=work,
            meta=meta,
            max_cycles=cfg.max_cycles,
            cache_en=cfg.cache_en,
            mem_latency=cfg.mem_latency,
            heartbeat=cfg.heartbeat,
            console=console,
        )
    except RuntimeError as exc:
        console.finish()
        print(f"exec: {exc}", file=out)
        return 1
    if not console.wrote_output:
        print("(no output)", file=out)
    print("-" * (len(path.name) + 26), file=out, flush=True)

    config = {
        "cache_en": cfg.cache_en,
        "mem_latency": cfg.mem_latency,
        "max_cycles": cfg.max_cycles,
        "pycore_mhz": cfg.pycore_mhz,
    }
    text, report = render_report(
        source=path, prepared=prepared, dev=dev, host=host,
        limits=limits, cfg=config, notes=notes,
    )
    print(text, file=out, flush=True)
    json_path = pathlib.Path(cfg.json_path) if cfg.json_path else work / "report.json"
    json_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"  (full report: {os.path.relpath(json_path)})", file=out, flush=True)
    return 0 if report["verdict"] in ("PASS", "RAN") else 1
