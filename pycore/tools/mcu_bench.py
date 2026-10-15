#!/usr/bin/env python3.14
"""Compare the research kernels with MicroPython, and with similar MCUs.

The functional oracle is the MicroPython unix port, not CPython. Each
research program is run under ``micropython`` and its stdout is checked
against the locked checksum. The PyCore hart's already-measured exec
cycles are copied from ``pycore/docs/research_comparison.json`` when that
file is present.

Similar boards (RP2040, STM32F411, nRF52840) each have a C, C++, and
MicroPython column. A cell is filled only from a JSON measurement under
``pycore/tools/mcu_bench/peers/``. This machine does not flash a board, so
an empty peers directory leaves those cells as not measured.

Usage::

    python3.14 pycore/tools/mcu_bench.py
    make mcu-bench
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import time
import tomllib

from bench_report import write_benchmark

ROOT = pathlib.Path(__file__).resolve().parents[2]
RESEARCH = ROOT / "pycore" / "tools" / "cpython_baseline" / "benchmarks" / "research"
PEERS_TOML = ROOT / "pycore" / "tools" / "mcu_peers.toml"
PEERS_DIR = ROOT / "pycore" / "tools" / "mcu_bench" / "peers"
HART_JSON = ROOT / "pycore" / "docs" / "research_comparison.json"
LANGUAGES = ("c", "cpp", "micropython")


def load_boards(path: pathlib.Path = PEERS_TOML) -> list[dict]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    boards = data.get("board") or []
    for board in boards:
        missing = [k for k in ("id", "name", "cpu", "clock_mhz", "sram_kb", "flash_kb", "languages") if k not in board]
        if missing:
            raise SystemExit(f"mcu peer {board.get('id', '?')} missing {', '.join(missing)}")
        unknown = set(board["languages"]) - set(LANGUAGES)
        if unknown:
            raise SystemExit(f"{board['id']}: unknown languages {sorted(unknown)}")
    return boards


def load_peer_results(directory: pathlib.Path = PEERS_DIR) -> list[dict]:
    """JSON files a board run left behind. Missing directory means none yet."""
    if not directory.is_dir():
        return []
    rows = []
    for path in sorted(directory.glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, dict):
            payload = [payload]
        for row in payload:
            row["_file"] = path.name
            rows.append(row)
    return rows


def hart_exec_cycles(path: pathlib.Path = HART_JSON) -> dict[str, int]:
    """PyCore exec cycles from the last research comparison, keyed by program."""
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    out = {}
    for row in data.get("suite") or []:
        cycles = row.get("pyc_exec")
        if isinstance(cycles, int) and row.get("program"):
            out[row["program"]] = cycles
    return out


def locked_stdout() -> dict[str, str]:
    sys.path.insert(0, str(ROOT))
    from pycore.tests.test_research_benchmarks import _STDOUT
    return dict(_STDOUT)


def micropython_version(exe: str) -> str:
    proc = subprocess.run([exe, "-c", "import sys; print(sys.version)"],
                          capture_output=True, text=True, check=False)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def run_program(exe: str, path: pathlib.Path) -> tuple[str, float]:
    started = time.perf_counter()
    proc = subprocess.run([exe, str(path)], capture_output=True, text=True, check=False)
    elapsed = time.perf_counter() - started
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        tail = detail[-1] if detail else f"exit {proc.returncode}"
        return f"ERROR {tail}", elapsed
    return proc.stdout, elapsed


def _peer_cell(results: list[dict], board: str, language: str, program: str) -> str:
    hits = [r for r in results if r.get("board") == board and r.get("language") == language and r.get("program") == program]
    if not hits:
        return "not measured"
    row = hits[-1]
    if "seconds" in row:
        return f"{float(row['seconds']):.3f} s"
    if "cycles" in row:
        return f"{int(row['cycles']):,} cycles"
    return "recorded"


def render(report: dict) -> str:
    lines = [
        "# MCU benchmark comparison",
        "",
        "The research kernels are compared with MicroPython, not with CPython.",
        "The desktop CPython numbers stay in `research_comparison.md`.",
        "",
        f"Recorded {report['recorded']}.",
        f"Oracle: MicroPython `{report['micropython']}` ({report['micropython_version']}).",
        "",
        "MicroPython unix time is host wall time. It checks the checksum.",
        "It is not a microcontroller clock. PyCore time is hart exec cycles",
        "at the 1 GHz column of the last research comparison.",
        "",
        "## PyCore hart and MicroPython unix",
        "",
        "| program | result | checksum | PyCore exec | PyCore @ 1 GHz | MicroPython unix |",
        "| --- | --- | --- | ---: | ---: | ---: |",
    ]
    for row in report["programs"]:
        lines.append(
            f"| {row['program']} | {row['status']} | `{row['checksum']}` | "
            f"{_cycles(row.get('pycore_cycles'))} | {_ms(row.get('pycore_cycles'))} | "
            f"{row['micropython_s']:.3f} s |"
        )
    lines += [
        "",
        "## Similar MCUs",
        "",
        "Each board is a 32-bit microcontroller with on-chip SRAM of a few",
        "hundred kilobytes, and each one can run the same program in C, C++,",
        "and MicroPython. A cell is filled from",
        "`pycore/tools/mcu_bench/peers/*.json`. This run does not flash a board.",
        "",
        "| board | cpu | clock | SRAM | flash | C | C++ | MicroPython |",
        "| --- | --- | ---: | ---: | ---: | --- | --- | --- |",
    ]
    for board in report["boards"]:
        covered = []
        for language in LANGUAGES:
            n = sum(1 for r in report["peer_results"]
                    if r.get("board") == board["id"] and r.get("language") == language)
            covered.append(f"{n} program(s)" if n else "not measured")
        lines.append(
            f"| {board['name']} | {board['cpu']} | {board['clock_mhz']} MHz | "
            f"{board['sram_kb']} KB | {board['flash_kb']} KB | "
            + " | ".join(covered) + " |"
        )
    lines += ["", "Per program, when a board measurement exists:", ""]
    any_peer = False
    for row in report["programs"]:
        cells = []
        for board in report["boards"]:
            for language in LANGUAGES:
                cell = _peer_cell(report["peer_results"], board["id"], language, row["program"])
                if cell != "not measured":
                    cells.append(f"{board['id']} {language}: {cell}")
                    any_peer = True
        if cells:
            lines.append(f"- `{row['program']}` — " + "; ".join(cells))
    if not any_peer:
        lines.append("No board measurement is checked in yet.")
    lines += ["", "Board notes:", ""]
    for board in report["boards"]:
        lines.append(f"- **{board['name']}.** {board.get('note', '')}")
    lines.append("")
    return "\n".join(lines)


def _cycles(n: object) -> str:
    return f"{n:,}" if isinstance(n, int) else "—"


def _ms(n: object) -> str:
    if not isinstance(n, int):
        return "—"
    ms = n / 1_000_000
    return f"{ms:.2f} ms" if ms < 1000 else f"{ms / 1000:.3f} s"


def build_report(exe: str, programs: list[pathlib.Path] | None = None) -> dict:
    import datetime as dt
    boards = load_boards()
    peers = load_peer_results()
    hart = hart_exec_cycles()
    expected = locked_stdout()
    paths = programs if programs is not None else sorted(RESEARCH.glob("*.py"))
    rows = []
    for path in paths:
        stdout, elapsed = run_program(exe, path)
        want = expected.get(path.name)
        if stdout == want:
            status = "PASS"
        elif stdout.startswith("ERROR"):
            status = "ERROR"
        else:
            status = "MISMATCH"
        text = stdout if status != "PASS" else stdout.strip().replace("\n", " ")
        rows.append({
            "program": path.name,
            "status": status,
            "checksum": text if status == "PASS" else stdout.strip().splitlines()[-1] if stdout else "",
            "stdout": stdout,
            "expected": want,
            "pycore_cycles": hart.get(path.name),
            "micropython_s": elapsed,
        })
    return {
        "recorded": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "micropython": exe,
        "micropython_version": micropython_version(exe),
        "boards": boards,
        "peer_results": peers,
        "programs": rows,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--micropython", default=shutil.which("micropython") or "micropython")
    ap.add_argument("--doc", default=str(ROOT / "pycore" / "docs" / "mcu_comparison.md"))
    ap.add_argument("--json", default=str(ROOT / "build" / "mcu_bench" / "comparison.json"))
    args = ap.parse_args(argv)
    exe = args.micropython
    if shutil.which(exe) is None and not pathlib.Path(exe).is_file():
        print(f"mcu_bench: micropython not found ({exe})", file=sys.stderr)
        return 1
    started = time.perf_counter()
    report = build_report(exe)
    text = render(report)
    doc = pathlib.Path(args.doc)
    doc.parent.mkdir(parents=True, exist_ok=True)
    doc.write_text(text, encoding="utf-8")
    blob = pathlib.Path(args.json)
    blob.parent.mkdir(parents=True, exist_ok=True)
    blob.write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")
    failed = [r for r in report["programs"] if r["status"] != "PASS"]
    bench = write_benchmark(
        "micropython",
        [
            {
                "status": r["status"],
                "area": "research",
                "name": r["program"],
                "config": "micropython-unix",
                "cycles": r["pycore_cycles"],
                "wall_s": round(r["micropython_s"], 6),
                "detail": r["checksum"],
            }
            for r in report["programs"]
        ],
        elapsed_s=time.perf_counter() - started,
        passed=len(report["programs"]) - len(failed),
        failed=len(failed),
        note=("Comparison oracle is MicroPython unix, not CPython. "
              "`cycles` is the PyCore hart exec count. `wall_s` is MicroPython on this host. "
              "RP2040, STM32F411, and nRF52840 C / C++ / MicroPython cells are in the doc."),
    )
    print(text)
    print(f"wrote {doc}")
    print(f"benchmark: {bench}")
    if failed:
        for r in failed:
            print(f"FAIL {r['program']}: {r['status']} got {r['stdout']!r} expected {r['expected']!r}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
