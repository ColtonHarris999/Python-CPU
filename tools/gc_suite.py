#!/usr/bin/env python3
"""Run hardware tests one result per run, for the GC gates (planning/gc_plan.md §10).

The GC gates need every simulator result attributed exactly: test, top,
CACHE_EN, MEM_LATENCY, return or trap, tag/value or trap code, cycles, and
the GC counter line. The tests are the entries of
`pycore/programs/hw_tests.toml`; this module selects them, builds each image
once per process with `pycore/tools/hw_tests.py`'s runner, and runs each test
with the gate's plusargs ahead of the test's own (the first `+NAME=` wins in
`$value$plusargs`, so a gate's `+HEAP_DYN_BYTES=` replaces the manifest's).
Every run gets its own log under the gate's log directory.

Suites (`expand`):

- `hw`: every test outside the GC areas (what G0 records and G1 compares);
- `img`: the image tests of `hw` (kinds run/trap/stdout/coderam), the ones a
  collection can run in;
- `gc`, `gc-long`: the two GC areas; `gc-all`: both;
- any other area name, or a test name / glob.

Used by `tools/gc_baseline.py` (G0) and `tools/gc_acceptance.py` (G1, G4,
G5, G7, G11-G14).
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import fnmatch
import json
import os
import pathlib
import re
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pycore" / "tools"))
import hw_tests  # noqa: E402

GC_AREAS = ("gc", "gc-long")
IMAGE_KINDS = {"run", "trap", "stdout", "coderam"}

PASS_RE = re.compile(
    r"^PASS: (?P<prog>\S*) \S+ (?:tag=(?P<tag>\d+) value=0x(?P<value>[0-9a-fA-F]+)"
    r"|trapped code=(?P<trap>\d+)) cycles=(?P<cycles>\d+)"
)
CACHE_RE = re.compile(r"^tb_container: CACHE_EN=(\d+)")
GC_LINE_RE = re.compile(r"^GC collections=")
SIM_RE = re.compile(r"build/(sim_img_twocore|sim_img)/Vtb_container")
FAIL_MARKERS = ("[FAIL]", "%Error", "%Fatal", "*** [")


def merge_plusargs(base: str, extra: str) -> str:
    """Append `extra`, with a later `+NAME=value` replacing an earlier one.

    G7/G8 add `+HEAP_DYN_BYTES=` on top of a gate's own plusargs. Verilator
    `$value$plusargs` keeps the first match, so a second copy was ignored and
    G7 tortured `img_gc_stracc_split` at 16 KB instead of 2.5× peak.
    """
    toks: list[str] = []
    at: dict[str, int] = {}
    for src in (base, extra):
        for tok in src.split():
            if tok.startswith("+") and "=" in tok:
                key = tok.split("=", 1)[0]
                if key in at:
                    toks[at[key]] = tok
                    continue
                at[key] = len(toks)
            toks.append(tok)
    return " ".join(toks)


# --------------------------------------------------------------------------
# Selection
# --------------------------------------------------------------------------

def manifest(text: str | None = None) -> dict[str, hw_tests.Test]:
    """{name: Test} from the manifest (or from `text`, e.g. an older commit's)."""
    if text is None:
        tests = hw_tests.load_manifest()
    else:
        tmp = ROOT / "build" / "gc_suite" / "_manifest.toml"
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(text, encoding="utf-8")
        tests = hw_tests.load_manifest(tmp)
    return {t.name: t for t in tests}


def expand(suites: list[str], tests: dict[str, hw_tests.Test] | None = None) -> list[str]:
    """Test names selected by `suites`, in manifest order, no duplicates."""
    tests = tests if tests is not None else manifest()
    areas = {t.area for t in tests.values()}
    picked: set[str] = set()
    for s in suites:
        if s == "hw":
            hit = {n for n, t in tests.items() if t.area not in GC_AREAS}
        elif s == "img":
            hit = {n for n, t in tests.items() if t.area not in GC_AREAS and t.kind in IMAGE_KINDS}
        elif s == "gc-all":
            hit = {n for n, t in tests.items() if t.area in GC_AREAS}
        elif s in areas:
            hit = {n for n, t in tests.items() if t.area == s}
        else:
            hit = {n for n in tests if fnmatch.fnmatch(n, s)}
            if not hit:
                raise KeyError(f"no hw_tests.toml test or area matches {s!r}")
        picked |= hit
    return [n for n in tests if n in picked]


def top_of(name: str, tests: dict[str, hw_tests.Test] | None = None) -> str:
    """'single' or 'twocore' for a test name ('single' if unknown)."""
    tests = tests if tests is not None else manifest()
    t = tests.get(name)
    return t.core if t else "single"


# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------

@dataclass
class SimRun:
    target: str          # the hw_tests.toml test name
    index: int
    top: str
    cache_en: int
    mem_latency: int
    status: str  # pass | fail
    kind: str = ""  # return | trap
    tag_or_trap_code: int = -1
    value: str = ""
    cycles: int = -1
    prog: str = ""
    gc: dict[str, int] = field(default_factory=dict)
    detail: str = ""
    log: str = ""


def parse_gc_line(line: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for tok in line.split()[1:]:
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                out[k] = int(v)
            except ValueError:
                pass
    return out


def parse_log(target: str, text: str, cache_en: int, mem_latency: int,
              returncode: int, log: str, top: str = "") -> list[SimRun]:
    """One SimRun per simulator invocation found in a run's log."""
    runs: list[SimRun] = []
    cur_cache = cache_en
    fail_lines: list[str] = []
    pending_gc: dict[str, int] = {}
    for line in text.splitlines():
        m = SIM_RE.search(line)
        if m and not line.startswith("PASS"):
            top = "twocore" if m.group(1) == "sim_img_twocore" else "single"
        m = CACHE_RE.match(line)
        if m:
            cur_cache = int(m.group(1))
        if GC_LINE_RE.match(line):
            pending_gc = parse_gc_line(line)
            if runs and not runs[-1].gc:
                runs[-1].gc = pending_gc
                pending_gc = {}
        if any(marker in line for marker in FAIL_MARKERS):
            fail_lines.append(line.strip())
        m = PASS_RE.match(line)
        if m:
            run = SimRun(
                target=target, index=len(runs), top=top or "unknown",
                cache_en=cur_cache, mem_latency=mem_latency, status="pass",
                prog=m.group("prog"), cycles=int(m.group("cycles")), log=log,
            )
            if m.group("trap") is not None:
                run.kind = "trap"
                run.tag_or_trap_code = int(m.group("trap"))
            else:
                run.kind = "return"
                run.tag_or_trap_code = int(m.group("tag"))
                run.value = m.group("value").lower()
            if pending_gc:
                run.gc = pending_gc
                pending_gc = {}
            runs.append(run)
    if returncode != 0 or fail_lines or not runs:
        detail = "; ".join(fail_lines[:4]) or (
            f"exit {returncode}" if returncode else "no PASS line")
        runs.append(SimRun(
            target=target, index=len(runs), top=top or "unknown",
            cache_en=cur_cache, mem_latency=mem_latency, status="fail",
            detail=detail[:600], log=log,
        ))
    return runs


# --------------------------------------------------------------------------
# Running
# --------------------------------------------------------------------------

_prepared: set[str] = set()
_built: dict[str, tuple[bool, str]] = {}
_guard = threading.Lock()


def prepare(tests: list[hw_tests.Test]) -> None:
    """Build the simulators, firmware and generated fixtures once per process."""
    key = ",".join(sorted({t.core for t in tests} | {n for t in tests for n in t.needs}
                          | ({"make"} if any(t.kind == "make" for t in tests) else set())))
    if key in _prepared:
        return
    hw_tests.prepare(tests)
    _prepared.add(key)


def build(runner: hw_tests.Runner, t: hw_tests.Test) -> tuple[bool, str]:
    """Build `t`'s image once per process (the sources cannot change: the
    acceptance run is invalid if HEAD moves)."""
    with _guard:
        if t.name in _built:
            return _built[t.name]
    res = runner.build(t)
    with _guard:
        _built[t.name] = res
    return res


def run_tests(
    names: list[str],
    cache_en: int,
    mem_latency: int,
    log_dir: Path,
    jobs: int,
    plusargs: str = "",
    per_test: dict[str, str] | None = None,
    timeout: float = 6 * 3600,
    progress: bool = True,
    tests: dict[str, hw_tests.Test] | None = None,
) -> list[SimRun]:
    """Run each test once at (cache_en, mem_latency) with `plusargs` (and
    `per_test[name]`, merged over them) ahead of the test's own. `{leaf}` in
    the plusargs becomes the test name, so per-run artefacts never collide."""
    tests = tests if tests is not None else manifest()
    sel = [tests[n] for n in names]
    log_dir.mkdir(parents=True, exist_ok=True)
    if not sel:
        return []
    try:
        prepare(sel)
    except subprocess.CalledProcessError as exc:
        return [SimRun(target=t.name, index=0, top=t.core, cache_en=cache_en,
                       mem_latency=mem_latency, status="fail",
                       detail=f"prepare failed: {exc}") for t in sel]
    fw_hex = Path(os.environ.get("EXCORE_FW_HEX", str(hw_tests.DEFAULT_FW_HEX))).resolve()
    cfg = hw_tests.Config(f"cache={cache_en} lat={mem_latency}", cache_en, mem_latency)
    results: list[SimRun] = []
    lock = threading.Lock()
    done = 0
    t0 = time.time()

    def one(t: hw_tests.Test) -> list[SimRun]:
        plus = merge_plusargs(plusargs, (per_test or {}).get(t.name, "")).replace("{leaf}", t.name)
        for tok in plus.split():
            if tok.startswith("+GC_DUMP_EACH="):
                (ROOT / tok.split("=", 1)[1]).mkdir(parents=True, exist_ok=True)
        runner = hw_tests.Runner(fw_hex, sys.executable, plus)
        log = log_dir / f"{t.name}.log"
        ok, detail = build(runner, t)
        if not ok:
            log.write_text(detail + "\n", encoding="utf-8")
            return [SimRun(target=t.name, index=0, top=t.core, cache_en=cache_en,
                           mem_latency=mem_latency, status="fail", detail=detail, log=str(log))]
        try:
            cmd = runner.command(t, cfg)
        except (OSError, RuntimeError) as exc:
            log.write_text(f"{exc}\n", encoding="utf-8")
            return [SimRun(target=t.name, index=0, top=t.core, cache_en=cache_en,
                           mem_latency=mem_latency, status="fail", detail=str(exc), log=str(log))]
        try:
            res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
            text, rc = res.stdout + res.stderr, res.returncode
        except subprocess.TimeoutExpired as exc:
            text = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
            text += f"\n[FAIL] runner timeout after {timeout}s\n"
            rc = 124
        log.write_text(" ".join(cmd) + "\n" + text, encoding="utf-8")
        runs = parse_log(t.name, text, cache_en, mem_latency, rc, str(log), top=t.core)
        # hw_tests' own verdict too (stdout fixtures compare their output).
        passed, why, _ = runner.verdict(t, cfg, rc, text)
        if not passed and all(r.status == "pass" for r in runs):
            runs.append(SimRun(target=t.name, index=len(runs), top=t.core, cache_en=cache_en,
                               mem_latency=mem_latency, status="fail", detail=why, log=str(log)))
        return runs

    # Longest first, as hw_tests does, so the long fixtures do not start last.
    order = sorted(sel, key=lambda t: -(t.cycles or 0))
    with cf.ThreadPoolExecutor(max_workers=max(1, jobs)) as ex:
        for runs in ex.map(one, order):
            with lock:
                results.extend(runs)
                done += 1
                if progress and (done % 25 == 0 or done == len(sel)):
                    bad = sum(1 for r in results if r.status != "pass")
                    print(f"[gc_suite] CE={cache_en} LAT={mem_latency} {done}/{len(sel)} tests, "
                          f"{bad} failing, {time.time() - t0:.0f}s", flush=True)
    pos = {n: i for i, n in enumerate(names)}
    results.sort(key=lambda r: (pos.get(r.target, 1 << 30), r.index))
    return results


def results_to_json(results: list[SimRun]) -> list[dict]:
    return [asdict(r) for r in results]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("suites", nargs="+", help="suites, areas or test names/globs")
    ap.add_argument("--cache-en", type=int, default=1)
    ap.add_argument("--mem-latency", type=int, default=4)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--log-dir", default="build/gc_suite/logs")
    ap.add_argument("--out", default="")
    ap.add_argument("--plusargs", default="", help="simulator plusargs ahead of each test's own")
    ap.add_argument("--list", action="store_true", help="print the selected tests and exit")
    args = ap.parse_args()
    names = expand(args.suites)
    if args.list:
        print("\n".join(names))
        return 0
    results = run_tests(names, args.cache_en, args.mem_latency, Path(args.log_dir).resolve(),
                        args.jobs, args.plusargs)
    if args.out:
        Path(args.out).write_text(json.dumps(results_to_json(results), indent=1), encoding="utf-8")
    bad = [r for r in results if r.status != "pass"]
    for r in bad:
        print(f"FAIL {r.target}: {r.detail} ({r.log})")
    print(f"{len(results) - len(bad)} pass, {len(bad)} fail")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
