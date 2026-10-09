#!/usr/bin/env python3.14
"""Compare the research benchmarks on PyCore and on the CPython baseline.

The CPython side is ``cpython_baseline`` (Callgrind plus the simple-core
cycle model). The PyCore side is ``pycore_exec``: on-device ``compile()``,
then ``exec``, with the same stdout check as ``make run-file``.

Cycles are the comparison. A clock only turns cycles into time.
``--pycore-mhz`` (default 1000) is the clock assumed for the hart.
CPython's own simulated time stays at the baseline machine's clock, and
every cycle count is also shown as time at 1 GHz so the two cores can be
read on one clock.

PyCore does not produce every Callgrind column. A missing counter is
recorded as such, with the reason, instead of a stand-in number.

    python3.14 pycore/tools/research_compare.py
    python3.14 pycore/tools/research_compare.py --jobs 2 --pycore-mhz 1000
    python3.14 pycore/tools/research_compare.py --report-only

``make research-compare`` is the same run. Finished programs are kept:
a later invocation skips a PyCore report that already passed, and a
CPython record that already succeeded, unless ``--force`` is set.
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import sys
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from cpython_baseline.machine import load_machine, preset_names  # noqa: E402
from cpython_baseline.runner import measure  # noqa: E402
from pycore_exec import ExecConfig, exec_file  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
RESEARCH = _TOOLS / "cpython_baseline" / "benchmarks" / "research"
DEFAULT_OUT = REPO / "build" / "research_compare"
DEFAULT_DOC = REPO / "pycore" / "docs" / "research_comparison.md"

# Longest kernels first so a multi-job run overlaps the slow simulations.
RUN_ORDER = (
    "fannkuch.py",
    "nqueens.py",
    "sor.py",
    "binary_trees.py",
    "monte_carlo.py",
    "knucleotide.py",
    "mandelbrot.py",
    "spectral_norm.py",
    "fasta.py",
    "nbody.py",
)


@dataclass(frozen=True)
class Row:
    """One measured result, paired across the two cores."""

    group: str
    name: str
    cpython: float | int | str | None
    pycore: float | int | str | None
    compare: str | None
    note: str


def _geomean(values: list[float]) -> float | None:
    usable = [v for v in values if v > 0]
    if not usable:
        return None
    return math.exp(sum(math.log(v) for v in usable) / len(usable))


def _div(num: float | None, den: float | None) -> float | None:
    if num is None or den is None or den == 0:
        return None
    return num / den


def _pct(rate: float | None) -> str:
    if rate is None:
        return "-"
    return f"{100.0 * rate:.1f}%"


def _n(value: float | int | None) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        if abs(value) >= 100:
            return f"{value:,.1f}"
        return f"{value:.2f}"
    return f"{value:,}"


def _dur(seconds: float | None) -> str:
    if seconds is None:
        return "-"
    if seconds >= 1:
        return f"{seconds:.3f} s"
    if seconds >= 1e-3:
        return f"{seconds * 1e3:.2f} ms"
    return f"{seconds * 1e6:.1f} us"


def _tick_dur(seconds: float) -> str:
    """Axis ticks are exact decades, so drop the trailing zeros used in table cells."""
    if seconds >= 1:
        return f"{seconds:g} s"
    if seconds >= 1e-3:
        return f"{seconds * 1e3:g} ms"
    return f"{seconds * 1e6:g} us"


def _ns_at(cycles: float | None, mhz: float) -> float | None:
    if cycles is None or not mhz:
        return None
    return cycles * 1000.0 / mhz


def _seconds_at(cycles: float | None, mhz: float) -> float | None:
    ns = _ns_at(cycles, mhz)
    return None if ns is None else ns / 1e9


def _ratio_text(pyc: float | None, cpy: float | None) -> str | None:
    ratio = _div(pyc, cpy)
    if ratio is None:
        return None
    return f"{ratio:.2f}x"


def _pp_text(pyc: float | None, cpy: float | None) -> str | None:
    if pyc is None or cpy is None:
        return None
    delta = 100.0 * (pyc - cpy)
    sign = "+" if delta >= 0 else ""
    return f"{sign}{delta:.1f} pp"


def _phase(record: dict | None, name: str) -> dict | None:
    if not record:
        return None
    return (record.get("phases") or {}).get(name)


def _pyc_phase(report: dict | None, name: str) -> dict | None:
    if not report:
        return None
    return ((report.get("device") or {}).get("phases") or {}).get(name)


def _hit_rate(phase: dict | None, hit_key: str, miss_key: str) -> float | None:
    if not phase or hit_key not in phase:
        return None
    hits = phase.get(hit_key) or 0
    misses = phase.get(miss_key) or 0
    total = hits + misses
    if total == 0:
        return None
    return hits / total


def _mpki(misses: float | None, instructions: float | None) -> float | None:
    if misses is None or not instructions:
        return None
    return 1000.0 * misses / instructions


def _cache(phase: dict | None, level: str) -> dict | None:
    if not phase:
        return None
    return (phase.get("caches") or {}).get(level)


def _event_cycles(phase: dict | None) -> int | None:
    if not phase:
        return None
    value = phase.get("cycles")
    return None if value is None else int(value)


def research_programs() -> list[Path]:
    files = sorted(p for p in RESEARCH.glob("*.py") if p.is_file())
    order = {name: i for i, name in enumerate(RUN_ORDER)}
    return sorted(files, key=lambda p: (order.get(p.name, len(order)), p.name))


def _row(
    group: str,
    name: str,
    cpython: float | int | str | None,
    pycore: float | int | str | None,
    compare: str | None,
    note: str,
) -> Row:
    return Row(group, name, cpython, pycore, compare, note)


def compare_program(
    cpython: dict | None,
    pycore: dict | None,
    *,
    pycore_mhz: float,
) -> list[Row]:
    """Pair every figure the baseline report prints with the hart's counter."""
    rows: list[Row] = []
    machine_mhz = None
    # The caller passes machine mhz by stashing it on the record when present.
    if cpython and cpython.get("_machine_mhz"):
        machine_mhz = float(cpython["_machine_mhz"])

    def add_phase(group: str, cpy_name: str, pyc_name: str | None, pyc_note: str) -> None:
        cphase = _phase(cpython, cpy_name)
        pphase = _pyc_phase(pycore, pyc_name) if pyc_name else None
        ccyc = _event_cycles(cphase)
        pcyc = None if pphase is None else pphase.get("cycle")
        if pphase is not None and pphase.get("partial"):
            pyc_note = (pyc_note + "; " if pyc_note else "") + "phase was cut short by a trap or the cycle limit"
        rows.append(_row(
            group, "cycles", ccyc, pcyc, _ratio_text(pcyc, ccyc) if pyc_name else None, pyc_note,
        ))
        rows.append(_row(
            group,
            "time at 1 GHz",
            _dur(_seconds_at(ccyc, 1000.0)),
            _dur(_seconds_at(pcyc, 1000.0)),
            _ratio_text(pcyc, ccyc),
            "both columns are cycles / 1e9; the ratio matches the cycle ratio",
        ))
        if machine_mhz:
            rows.append(_row(
                group,
                f"time at stated clock (CPython {machine_mhz:g} MHz, PyCore {pycore_mhz:g} MHz)",
                _dur(_seconds_at(ccyc, machine_mhz)),
                _dur(_seconds_at(pcyc, pycore_mhz)),
                None,
                "clocks differ, so this time ratio is not a performance ratio",
            ))
        cir = None if not cphase else cphase.get("events", {}).get("Ir")
        pinstr = None if pphase is None else pphase.get("instr")
        rows.append(_row(
            group, "instructions", cir, pinstr, None,
            "CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins",
        ))
        ccpi = None if not cphase else cphase.get("cpi")
        pcpi = _div(pcyc, pinstr)
        rows.append(_row(
            group, "cycles per instruction", ccpi, pcpi, None,
            "each core's own instruction; PyCore's is cycles per issued bytecode",
        ))
        for label, key, hit_key, miss_key in (
            ("L1I hit rate", "l1i", "l1i_hit", "l1i_miss"),
            ("L1D hit rate", "l1d", "l1d_hit", "l1d_miss"),
        ):
            crate = None if not _cache(cphase, key) else _cache(cphase, key).get("hit_rate")
            prate = _hit_rate(pphase, hit_key, miss_key) if pyc_name else None
            rows.append(_row(
                group, label, _pct(crate) if cphase else None,
                _pct(prate) if pyc_name else None,
                _pp_text(prate, crate) if pyc_name else None,
                "" if pyc_name else pyc_note,
            ))
            cmpki = None if not _cache(cphase, key) else _cache(cphase, key).get("mpki")
            if pyc_name and pphase is not None and pinstr:
                pmpki = _mpki(pphase.get(miss_key), pinstr)
            else:
                pmpki = None
            rows.append(_row(
                group, f"{label.split()[0]} MPKI", cmpki, pmpki, None,
                "misses per thousand of that core's own instructions"
                + ("" if pyc_name else "; " + pyc_note),
            ))
        llc = _cache(cphase, "llc")
        rows.append(_row(
            group, "LLC hit rate",
            _pct(llc.get("hit_rate")) if llc else None,
            None,
            None,
            "PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK"
            if pyc_name else pyc_note,
        ))
        if llc:
            rows.append(_row(group, "LLC MPKI", llc.get("mpki"), None, None, "no L2 miss counter on the phase mark"))
        branch = (cphase or {}).get("caches", {}).get("branch") if cphase else None
        rows.append(_row(
            group, "branch MPKI",
            None if not branch else branch.get("mpki"),
            None,
            None,
            "the hart does not count mispredicted branches",
        ))

    add_phase(
        "compile (cold)",
        "compile_cold",
        "compile",
        "",
    )
    add_phase(
        "compile (warm)",
        "compile_warm",
        None,
        "PyCore compiles once per reset; there is no second compile",
    )
    add_phase(
        "interpret (dispatch edge)",
        "interpret",
        None,
        "CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream",
    )
    add_phase(
        "run (opcode bodies and helpers)",
        "run",
        None,
        "CPython exec minus the dispatch edge. The hart does not split fetch from the opcode",
    )
    add_phase(
        "exec (cold, interpret + run)",
        "run_cold",
        "run",
        "fair column: one execution of the code object, no specialization",
    )
    add_phase(
        "exec (warm)",
        "run_warm",
        None,
        "CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this",
    )

    # Dispatch share and the three-way split.
    run_cold = _phase(cpython, "run_cold")
    interpret = _phase(cpython, "interpret")
    exec_ir = None if not run_cold else run_cold.get("events", {}).get("Ir")
    disp_ir = None if not interpret else interpret.get("events", {}).get("Ir")
    disp_share = _div(disp_ir, exec_ir)
    rows.append(_row(
        "exec split",
        "dispatch share of exec instructions",
        _pct(disp_share),
        None,
        None,
        "share of x86 instructions on the jump-table edge",
    ))
    breakdown = (cpython or {}).get("run_cold_breakdown") or {}
    for key, label in (
        ("dispatch", "dispatch cycles"),
        ("inline_opcodes", "inline opcode cycles"),
        ("c_helpers", "C helper cycles"),
    ):
        part = breakdown.get(key) or {}
        rows.append(_row(
            "exec split", label, part.get("cycles"), None, None,
            "no matching split on the hart",
        ))

    pyc_run = _pyc_phase(pycore, "run") or {}
    pyc_comp = _pyc_phase(pycore, "compile") or {}
    for group, phase in (("compile (cold)", pyc_comp), ("exec (cold, interpret + run)", pyc_run)):
        traps = phase.get("excore_traps")
        wait = phase.get("excore_wait")
        cyc = phase.get("cycle")
        rows.append(_row(group, "excore handoffs", None, traps, None, "PyCore only; recoverable traps to the companion core"))
        rows.append(_row(
            group, "excore wait cycles", None, wait,
            _pct(_div(wait, cyc)) if wait is not None and cyc else None,
            "cycles the hart spent marshalling and waiting; compare cell is the share of that phase",
        ))

    bytecodes = None if not cpython else cpython.get("bytecodes_executed")
    per = (cpython or {}).get("cycles_per_bytecode") or {}
    pyc_exec_cyc = pyc_run.get("cycle")
    rows.append(_row(
        "bytecode",
        "CPython bytecodes executed",
        bytecodes,
        bytecodes,
        None,
        "sys.monitoring count of the source; the same denominator for both cores",
    ))
    rows.append(_row(
        "bytecode",
        "PyCore bytecodes issued",
        None,
        pyc_run.get("instr"),
        None,
        "includes ROM bodies such as print(); larger than the monitoring count",
    ))
    rows.append(_row(
        "bytecode",
        "exec cycles per CPython bytecode",
        None if not per else per.get("exec"),
        _div(pyc_exec_cyc, bytecodes),
        _ratio_text(_div(pyc_exec_cyc, bytecodes), None if not per else per.get("exec")),
        "cold exec cycles divided by the monitoring count",
    ))
    rows.append(_row(
        "bytecode",
        "dispatch cycles per CPython bytecode",
        None if not per else per.get("dispatch"),
        None,
        None,
        "the hart has no separate dispatch-edge cycle count",
    ))

    code = (cpython or {}).get("code") or {}
    dev = (pycore or {}).get("device") or {}
    rows.append(_row(
        "code",
        "instructions / code-RAM slots",
        code.get("instructions"),
        dev.get("code_slots"),
        None,
        "CPython instruction count versus slots the on-device compiler allocated",
    ))
    rows.append(_row(
        "code",
        "CPython code units with CACHE",
        code.get("code_units"),
        None,
        None,
        "the on-device compiler emits no CACHE",
    ))

    tops = ((cpython or {}).get("top_functions") or {}).get("run_cold") or []
    if tops:
        summary = "; ".join(f"{item['function']} ({item['instructions']})" for item in tops[:5])
    else:
        summary = None
    rows.append(_row(
        "profile",
        "hottest exec functions",
        summary,
        None,
        None,
        "Callgrind attributes x86 instructions to symbols; the hart has no per-function profile",
    ))
    return rows


def _program_name(record: dict) -> str:
    return Path(str(record.get("program", ""))).name


def suite_rows(programs: list[dict]) -> list[dict]:
    """One summary row per program, the columns the research table prints."""
    out = []
    for item in programs:
        cpy = item.get("cpython")
        pyc = item.get("pycore")
        run_cold = _phase(cpy, "run_cold")
        interpret = _phase(cpy, "interpret")
        compile_cold = _phase(cpy, "compile_cold")
        run_warm = _phase(cpy, "run_warm")
        pyc_run = _pyc_phase(pyc, "run") or {}
        pyc_comp = _pyc_phase(pyc, "compile") or {}
        exec_ir = None if not run_cold else run_cold.get("events", {}).get("Ir")
        disp_ir = None if not interpret else interpret.get("events", {}).get("Ir")
        bytecodes = None if not cpy else cpy.get("bytecodes_executed")
        ccyc = _event_cycles(run_cold)
        pcyc = pyc_run.get("cycle")
        verdict = None if not pyc else pyc.get("verdict")
        # A trap or a rejected compile still leaves a cycle counter. It is
        # not an execution of the benchmark, so it stays out of the ratios.
        finished = verdict in ("PASS", "MISMATCH") and not pyc_run.get("partial")
        compile_done = (
            verdict not in (None, "UNSUPPORTED")
            and pyc_comp.get("cycle")
            and not pyc_comp.get("partial")
        )
        out.append({
            "program": item["program"],
            "verdict": verdict,
            "stdout_match": item.get("stdout_match"),
            "finished": finished,
            "cpy_compile": _event_cycles(compile_cold),
            "pyc_compile": pyc_comp.get("cycle"),
            "cpy_interpret": _event_cycles(interpret),
            "cpy_run": _event_cycles(_phase(cpy, "run")),
            "cpy_exec": ccyc,
            "pyc_exec": pcyc if finished else None,
            "pyc_exec_partial": None if finished else pcyc,
            "exec_ratio": _div(pcyc, ccyc) if finished else None,
            "compile_ratio": _div(pyc_comp.get("cycle"), _event_cycles(compile_cold)) if compile_done else None,
            "cpy_l1d": None if not _cache(run_cold, "l1d") else _cache(run_cold, "l1d").get("hit_rate"),
            "pyc_l1d": _hit_rate(pyc_run, "l1d_hit", "l1d_miss"),
            "cpy_l1i": None if not _cache(run_cold, "l1i") else _cache(run_cold, "l1i").get("hit_rate"),
            "pyc_l1i": _hit_rate(pyc_run, "l1i_hit", "l1i_miss"),
            "cpy_llc": None if not _cache(run_cold, "llc") else _cache(run_cold, "llc").get("hit_rate"),
            "disp_share": _div(disp_ir, exec_ir),
            "cpy_per_bc": _div(ccyc, bytecodes),
            "pyc_per_bc": _div(pcyc, bytecodes),
            "cpy_warm": _event_cycles(run_warm),
            "cpy_branch_mpki": None if not _cache(run_cold, "branch") else (
                (_cache(run_cold, "branch") or {}).get("mpki")
            ),
            "pyc_excore_wait": pyc_run.get("excore_wait"),
            "pyc_excore_traps": pyc_run.get("excore_traps"),
            "bytecodes": bytecodes,
            "pyc_issued": pyc_run.get("instr"),
        })
    return out


def _cell(value, kind: str = "num") -> str:
    if value is None or value == "":
        return "-"
    if kind == "pct":
        return _pct(value) if isinstance(value, float) else str(value)
    if kind == "ratio":
        return f"{value:.2f}x"
    if kind == "float":
        return f"{value:.1f}"
    if isinstance(value, str):
        return value
    return _n(value)


def render_markdown(payload: dict) -> str:
    mhz = payload["pycore_mhz"]
    machine = payload.get("cpython_machine") or {}
    lines: list[str] = []
    w = lines.append
    w("# Research benchmark comparison")
    w("")
    w("PyCore versus the CPython 3.14 baseline on the research set")
    w("(`pycore/tools/cpython_baseline/benchmarks/research/`).")
    w("Regenerate with `make research-compare`.")
    w("")
    w(f"Recorded {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}.")
    w("")
    w("## How to read the numbers")
    w("")
    w("Cycles are the result. The hart's simulated time uses")
    w(f"**{mhz:g} MHz**. CPython's simulated time uses the baseline")
    w(f"machine clock ({machine.get('frequency_mhz', '-')} MHz, preset")
    w(f"`{machine.get('name', 'pycore')}`). A second time column puts both")
    w("cores at 1 GHz, so that ratio is the cycle ratio and the clock")
    w("assumption drops out.")
    w("")
    w("The fair exec column is CPython `run_cold` (dispatch edge plus")
    w("opcode bodies plus C helpers, first execution) against PyCore's")
    w("run phase (on-device `exec` of the code object the hart just")
    w("compiled). PyCore does not specialize, so there is no warm exec.")
    w("CPython's `interpret` and `run` columns stay CPython-only: they")
    w("split an x86 instruction stream the hart does not have.")
    w("")
    w("CPython leaves the garbage collector on. This hart run leaves it")
    w("off, which is the default `make run-file` configuration")
    w(f"(two-core, `CACHE_EN=1`, `MEM_LATENCY={payload['pycore_config']['mem_latency']}`).")
    w("L1 hit rates on PyCore count the hart's own accesses during that")
    w("phase. LLC hit rate and branch MPKI are Callgrind results; the")
    w("phase mark does not count L2 misses or mispredicted branches.")
    w("")
    w("Two files needed a source change before the hart could finish them.")
    w("`mandelbrot.py` and `spectral_norm.py` had a non-ASCII character in")
    w("a comment. The on-device compiler raises `SyntaxError` on that, so")
    w("the comments are ASCII and the kernels are unchanged.")
    w("`binary_trees.py` tested a leaf with `node == 0`. A list compared")
    w("with an int TYPE-traps, and a node is a non-empty list, so the test")
    w("is `not node`. The printed checksums are the ones in")
    w("`cpython_benchmarks.md`.")
    w("")
    w("## Suite")
    w("")
    w("| program | result | cpy compile | pyc compile | compile × | cpy exec | pyc exec | exec × | cpy L1D | pyc L1D | cpy L1I | pyc L1I | cpy LLC | disp% | c/bc cpy | c/bc pyc | pyc @1GHz | cpy @1GHz |")
    w("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    summary = payload["suite"]
    for row in summary:
        w(
            "| {program} | {verdict} | {cc} | {pc} | {cr} | {ce} | {pe} | {er} | {cl1d} | {pl1d} | {cl1i} | {pl1i} | {llc} | {disp} | {cbc} | {pbc} | {pt} | {ct} |".format(
                program=row["program"],
                verdict=row.get("verdict") or "-",
                cc=_cell(row["cpy_compile"]),
                pc=_cell(row["pyc_compile"]),
                cr=_cell(row["compile_ratio"], "ratio"),
                ce=_cell(row["cpy_exec"]),
                pe=_cell(row["pyc_exec"]),
                er=_cell(row["exec_ratio"], "ratio"),
                cl1d=_cell(row["cpy_l1d"], "pct"),
                pl1d=_cell(row["pyc_l1d"], "pct"),
                cl1i=_cell(row["cpy_l1i"], "pct"),
                pl1i=_cell(row["pyc_l1i"], "pct"),
                llc=_cell(row["cpy_llc"], "pct"),
                disp=_cell(row["disp_share"], "pct"),
                cbc=_cell(row["cpy_per_bc"], "float"),
                pbc=_cell(row["pyc_per_bc"], "float"),
                pt=_dur(_seconds_at(row["pyc_exec"], 1000.0)),
                ct=_dur(_seconds_at(row["cpy_exec"], 1000.0)),
            )
        )
    finished_rows = [r for r in summary if r.get("finished") and r.get("cpy_exec") and r.get("pyc_exec")]
    geo_exec_c = _geomean([r["cpy_exec"] for r in finished_rows])
    geo_exec_p = _geomean([r["pyc_exec"] for r in finished_rows])
    geo_ratio = _geomean([r["exec_ratio"] for r in finished_rows])
    w(
        "| geomean | | | | | {ce} | {pe} | {er} | | | | | | | | | {pt} | {ct} |".format(
            ce=_cell(round(geo_exec_c) if geo_exec_c else None),
            pe=_cell(round(geo_exec_p) if geo_exec_p else None),
            er=_cell(geo_ratio, "ratio"),
            pt=_dur(_seconds_at(geo_exec_p, 1000.0)),
            ct=_dur(_seconds_at(geo_exec_c, 1000.0)),
        )
    )
    w("")
    w("`c/bc` divides cold-exec cycles by CPython's `sys.monitoring` count")
    w("of the same source. `exec ×` is PyCore run cycles divided by CPython")
    w("`run_cold` cycles. `disp%` is the dispatch edge's share of CPython's")
    w("cold-exec instructions. The geometric mean uses programs that")
    w("finished (PASS or MISMATCH) with a positive exec cycle count.")
    w("")
    w("| program | cpy warm exec | cpy branch MPKI | pyc excore handoffs | pyc excore wait | excore share of exec |")
    w("| --- | ---: | ---: | ---: | ---: | ---: |")
    for row in summary:
        share = _div(row.get("pyc_excore_wait"), row.get("pyc_exec"))
        w(
            f"| {row['program']} | {_cell(row['cpy_warm'])} | {_cell(row['cpy_branch_mpki'], 'float')} | "
            f"{_cell(row['pyc_excore_traps'])} | {_cell(row['pyc_excore_wait'])} | {_cell(share, 'pct')} |"
        )
    w("")
    w("Warm exec is CPython's second execution after PEP 659. Branch MPKI")
    w("is mispredicted conditional and indirect branches per thousand")
    w("retired x86 instructions on the cold exec. Excore wait is hart")
    w("cycles spent handing container and console work to the companion.")
    w("")
    w("## Each measured result")
    w("")
    for item in payload["programs"]:
        w(f"### {item['program']}")
        w("")
        verdict = item.get("verdict") or "-"
        match = "stdout matches" if item.get("stdout_match") else "stdout differs"
        w(f"PyCore result: {verdict}. {match}.")
        if item.get("pycore_stdout") is not None:
            shown = item["pycore_stdout"].replace("\n", "↵")
            w(f"PyCore stdout: `{shown}`")
        if item.get("cpython_stdout") is not None:
            shown = item["cpython_stdout"].replace("\n", "↵")
            w(f"CPython stdout: `{shown}`")
        notes = item.get("notes") or []
        for note in notes:
            w(f"Note: {note}")
        w("")
        w("| group | result | CPython | PyCore | compare | note |")
        w("| --- | --- | ---: | ---: | ---: | --- |")
        for row in item["rows"]:
            note = str(row["note"]).replace("|", "/")
            w(
                f"| {row['group']} | {row['name']} | {_md(row['cpython'])} | {_md(row['pycore'])} | "
                f"{row['compare'] or '-'} | {note} |"
            )
        w("")
    return "\n".join(lines).rstrip() + "\n"


def _md(value) -> str:
    if value is None or value == "":
        return "-"
    if isinstance(value, str):
        return value.replace("|", "/")
    return _n(value)


def _stdout_match(cpy: dict | None, pyc: dict | None) -> bool | None:
    if not cpy or not pyc:
        return None
    dev = pyc.get("device") or {}
    return dev.get("stdout") == cpy.get("stdout")


def build_payload(
    cpython_payload: dict,
    pycore_reports: dict[str, dict],
    *,
    pycore_mhz: float,
    pycore_config: dict,
) -> dict:
    machine = cpython_payload.get("machine") or {}
    mhz = machine.get("frequency_mhz")
    by_name = {_program_name(r): r for r in cpython_payload.get("programs") or []}
    names = sorted(set(by_name) | set(pycore_reports), key=lambda n: (RUN_ORDER.index(n) if n in RUN_ORDER else 99, n))
    # Present alphabetically in the written report.
    names = sorted(names)
    programs = []
    for name in names:
        cpy = by_name.get(name)
        if cpy is not None and mhz:
            cpy = dict(cpy)
            cpy["_machine_mhz"] = mhz
        pyc = pycore_reports.get(name)
        rows = compare_program(cpy, pyc, pycore_mhz=pycore_mhz)
        programs.append({
            "program": name,
            "verdict": None if not pyc else pyc.get("verdict"),
            "stdout_match": _stdout_match(cpy, pyc),
            "pycore_stdout": None if not pyc else (pyc.get("device") or {}).get("stdout"),
            "cpython_stdout": None if not cpy else cpy.get("stdout"),
            "notes": list((cpy or {}).get("notes") or []),
            "cpython": cpy,
            "pycore": pyc,
            "rows": rows,
        })
    suite = suite_rows(programs)
    return {
        "schema_version": 1,
        "pycore_mhz": pycore_mhz,
        "cpython_machine": machine,
        "cpython_python": cpython_payload.get("python"),
        "pycore_config": pycore_config,
        "programs": [
            {k: v for k, v in item.items() if k not in ("cpython", "pycore")}
            | {"rows": [row.__dict__ for row in item["rows"]]}
            for item in programs
        ],
        "suite": suite,
    }


def _write_payload(path: Path, payload: dict) -> None:
    # Rows are already plain dicts in build_payload.
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _load_json(path: Path) -> dict | None:
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _pycore_reusable(report: dict | None) -> bool:
    if not report:
        return False
    return report.get("verdict") in ("PASS", "MISMATCH")


def run_cpython(
    programs: list[Path],
    out: Path,
    machine_name: str,
    *,
    force: bool,
    dest_name: str = "cpython.json",
    work_name: str = "callgrind",
) -> dict:
    from cpython_baseline.runner import python_identity  # noqa: PLC0415

    dest = out / dest_name
    existing = _load_json(dest) or {}
    by_name = {
        _program_name(r): r
        for r in existing.get("programs") or []
        if r.get("status") == "ok"
    }
    # --force reruns the selected programs only. The others stay on disk.
    if force:
        for program in programs:
            by_name.pop(program.name, None)
    machine = load_machine(machine_name)
    work = out / work_name

    def save() -> dict:
        payload = {
            "schema_version": 1,
            "machine": machine.to_json(),
            "python": python_identity(),
            "programs": sorted(by_name.values(), key=_program_name),
        }
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return payload

    for program in programs:
        if program.name in by_name:
            print(f"cpython {program.name}: reuse", flush=True)
            continue
        print(f"cpython {program.name}: callgrind", flush=True)
        record = measure(program, machine, work)
        by_name[program.name] = record
        save()
        print(
            f"cpython {program.name}: {record.get('status')} "
            f"exec={((record.get('phases') or {}).get('run_cold') or {}).get('cycles')}",
            flush=True,
        )
    return save()


def run_pycore_one(
    program: Path,
    dest: Path,
    *,
    mhz: float,
    max_cycles: int,
    mem_latency: int,
    force: bool,
) -> dict:
    dest.mkdir(parents=True, exist_ok=True)
    report_path = dest / "report.json"
    existing = _load_json(report_path)
    if not force and _pycore_reusable(existing):
        print(f"pycore {program.name}: reuse {existing.get('verdict')}", flush=True)
        return existing
    log_path = dest / "exec.log"
    cfg = ExecConfig(
        max_cycles=max_cycles,
        cache_en=1,
        mem_latency=mem_latency,
        heartbeat=5_000_000,
        pycore_mhz=mhz,
        host=True,
        build_dir=str(dest),
        progress=False,
        json_path=str(report_path),
    )
    print(f"pycore {program.name}: start", flush=True)
    with log_path.open("w", encoding="utf-8") as fh:
        try:
            exec_file(program, cfg, out=fh)
        except Exception:
            fh.write("\n" + traceback.format_exc())
            raise
    report = _load_json(report_path) or {"verdict": "ERROR", "detail": "no report"}
    phases = (report.get("device") or {}).get("phases") or {}
    run_cyc = (phases.get("run") or {}).get("cycle")
    print(f"pycore {program.name}: {report.get('verdict')} run={run_cyc}", flush=True)
    return report


def run_pycore(
    programs: list[Path],
    out: Path,
    *,
    mhz: float,
    max_cycles: int,
    mem_latency: int,
    jobs: int,
    force: bool,
) -> dict[str, dict]:
    reports: dict[str, dict] = {}

    def go(program: Path) -> tuple[str, dict]:
        report = run_pycore_one(
            program, out / "pycore" / program.stem,
            mhz=mhz, max_cycles=max_cycles, mem_latency=mem_latency, force=force,
        )
        return program.name, report

    if jobs <= 1:
        for program in programs:
            name, report = go(program)
            reports[name] = report
        return reports
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(go, program) for program in programs]
        for fut in as_completed(futures):
            name, report = fut.result()
            reports[name] = report
    return reports


def _exec_cycles(record: dict | None) -> int | None:
    if not record or record.get("status") != "ok":
        return None
    return _event_cycles(_phase(record, "run_cold"))


def _pyc_exec_cycles(report: dict | None) -> int | None:
    phase = _pyc_phase(report, "run") or {}
    if phase.get("partial"):
        return None
    if report and report.get("verdict") not in ("PASS", "MISMATCH"):
        return None
    value = phase.get("cycle")
    return None if not value else int(value)


# Stable left-to-right order: the hart, then CPython presets from the
# slow-clock paper machines to the desktop.
_MACHINE_ORDER = ("pycore-hart", "romer", "pycore", "gem5_classic", "skylake")

_SERIES_COLOR = {
    "pycore-hart": "#1b4f72",
    "romer": "#6c3483",
    "pycore": "#1a5276",
    "gem5_classic": "#1e8449",
    "skylake": "#b9770e",
}


def _clock_label(mhz: float) -> str:
    if mhz >= 1000 and mhz % 1000 == 0:
        return f"{mhz / 1000:g} GHz"
    if mhz >= 1000:
        return f"{mhz / 1000:.1f} GHz"
    return f"{mhz:g} MHz"


def _series_label(key: str, mhz: float) -> str:
    if key == "pycore-hart":
        return f"PyCore hart {_clock_label(mhz)}"
    machine = load_machine(key)
    short = {
        "pycore": "CPython, PyCore caches",
        "gem5_classic": "CPython, gem5 classic",
        "skylake": "CPython, Skylake",
        "romer": "CPython, Romer",
    }
    return f"{short.get(key, 'CPython ' + key)} {_clock_label(machine.frequency_mhz)}"


def machine_chart_data(
    pycore_reports: dict[str, dict],
    machine_payloads: dict[str, dict],
    *,
    pycore_mhz: float,
) -> dict:
    """Cold-exec cycles and time for the hart and every CPython machine."""
    names = sorted({
        name
        for payload in machine_payloads.values()
        for name in (_program_name(r) for r in payload.get("programs") or [])
    } | set(pycore_reports))
    programs = []
    for name in names:
        entry = {"program": name, "series": {}}
        pcyc = _pyc_exec_cycles(pycore_reports.get(name))
        if pcyc:
            entry["series"]["pycore-hart"] = {
                "cycles": pcyc,
                "seconds": pcyc / (pycore_mhz * 1e6),
                "mhz": pycore_mhz,
            }
        for machine_name, payload in machine_payloads.items():
            record = next(
                (r for r in payload.get("programs") or [] if _program_name(r) == name),
                None,
            )
            ccyc = _exec_cycles(record)
            mhz = (payload.get("machine") or {}).get("frequency_mhz")
            if ccyc and mhz:
                entry["series"][machine_name] = {
                    "cycles": ccyc,
                    "seconds": ccyc / (float(mhz) * 1e6),
                    "mhz": float(mhz),
                }
        programs.append(entry)
    series_keys = [key for key in _MACHINE_ORDER if any(key in item["series"] for item in programs)]
    for key in machine_payloads:
        if key not in series_keys:
            series_keys.append(key)
    if "pycore-hart" not in series_keys and any("pycore-hart" in item["series"] for item in programs):
        series_keys.insert(0, "pycore-hart")
    geomean = {}
    for key in series_keys:
        cycles = [item["series"][key]["cycles"] for item in programs if key in item["series"]]
        seconds = [item["series"][key]["seconds"] for item in programs if key in item["series"]]
        mhz = next(item["series"][key]["mhz"] for item in programs if key in item["series"])
        geomean[key] = {
            "cycles": _geomean([float(c) for c in cycles]),
            "seconds": _geomean(seconds),
            "mhz": mhz,
            "programs": len(cycles),
        }
    return {
        "pycore_mhz": pycore_mhz,
        "series": [
            {"key": key, "label": _series_label(key, pycore_mhz), "color": _SERIES_COLOR.get(key, "#566573")}
            for key in series_keys
        ],
        "programs": programs,
        "geomean": geomean,
    }


def _xml(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def render_chart_svg(data: dict) -> str:
    """Log-scale grouped bars of cold-exec time. One group per program, plus the geomean."""
    series = data["series"]
    groups = list(data["programs"]) + [{
        "program": "geomean",
        "series": {
            key: {"seconds": value["seconds"], "cycles": value["cycles"]}
            for key, value in data["geomean"].items()
            if value.get("seconds")
        },
    }]
    times = [
        item["series"][spec["key"]]["seconds"]
        for item in groups
        for spec in series
        if spec["key"] in item["series"] and item["series"][spec["key"]]["seconds"] > 0
    ]
    if not times:
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"640\" height=\"80\"><text x=\"16\" y=\"40\">no machine data</text></svg>\n"
    vmin = 10 ** math.floor(math.log10(min(times)))
    vmax = 10 ** math.ceil(math.log10(max(times) * 1.05))
    if vmax <= vmin:
        vmax = vmin * 10
    width = 1040
    height = 560
    left, right, top, bottom = 72, 24, 108, 92
    plot_w = width - left - right
    plot_h = height - top - bottom
    n_series = len(series)
    n_groups = len(groups)
    gap = 18
    group_w = plot_w / n_groups
    bar_w = min(14.0, (group_w - gap) / max(1, n_series))

    def y_of(seconds: float) -> float:
        frac = (math.log10(seconds) - math.log10(vmin)) / (math.log10(vmax) - math.log10(vmin))
        return top + plot_h * (1.0 - frac)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#fbfcfd"/>',
        '<text x="72" y="28" font-family="sans-serif" font-size="18" fill="#1c2833">Research cold-exec time</text>',
        '<text x="72" y="48" font-family="sans-serif" font-size="12" fill="#566573">PyCore at its assumed clock. Each CPython bar uses that preset\'s clock. The scale is logarithmic.</text>',
    ]
    decade = vmin
    while decade <= vmax * 1.001:
        y = y_of(decade)
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="#d5d8dc"/>')
        label = _tick_dur(decade)
        parts.append(
            f'<text x="{left - 8}" y="{y + 4:.1f}" text-anchor="end" font-family="sans-serif" font-size="11" fill="#566573">{_xml(label)}</text>'
        )
        decade *= 10
    parts.append(f'<line x1="{left}" y1="{top + plot_h}" x2="{width - right}" y2="{top + plot_h}" stroke="#1c2833"/>')
    for index, group in enumerate(groups):
        origin = left + index * group_w + (group_w - (n_series * bar_w)) / 2
        for s_index, spec in enumerate(series):
            point = group["series"].get(spec["key"])
            if not point or not point.get("seconds"):
                continue
            y = y_of(point["seconds"])
            h = top + plot_h - y
            x = origin + s_index * bar_w
            parts.append(
                f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w - 1:.1f}" height="{max(h, 0):.1f}" fill="{spec["color"]}"/>'
            )
        label = group["program"].removesuffix(".py")
        lx = left + index * group_w + group_w / 2
        parts.append(
            f'<text x="{lx:.1f}" y="{top + plot_h + 16}" text-anchor="end" transform="rotate(-40 {lx:.1f} {top + plot_h + 16})" font-family="sans-serif" font-size="11" fill="#1c2833">{_xml(label)}</text>'
        )
    legend_x = left
    legend_y = 62
    for spec in series:
        need = 20 + len(spec["label"]) * 6.3
        if legend_x + need > width - right:
            legend_x = left
            legend_y += 18
        parts.append(f'<rect x="{legend_x}" y="{legend_y}" width="12" height="12" fill="{spec["color"]}"/>')
        parts.append(
            f'<text x="{legend_x + 16}" y="{legend_y + 11}" font-family="sans-serif" font-size="11" fill="#1c2833">{_xml(spec["label"])}</text>'
        )
        legend_x += need
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def render_machines_markdown(data: dict) -> str:
    lines = ["# CPython research benchmarks across machines", ""]
    lines.append(
        "Cold-exec time for the research set. PyCore is the measured hart. "
        "Every other series is CPython 3.14 under the simple-core model "
        "(`cpython_baseline`) at that preset's own clock, so a faster clock "
        "is part of the machine. The same cycle counts are in the table."
    )
    lines.append("")
    lines.append("Regenerate with `make research-compare-machines`.")
    lines.append("")
    lines.append(f"Recorded {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}.")
    lines.append("")
    lines.append("![Research cold-exec time](research_machines.svg)")
    lines.append("")
    lines.append("## Geometric mean")
    lines.append("")
    lines.append("| machine | clock | programs | geomean cycles | geomean time |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    for spec in data["series"]:
        stats = data["geomean"].get(spec["key"]) or {}
        cycles = stats.get("cycles")
        lines.append(
            f"| {spec['label']} | {stats.get('mhz', '-'):g} MHz | {stats.get('programs', '-')} | "
            f"{_n(round(cycles)) if cycles else '-'} | {_dur(stats.get('seconds'))} |"
        )
    lines.append("")
    lines.append("## Cold exec, per program")
    lines.append("")
    header = "| program | " + " | ".join(spec["label"] for spec in data["series"]) + " |"
    rule = "| --- | " + " | ".join("---:" for _ in data["series"]) + " |"
    lines.append(header)
    lines.append(rule)
    for item in data["programs"]:
        cells = []
        for spec in data["series"]:
            point = item["series"].get(spec["key"])
            if not point:
                cells.append("-")
            else:
                cells.append(f"{_dur(point['seconds'])} ({_n(point['cycles'])})")
        lines.append(f"| {item['program']} | " + " | ".join(cells) + " |")
    lines.append("")
    lines.append("Each cell is simulated time at that machine's clock, then the cycle count.")
    lines.append("Time is cycles / clock. A smaller bar is a faster machine.")
    lines.append("")
    return "\n".join(lines)


def _machine_names(spec: str) -> list[str]:
    if spec == "all":
        names = preset_names()
    else:
        names = [part.strip() for part in spec.split(",") if part.strip()]
    for name in names:
        load_machine(name)
    return names


def _copy_payload(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(src.read_text(encoding="utf-8"), encoding="utf-8")


def run_machines(
    programs: list[Path],
    out: Path,
    names: list[str],
    *,
    jobs: int,
    force: bool,
) -> dict[str, dict]:
    """Callgrind the research set on each preset. One directory per machine."""
    out.mkdir(parents=True, exist_ok=True)
    # The single-machine file is the pycore preset from `make research-compare`.
    preset_file = out / "cpython.json"
    preset = _load_json(preset_file)
    if preset and (preset.get("machine") or {}).get("name") == "pycore":
        cached = out / "machines" / "pycore" / "cpython.json"
        if not cached.is_file():
            _copy_payload(preset_file, cached)

    def one(name: str) -> tuple[str, dict]:
        print(f"machine {name}: start", flush=True)
        payload = run_cpython(
            programs,
            out / "machines" / name,
            name,
            force=force,
            dest_name="cpython.json",
            work_name="callgrind",
        )
        print(f"machine {name}: {len(payload.get('programs') or [])} programs", flush=True)
        return name, payload

    payloads: dict[str, dict] = {}
    if jobs <= 1:
        for name in names:
            key, payload = one(name)
            payloads[key] = payload
        return payloads
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(one, name) for name in names]
        for fut in as_completed(futures):
            key, payload = fut.result()
            payloads[key] = payload
    return payloads


def _select(programs: list[Path], names: list[str]) -> list[Path]:
    if not names:
        return programs
    wanted = set(names)
    chosen = [p for p in programs if p.name in wanted or p.stem in wanted]
    missing = wanted - {p.name for p in chosen} - {p.stem for p in chosen}
    if missing:
        raise SystemExit(f"unknown program(s): {', '.join(sorted(missing))}")
    return chosen


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--doc", type=Path, default=None, help="Also write the markdown report here")
    parser.add_argument("--machine", default="pycore", help="CPython baseline preset used for the one-core comparison")
    parser.add_argument(
        "--machines",
        default="",
        help="Comma-separated presets, or 'all', for the multi-machine chart",
    )
    parser.add_argument(
        "--chart-doc",
        type=Path,
        default=None,
        help="Write the machine chart markdown here (svg beside it)",
    )
    parser.add_argument("--pycore-mhz", type=float, default=1000.0)
    parser.add_argument("--max-cycles", type=int, default=2_000_000_000)
    parser.add_argument("--mem-latency", type=int, default=4)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--force", action="store_true", help="Rerun programs that already have a report")
    parser.add_argument("--skip-cpython", action="store_true")
    parser.add_argument("--skip-pycore", action="store_true")
    parser.add_argument("--report-only", action="store_true", help="Rebuild the report from saved JSON")
    parser.add_argument("--program", action="append", default=[], help="Stem or filename; default is the research set")
    args = parser.parse_args(argv)

    programs = _select(research_programs(), args.program)
    out = args.out if args.out.is_absolute() else REPO / args.out
    out.mkdir(parents=True, exist_ok=True)

    if args.report_only:
        args.skip_cpython = True
        args.skip_pycore = True

    if args.skip_cpython:
        cpython_payload = _load_json(out / "cpython.json")
        if cpython_payload is None:
            raise SystemExit(f"no {out / 'cpython.json'}; run without --skip-cpython")
    else:
        cpython_payload = run_cpython(programs, out, args.machine, force=args.force)

    if args.skip_pycore:
        pycore_reports = {}
    else:
        pycore_reports = run_pycore(
            programs, out,
            mhz=args.pycore_mhz,
            max_cycles=args.max_cycles,
            mem_latency=args.mem_latency,
            jobs=max(1, args.jobs),
            force=args.force,
        )
    # A partial invocation still reports every program that already has a
    # saved hart report, so --program reruns one kernel without dropping
    # the others.
    for program in research_programs():
        if program.name in pycore_reports:
            continue
        saved = _load_json(out / "pycore" / program.stem / "report.json")
        if saved is not None:
            pycore_reports[program.name] = saved

    payload = build_payload(
        cpython_payload,
        pycore_reports,
        pycore_mhz=args.pycore_mhz,
        pycore_config={
            "cache_en": 1,
            "mem_latency": args.mem_latency,
            "gc": False,
            "cores": 2,
            "max_cycles": args.max_cycles,
        },
    )
    text = render_markdown(payload)
    (out / "comparison.md").write_text(text, encoding="utf-8")
    _write_payload(out / "comparison.json", payload)
    if args.doc:
        doc = args.doc if args.doc.is_absolute() else REPO / args.doc
        doc.parent.mkdir(parents=True, exist_ok=True)
        doc.write_text(text, encoding="utf-8")
        _write_payload(doc.with_suffix(".json"), payload)
    print(f"wrote {out / 'comparison.md'}", flush=True)
    if args.machines:
        names = _machine_names(args.machines)
        if args.report_only or args.skip_cpython:
            payloads = {}
            for name in names:
                loaded = _load_json(out / "machines" / name / "cpython.json")
                if loaded is None and name == "pycore":
                    loaded = cpython_payload
                if loaded is None:
                    raise SystemExit(f"no saved baseline for machine {name}")
                payloads[name] = loaded
        else:
            payloads = run_machines(programs, out, names, jobs=max(1, args.jobs), force=args.force)
        chart = machine_chart_data(pycore_reports, payloads, pycore_mhz=args.pycore_mhz)
        svg = render_chart_svg(chart)
        (out / "research_machines.svg").write_text(svg, encoding="utf-8")
        chart_md = render_machines_markdown(chart)
        (out / "research_machines.md").write_text(chart_md, encoding="utf-8")
        _write_payload(out / "research_machines.json", chart)
        print(f"wrote {out / 'research_machines.md'}", flush=True)
        if args.chart_doc:
            doc = args.chart_doc if args.chart_doc.is_absolute() else REPO / args.chart_doc
            doc.parent.mkdir(parents=True, exist_ok=True)
            doc.write_text(chart_md, encoding="utf-8")
            doc.with_suffix(".svg").write_text(svg, encoding="utf-8")
            _write_payload(doc.with_suffix(".json"), chart)
    bad = [
        item["program"] for item in payload["programs"]
        if item.get("verdict") != "PASS" or item.get("stdout_match") is False
    ]
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
