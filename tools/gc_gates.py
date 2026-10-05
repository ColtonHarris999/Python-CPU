"""Gate implementations for tools/gc_acceptance.py (planning/gc_plan.md §10.2).

Every gate returns a Result. A gate that cannot evaluate its evidence (missing
file, test, or unparsable output) returns `fail`: the runner fails closed.

The gates that run hardware tests take their test set and plusargs from the
`[gate.*]` tables of pycore/programs/hw_tests.toml and run them through
pycore/tools/hw_tests.py (`run_tests`). Each gate's runs log to
`<out>/runs/<gate>/<test>/sim-<config>.log`; `+GC_DUMP_EACH={out}` dumps go
to `<out>/runs/<gate>/<test>/<config>/gc<n>.gcdump`.
"""

from __future__ import annotations

import csv
import fnmatch
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pycore" / "tools"))
sys.path.insert(0, str(ROOT / "tools"))
import hw_tests  # noqa: E402
import gc_baseline  # noqa: E402

BASELINE_TSV = hw_tests.BASELINE
BASELINE_WARN = gc_baseline.WARN_FILE
BASELINE_AUX = gc_baseline.AUX_FILE
RECORD_ONLY = {"planning/gc_progress.md", "planning/gc_reviews.md"}
DEFAULT = hw_tests.config("1,4")


@dataclass
class Result:
    status: str
    summary: str
    lines: list[str] = field(default_factory=list)


@dataclass
class Context:
    root: pathlib.Path
    out: pathlib.Path
    mode: str
    jobs: int
    head: str
    cache: dict = field(default_factory=dict)
    mutant: int = 0              # G10: deliberate collector bug under test

    @property
    def full(self) -> bool:
        return self.mode == "full"


def run(cmd: list[str], cwd: pathlib.Path = ROOT, timeout: float | None = None) -> tuple[int, str]:
    try:
        res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return res.returncode, res.stdout + res.stderr
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        return 124, out + f"\n[timeout after {timeout}s]\n"


# --------------------------------------------------------------------------
# Running gate sets through hw_tests
# --------------------------------------------------------------------------

_TESTS: list[hw_tests.Test] = []


def all_tests() -> list[hw_tests.Test]:
    if not _TESTS:
        _TESTS.extend(hw_tests.load_manifest())
    return _TESTS


def by_name() -> dict[str, hw_tests.Test]:
    return {t.name: t for t in all_tests()}


def spec(ctx: Context, gate: str) -> dict:
    return hw_tests.gate_spec(gate, ctx.mode)


def matches(name: str, globs: list[str]) -> bool:
    return any(fnmatch.fnmatch(name, g) for g in globs)


def gate_runs(ctx: Context, gate: str, name: str | None = None, *,
              tests: list[hw_tests.Test] | None = None,
              configs: list[hw_tests.Config] | None = None,
              plusargs: str | None = None,
              extra: dict[str, str] | None = None) -> list[hw_tests.Result]:
    """Run a gate's test set (or `tests`) with its plusargs (or `plusargs`),
    plus `+GC_MUTANT=<n>` under G10. Logs go to <out>/runs/<name or gate>."""
    sp = spec(ctx, gate)
    if tests is None:
        tests = hw_tests.gate_tests(sp, all_tests())
    configs = configs or hw_tests.gate_configs(sp)
    plus = sp.get("plusargs", "") if plusargs is None else plusargs
    if ctx.mutant:
        plus = f"+GC_MUTANT={ctx.mutant} {plus}"
    out = ctx.out / "runs" / (name or gate)
    shutil.rmtree(out, ignore_errors=True)
    total = sum(len(hw_tests.configs_for(t, configs)) for t in tests)
    done = [0]
    label = name or gate

    def echo(line: str) -> None:
        done[0] += 1
        if not line.startswith(("PASS", "XFAIL")):
            print(f"[{label}] {line}", flush=True)
        elif done[0] % 50 == 0 or done[0] == total:
            print(f"[{label}] {done[0]}/{total} runs", flush=True)

    return hw_tests.run_tests(tests, configs, jobs=ctx.jobs, plusargs=plus, extra=extra,
                              out=out, echo=echo)


def run_logs(ctx: Context, prefix: str, exclude: tuple[str, ...] = ()) -> dict[str, list[pathlib.Path]]:
    """test -> logs of every gate run directory whose name starts with
    `prefix` ("" for all), skipping directories named in `exclude`."""
    out: dict[str, list[pathlib.Path]] = {}
    runs = ctx.out / "runs"
    if not runs.is_dir():
        return out
    for d in sorted(runs.iterdir()):
        if not d.is_dir() or not d.name.startswith(prefix) or d.name in exclude:
            continue
        for p in sorted(d.glob("*/sim-*.log")):
            out.setdefault(p.parent.name, []).append(p)
    return out


def failures(results: list[hw_tests.Result]) -> list[str]:
    out = []
    for r in results:
        if not r.ok:
            why = "passed but is marked xfail" if r.passed else r.detail
            out.append(f"FAIL {r.test.name} [{r.config.label}]: {why}")
    return out


# --------------------------------------------------------------------------
# Baseline helpers
# --------------------------------------------------------------------------

def load_baseline() -> list[dict[str, str]]:
    with BASELINE_TSV.open(encoding="utf-8") as fh:
        return list(csv.DictReader((ln for ln in fh if not ln.startswith("#")), delimiter="\t"))


def keyed(rows: list[dict[str, str]]) -> dict[tuple, dict[str, str]]:
    """Key rows by (test, cache_en, mem_latency, index)."""
    return {(r["test"], str(r["cache_en"]), str(r["mem_latency"]), str(r["index"])): r for r in rows}


def baseline_commit() -> str:
    first = BASELINE_TSV.read_text(encoding="utf-8").splitlines()[0]
    m = re.search(r"at ([0-9a-f]{40})", first)
    return m.group(1) if m else ""


def program_files(t: hw_tests.Test) -> list[str]:
    """The Python source a test's image is built from. (Hex fixtures are
    regenerated by their `needs` generators on every run, on main too.)"""
    if t.kind in hw_tests.IMAGE_KINDS:
        return [str(t.source.relative_to(ROOT))]
    return []


_CHANGED: dict[str, set[str]] = {}


def changed_since_baseline() -> set[str]:
    """Tests whose program file differs from the baseline commit: G0 measured
    a different program, so their rows are not compared."""
    if "names" not in _CHANGED:
        sha = baseline_commit()
        rc, out = run(["git", "diff", "--name-only", sha, "--", "pycore/programs"]) if sha else (1, "")
        files = set(out.split()) if rc == 0 else set()
        _CHANGED["names"] = {t.name for t in all_tests() if set(program_files(t)) & files}
    return _CHANGED["names"]


def compare_to_baseline(results: list[hw_tests.Result], check_cycles: bool = True) -> list[str]:
    """Differences between `results` and the G0 rows of the same tests and
    configurations (a test or config without G0 rows, or whose program
    changed since the baseline commit, is not compared)."""
    changed = changed_since_baseline() if results else set()
    results = [r for r in results if r.test.name not in changed]
    if not results:
        return []
    rows = load_baseline()
    want = {(r.test.name, str(r.config.cache_en), str(r.config.latency)) for r in results}
    base = keyed([b for b in rows if (b["test"], b["cache_en"], b["mem_latency"]) in want])
    got = keyed([row for r in results for row in gc_baseline.rows_for(r)])
    diffs = []
    fields = ["kind", "code", "value"] + (["cycles"] if check_cycles else [])
    for k, b in base.items():
        g = got.get(k)
        if g is None:
            diffs.append(f"missing run {k}")
            continue
        for f in fields:
            if b[f] != g[f]:
                diffs.append(f"{k}: {f} baseline={b[f]} got={g[f]}")
    return diffs


def g0_cycles(test: str, cfg: hw_tests.Config = DEFAULT) -> int | None:
    for b in load_baseline():
        if (b["test"], b["cache_en"], b["mem_latency"], b["index"]) == (
                test, str(cfg.cache_en), str(cfg.latency), "0") and b["kind"] != "fail":
            return int(b["cycles"])
    return None


# --------------------------------------------------------------------------
# G0 baseline
# --------------------------------------------------------------------------

def gate_G0(ctx: Context) -> Result:
    lines = []
    for p in (BASELINE_TSV, BASELINE_WARN, BASELINE_AUX):
        if not p.is_file():
            return Result("fail", f"missing {p.relative_to(ROOT)} (run tools/gc_baseline.py)")
    rows = load_baseline()
    if not rows:
        return Result("fail", "baseline TSV has no rows")
    # Coverage is judged against the tests that existed at the baseline
    # commit; GC tests added later have no G0 value by construction.
    first = BASELINE_TSV.read_text(encoding="utf-8").splitlines()[0]
    m = re.search(r"at ([0-9a-f]{40})", first)
    if not m:
        return Result("fail", "baseline TSV header does not name its commit")
    sha = m.group(1)
    rc, manifest = run(["git", "show", f"{sha}:pycore/programs/hw_tests.toml"])
    if rc != 0:
        return Result("fail", f"cannot read hw_tests.toml at baseline commit {sha[:10]}")
    rc, _ = run(["git", "merge-base", "--is-ancestor", sha, ctx.head])
    if rc != 0:
        return Result("fail", f"baseline commit {sha[:10]} is not an ancestor of HEAD")
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "hw_tests.toml"
        path.write_text(manifest, encoding="utf-8")
        base_tests = hw_tests.load_manifest(path)
    need = [(t.name, str(c.cache_en), str(c.latency))
            for t in base_tests for c in hw_tests.configs_for(t, gc_baseline.CONFIGS)]
    have = {(r["test"], r["cache_en"], r["mem_latency"]) for r in rows}
    missing = [n for n in need if n not in have]
    fails = [r for r in rows if r["kind"] == "fail"]
    aux = BASELINE_AUX.read_text(encoding="utf-8").splitlines()[1:]
    aux_fail = [a for a in aux if not a.endswith("\tpass")]
    lines.append(f"{len(rows)} baseline rows at {sha[:10]}; {len(need)} (test, config) pairs required")
    lines += [f"missing: {x}" for x in missing[:50]]
    lines += [f"pre-existing failure: {f['test']} {f['cache_en']}/{f['mem_latency']}" for f in fails]
    lines += [f"aux step failed at G0: {a}" for a in aux_fail]
    # Every pre-existing failure must be listed in the ledger.
    ledger = (ROOT / "planning" / "gc_progress.md").read_text(encoding="utf-8")
    unlisted = sorted({f["test"] for f in fails if f["test"] not in ledger})
    if missing:
        return Result("fail", f"baseline misses {len(missing)} test/config pairs", lines)
    if unlisted:
        return Result("fail", f"{len(unlisted)} pre-existing failures not listed in the ledger", lines)
    return Result("pass", f"{len(rows)} rows at {sha[:10]} cover all {len(need)} test/config pairs; "
                  f"{len(fails)} pre-existing failures", lines)


# --------------------------------------------------------------------------
# G1 GC_EN=0 transparency
# --------------------------------------------------------------------------

def gate_G1(ctx: Context) -> Result:
    if not BASELINE_TSV.is_file():
        return Result("fail", f"missing {BASELINE_TSV.relative_to(ROOT)}")
    res = gate_runs(ctx, "G1")
    if not res:
        return Result("fail", "G1 selected no tests (empty baseline?)")
    diffs = compare_to_baseline(res)
    changed = sorted(changed_since_baseline() & {r.test.name for r in res})
    lines = [f"{len(res)} runs over {len({r.test.name for r in res})} tests, {len(diffs)} differences; "
             f"not compared (program changed since G0): {', '.join(changed) or 'none'}"]
    problems = list(diffs)
    if ctx.full:
        for step in gc_baseline.AUX_STEPS:
            rc, out = run(["make", step, f"TEST_JOBS={ctx.jobs}"])
            (ctx.out / f"G1_aux_{step}.log").write_text(out, encoding="utf-8")
            lines.append(f"aux {step}: {'pass' if rc == 0 else 'fail'}")
            if rc != 0:
                problems.append(f"aux step {step} failed")
    lines += problems[:200]
    if problems:
        return Result("fail", f"{len(problems)} differences from G0 with GC_EN=0", lines)
    return Result("pass", f"{len(res)} runs: every result and cycle count identical to G0 with GC_EN=0",
                  lines)


# --------------------------------------------------------------------------
# G2 oracle self-validation
# --------------------------------------------------------------------------

def gate_G2(ctx: Context) -> Result:
    test = ROOT / "pycore" / "tests" / "test_gc_model.py"
    if not test.is_file():
        return Result("fail", "pycore/tests/test_gc_model.py does not exist")
    rc, out = run([sys.executable, "-m", "unittest", "-v", "pycore.tests.test_gc_model"],
                  timeout=3600)
    lines = out.splitlines()[-80:]
    m = re.search(r"G2 seeds=(\d+) directed=(\d+) rows=(\d+)/(\d+)", out)
    if rc != 0:
        return Result("fail", "test_gc_model failed", lines)
    if not m:
        return Result("fail", "test_gc_model did not report its seed/row coverage", lines)
    seeds, directed, rows_hit, rows_all = map(int, m.groups())
    if seeds < 500 or rows_hit != rows_all:
        return Result("fail", f"coverage too low: seeds={seeds} rows={rows_hit}/{rows_all}", lines)
    return Result("pass", f"oracle agrees with Python reachability on {seeds} seeds, "
                  f"{directed} directed cases, {rows_hit}/{rows_all} §4.1 rows", lines)


# --------------------------------------------------------------------------
# G3 engine unit testbench
# --------------------------------------------------------------------------

def gate_G3(ctx: Context) -> Result:
    rc, out = run(["make", "pycore-gc", f"TEST_JOBS={ctx.jobs}", "GC_UNIT_SEEDS=200",
                   f"GC_UNIT_ARGS=--mutant {ctx.mutant}"], timeout=4 * 3600)
    (ctx.out / "G3_run.log").write_text(out, encoding="utf-8")
    lines = out.splitlines()[-40:]
    m = re.search(r"G3 seeds=(\d+) configs=(\d+) runs=(\d+) failing=(\d+) overflow_guard=(\S+) "
                  r"spill_refill=(\S+)", out)
    if not m:
        return Result("fail", "make pycore-gc produced no G3 summary", lines)
    seeds, configs, runs_n, failing = map(int, m.groups()[:4])
    if rc != 0 or failing or seeds < 200 or configs < 6 or m.group(5) != "ok" or m.group(6) != "ok":
        return Result("fail", f"G3: {m.group(0)}", lines)
    return Result("pass", f"{seeds} seeds x {configs} memory configs ({runs_n} runs) exact vs gc_model; "
                  "overflow guard fires; spill/refill exercised", lines)


# --------------------------------------------------------------------------
# G4 oracle differential at every collection (G5/G6 ride along)
# --------------------------------------------------------------------------

def check_dump_file(path: str) -> tuple[str, list[str]]:
    import gc_model  # noqa: PLC0415
    try:
        return path, gc_model.check_dump(gc_model.load_dump(pathlib.Path(path)))
    except Exception as exc:  # noqa: BLE001 - an unreadable dump is a failure
        return path, [f"unreadable dump: {exc}"]


def dumps_of(results: list[hw_tests.Result]) -> list[pathlib.Path]:
    """Dumps of every run except expected failures (an xfail test's broken
    collection is the known bug)."""
    out = []
    for r in results:
        if r.out is not None and not r.expected_fail:
            out += sorted(r.out.glob("*.gcdump"))
    return out


def check_dumps(ctx: Context, dumps: list[pathlib.Path]) -> tuple[int, list[str]]:
    import concurrent.futures as cf
    problems = []
    with cf.ProcessPoolExecutor(max_workers=max(1, ctx.jobs)) as ex:
        for path, probs in ex.map(check_dump_file, [str(d) for d in dumps], chunksize=4):
            p = pathlib.Path(path)
            for x in probs[:4]:
                problems.append(f"{p.relative_to(ctx.out) if p.is_relative_to(ctx.out) else p}: {x}")
    return len(dumps), problems


def gate_G4(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    res = gate_runs(ctx, "G4")
    if not res:
        return Result("fail", "G4 selected no tests")
    n, probs = check_dumps(ctx, dumps_of(res))
    bad = failures(res)
    collected = sum(1 for r in res if r.gc.get("collections", 0))
    lines.append(f"G4: {len(res)} runs, {len(bad)} failing, {collected} collected, {n} dumps, "
                 f"{len(probs)} oracle problems")
    problems += bad + probs
    total = n
    if n == 0:
        problems.append("G4 produced no dumps")
    if ctx.full:
        ex = gate_runs(ctx, "G4-exit")
        n2, probs2 = check_dumps(ctx, dumps_of(ex))
        total += n2
        bad2 = failures(ex)
        # Every clean-return image test must have collected at least once.
        no_dump = [f"{r.test.name} [{r.config.label}]" for r in ex
                   if r.passed and r.sims and r.sims[-1].kind == "return"
                   and not (r.out and any(r.out.glob("*.gcdump")))]
        lines.append(f"G4-exit: {len(ex)} runs, {len(bad2)} failing, {n2} dumps, "
                     f"{len(probs2)} oracle problems, {len(no_dump)} without a collection")
        problems += bad2 + probs2 + [f"no collection in {x}" for x in no_dump]
        # Coherent-dump self-test (plan §6.1): the same test dumped with
        # caches on and off must show identical heap, metadata and roots.
        compared = 0
        for r in ex:
            if r.config.slug != "c1l4" or r.out is None:
                continue
            other = r.out.parent / "c0l4"
            for da in sorted(r.out.glob("*.gcdump")):
                db = other / da.name
                if not db.exists():
                    problems.append(f"coherent-dump self-test: {db.relative_to(ctx.out)} missing")
                    continue
                ka = [ln for ln in da.read_text().splitlines() if ln.startswith(("mem ", "root "))]
                kb = [ln for ln in db.read_text().splitlines() if ln.startswith(("mem ", "root "))]
                compared += 1
                if ka != kb:
                    problems.append(f"coherent-dump self-test: {r.test.name}/{da.name} differs "
                                    "between CACHE_EN=1 and 0")
        lines.append(f"coherent-dump self-test: {compared} dump pairs compared")
        if compared == 0:
            problems.append("coherent-dump self-test compared nothing")
    lines += problems[:300]
    if problems:
        return Result("fail", f"{len(problems)} problems over {total} dumps", lines)
    return Result("pass", f"{total} dumps exact vs gc_model (free set, roots, counters, run list) "
                  f"over {len(res)} runs", lines)


# --------------------------------------------------------------------------
# G5 shadow-heap checker, G6 in-RTL invariants
# --------------------------------------------------------------------------

# Logs that are not collector-on gate runs: G1 runs with the collector off,
# G5 forces a shadow violation on purpose.
NOT_GC_RUNS = ("G1", "G5")


def gc_logs(ctx: Context) -> list[pathlib.Path]:
    """Logs of every GC-enabled run this acceptance run made so far."""
    return [p for ps in run_logs(ctx, "", NOT_GC_RUNS).values() for p in ps]


def gate_G5(ctx: Context) -> Result:
    lines = []
    problems = []
    if not ctx.mutant:
        for r in gate_runs(ctx, "G5"):
            fired = "[GC-SHADOW] use-after-free: master=selftest" in r.text()
            lines.append(f"self-test on {r.test.name}: {'fired' if fired else 'DID NOT FIRE'} "
                         f"({'stopped' if not r.passed else 'ran to completion'})")
            if not fired or r.passed:
                problems.append(f"shadow self-test did not fire on {r.test.name}")
    logs = gc_logs(ctx)
    hits = [p for p in logs if "[GC-SHADOW] use-after-free" in p.read_text(encoding="utf-8", errors="replace")]
    lines.append(f"{len(logs)} GC gate logs scanned, {len(hits)} with a shadow violation")
    problems += [f"shadow violation in {p.relative_to(ctx.out)}" for p in hits]
    if not logs:
        problems.append("no GC gate runs to scan (run G4 first)")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} shadow-checker problems", lines)
    return Result("pass", f"self-test fires; no use-after-free in {len(logs)} GC gate runs", lines)


def gate_G6(ctx: Context) -> Result:
    logs = gc_logs(ctx)
    lines = []
    fired = []
    collections = 0
    for p in logs:
        text = p.read_text(encoding="utf-8", errors="replace")
        if "[GC-INV]" in text:
            fired.append(p)
        collections += hw_tests.parse_gc_line(text).get("collections", 0)
    lines.append(f"{len(logs)} GC gate logs, {collections} collections, {len(fired)} with [GC-INV]")
    lines += [f"invariant fired: {p.relative_to(ctx.out)}" for p in fired]
    if fired:
        return Result("fail", f"{len(fired)} runs tripped an in-RTL invariant", lines)
    if collections == 0:
        return Result("fail", "no collections ran under the invariants", lines)
    return Result("pass", f"no invariant fired over {collections} collections in {len(logs)} runs", lines)


# --------------------------------------------------------------------------
# G7 torture
# --------------------------------------------------------------------------

PERF_RE = re.compile(r"^PERF instr=(\d+)", re.M)
LOG_LIVE_RE = re.compile(r"^\[GC-LOG\] .*\blive=(\d+)", re.M)
TB_MAX_SCALE = 1 << 20      # the testbench clamps MAX_CYCLES * scale


def prev_prime(n: int) -> int:
    def prime(k: int) -> bool:
        return k >= 2 and all(k % d for d in range(2, int(k ** 0.5) + 1))
    while n > 2 and not prime(n):
        n -= 1
    return max(n, 1)


def default_logs(ctx: Context, prefix: str) -> dict[str, str]:
    """test -> text of its CACHE_EN=1 MEM_LATENCY=4 log in gate run
    directories starting with `prefix` (later directories win)."""
    out = {}
    for name, logs in run_logs(ctx, prefix).items():
        for p in logs:
            if p.name == f"sim-{DEFAULT.slug}.log":
                out[name] = p.read_text(encoding="utf-8", errors="replace")
    return out


def peak_live(ctx: Context, test: str, extra_logs: list[str]) -> int:
    """Peak occupancy the mutator needed, from G4 dumps and GC-LOG lines.

    A dump's `meta live` is the reachable set *after* the collection. Compile
    scratch and other dropped temps sit in `meta reclaimed`. G7 (a)/(c) shrink
    the heap to 2.5x this peak (§10.2), so using only post-collect live
    MEM_FAULTs programs whose high-water mark is the pre-collect occupancy.
    """
    peak = 0
    runs = ctx.out / "runs"
    if runs.is_dir():
        for p in runs.glob(f"G4*/{test}/*/*.gcdump"):
            live = rec = 0
            for ln in p.read_text(errors="replace").splitlines():
                if ln.startswith("meta live "):
                    live = int(ln.split()[2])
                elif ln.startswith("meta reclaimed "):
                    rec = int(ln.split()[2])
                elif ln.startswith(("root ", "mem ")):
                    break
            peak = max(peak, live + rec)
    for text in extra_logs:
        peak = max([peak] + [int(x) for x in LOG_LIVE_RE.findall(text)])
    return peak


def scan_gc_problems(results: list[hw_tests.Result]) -> list[str]:
    out = []
    for r in results:
        text = r.text()
        if "[GC-SHADOW]" in text:
            out.append(f"{r.test.name}: shadow-heap violation")
        if "[GC-INV]" in text:
            out.append(f"{r.test.name}: in-RTL invariant fired")
    return out


def gate_G7(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    sp = spec(ctx, "G7")
    tests = hw_tests.gate_tests(sp, all_tests())
    recipe_heap = sp.get("recipe_heap", [])
    bump_cursor = sp.get("bump_cursor", [])
    base_names = hw_tests.baseline_names()
    gc_on = "+GC_EN=1 +GC_ROOT_STASH=1 +MAX_CYCLES_SCALE=40"
    # Instruction counts and cycles from this run's G4 logs; measure if absent.
    g4 = default_logs(ctx, "G4")
    missing = [t for t in tests if not PERF_RE.search(g4.get(t.name, ""))]
    if missing:
        gate_runs(ctx, "G7", "G7_count", tests=missing, configs=[DEFAULT], plusargs=gc_on)
        g4.update(default_logs(ctx, "G7_count"))
    instr = {t.name: int(m.group(1)) for t in tests if (m := PERF_RE.search(g4.get(t.name, "")))}
    cycles = {t.name: int(m.group(1)) for t in tests
              if (m := re.search(r"cycles=(\d+)", g4.get(t.name, "")))}
    no_count = [t.name for t in tests if t.name not in instr or t.name not in cycles]
    problems += [f"no instruction/cycle count for {x}" for x in no_count]
    run_set = [t for t in tests if t.name not in no_count]
    quick_set = {t.name for t in hw_tests.gate_tests(hw_tests.gate_spec("G7", "quick"), all_tests())}

    def k_for(name: str) -> int:
        if name in quick_set or instr[name] < 50:
            return 1
        return prev_prime(instr[name] // 50)

    mode_b_logs: dict[str, str] = {}
    for mode in sp.get("modes", ["a"]):
        extra: dict[str, str] = {}
        poison = " +GC_POISON=1" if mode == "c" else ""
        for t in run_set:
            n = t.name
            if matches(n, bump_cursor):
                extra[n] = f"+MAX_CYCLES_SCALE={TB_MAX_SCALE}{poison}"
            elif mode == "b":
                k = k_for(n)
                want = instr[n] // max(k, 1)
                scale = (cycles[n] + (want + 2) * 400_000) // max(1, cycles[n]) + 2
                extra[n] = f"+GC_AT_BOUNDARY_EVERY={k} +MAX_CYCLES_SCALE={min(scale, TB_MAX_SCALE)}"
            elif matches(n, recipe_heap):
                extra[n] = f"+GC_EVERY_N_RUNS=1 +MAX_CYCLES_SCALE={TB_MAX_SCALE}{poison}"
            else:
                peak = peak_live(ctx, n, [mode_b_logs.get(n, "")])
                # 2.5x peak: 2x still OOMs G8 seed 2 after EVERY_N_RUNS=1
                # first-fit (largest hole 11 KB, trap 7). 2.25x passes.
                heap = (max(peak * 5 // 2, peak + 8192) + 63) & ~63
                extra[n] = (f"+GC_EVERY_N_RUNS=1 +HEAP_DYN_BYTES={heap} "
                            f"+MAX_CYCLES_SCALE={TB_MAX_SCALE}{poison}")
        name = f"G7_{mode}"
        res = gate_runs(ctx, "G7", name, tests=run_set, configs=[DEFAULT], extra=extra)
        by_test = {r.test.name: r for r in res}
        if mode == "b":
            mode_b_logs = {r.test.name: r.text() for r in res}
        # Golden results (cycles differ by design); GC tests check their own
        # expected value.
        base_res = [r for r in res if r.test.name in base_names]
        diffs = compare_to_baseline(base_res, check_cycles=False)
        bad = failures([r for r in res if r.test.name not in base_names])
        n_dumps, probs = check_dumps(ctx, dumps_of(res))
        gcp = scan_gc_problems(res)
        few = []
        if mode == "b":
            for t in run_set:
                got = hw_tests.parse_gc_line(mode_b_logs.get(t.name, "")).get("collections", 0)
                # N instructions produce N-1 FETCH transitions from a
                # completed instruction.
                need = min(50, max(instr[t.name] - 1, 1))
                r = by_test.get(t.name)
                if not matches(t.name, bump_cursor) and got < need and r and r.passed:
                    few.append(f"{t.name}: {got} boundary collections (K={k_for(t.name)}, "
                               f"{instr[t.name]} instr)")
        lines.append(f"{name}: {len(res)} runs, {len(diffs)} golden diffs, {len(bad)} failing GC tests, "
                     f"{n_dumps} dumps, {len(probs)} oracle problems, {len(gcp)} shadow/invariant, "
                     f"{len(few)} under-collected")
        problems += [f"{name}: {d}" for d in diffs + bad + probs + gcp + few]
    lines += problems[:300]
    if problems:
        return Result("fail", f"{len(problems)} torture problems", lines)
    return Result("pass", f"modes {','.join(sp.get('modes', ['a']))} over {len(run_set)} tests: "
                  "goldens equal, dumps exact, no shadow/invariant failure", lines)


# --------------------------------------------------------------------------
# G8 randomized differential fuzzing
# --------------------------------------------------------------------------

def gate_G8(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    sp = spec(ctx, "G8")
    n = int(sp.get("seeds", 50))
    for top in sp.get("tops", ["single"]):
        cmd = [sys.executable, str(ROOT / "pycore" / "tools" / "gc_fuzz.py"), "--seeds", f"0..{n - 1}",
               "--top", top, "--jobs", str(ctx.jobs), "--out", str(ctx.out / "G8")]
        if ctx.mutant:
            cmd += ["--mutant", str(ctx.mutant)]
        rc, out = run(cmd, timeout=24 * 3600)
        (ctx.out / f"G8_{top}.log").write_text(out, encoding="utf-8")
        m = re.search(r"^G8 top=\S+ seeds=(\d+) failing=(\d+)", out, re.M)
        cov = re.search(r"^G8 coverage (.*)$", out, re.M)
        lines += [ln for ln in out.splitlines() if ln.startswith(("G8 ", "[gc_fuzz] FAIL"))][:60]
        if not m:
            problems.append(f"{top}: gc_fuzz.py produced no summary (rc={rc})")
            continue
        if int(m.group(1)) < n or int(m.group(2)) or rc != 0:
            problems.append(f"{top}: {m.group(0)}")
        if not cov or "missing" in cov.group(1):
            problems.append(f"{top}: coverage incomplete: {cov.group(1) if cov else 'no report'}")
    if problems:
        return Result("fail", "; ".join(problems[:4]), lines + problems)
    return Result("pass", f"{n} seeds per top ({', '.join(sp.get('tops', ['single']))}), "
                  "0 failures, coverage complete", lines)


# --------------------------------------------------------------------------
# G9 allocation-site abort coverage
# --------------------------------------------------------------------------

def site_texts(ctx: Context) -> dict[str, list[str]]:
    """Per top: logs of passing G7 runs and passing G8 seeds."""
    out: dict[str, list[str]] = {"single": [], "twocore": []}
    tests = by_name()
    for name, logs in run_logs(ctx, "G7_", ("G7_count",)).items():
        t = tests.get(name)
        if t is None:
            continue
        for p in logs:
            text = p.read_text(encoding="utf-8", errors="replace")
            if hw_tests.parse_sims(text) and "[FAIL]" not in text:
                out[t.core].append(text)
    g8 = ctx.out / "G8"
    for top in ("single", "twocore"):
        rj = g8 / f"results_{top}.json"
        if not rj.exists():
            continue
        for rec in json.loads(rj.read_text()):
            if rec["problems"]:
                continue
            d = g8 / top / f"s{rec['seed']}"
            for name in ("measure.log", "shrunk.log"):
                if (d / name).exists():
                    out[top].append((d / name).read_text(encoding="utf-8", errors="replace"))
    return out


def gate_G9(ctx: Context) -> Result:
    import gc_sites  # noqa: PLC0415
    lines: list[str] = []
    problems: list[str] = []
    texts = site_texts(ctx)
    for top in ("single", "twocore"):
        wanted = gc_sites.rows_for(top)
        rows, unmapped = gc_sites.aggregate(texts[top])
        lines.append(f"{top}: {len(texts[top])} passing runs")
        lines += [f"  {ln}" for ln in gc_sites.table(rows, wanted)]
        for key, nums in sorted(unmapped.items()):
            if nums[1]:
                lines.append(f"  unmapped key {key}: allocs={nums[0]} aborts={nums[1]}")
        for r in wanted:
            a = rows.get(r, [0, 0, 0, 0])
            if min(a[1], a[2], a[3]) < 10:
                problems.append(f"{top} row {r}: aborts={a[1]} collects={a[2]} redispatch={a[3]} (< 10)")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} site-coverage problems", lines)
    return Result("pass", "every integrated §1.3 row has >= 10 abort/collect/re-dispatch events", lines)


# --------------------------------------------------------------------------
# G10 mutation testing
# --------------------------------------------------------------------------

def gate_G10(ctx: Context) -> Result:
    rc, out = run([sys.executable, str(ROOT / "tools" / "gc_mutants.py"), "--jobs", str(ctx.jobs),
                   "--out", str(ctx.out / "G10")], timeout=48 * 3600)
    (ctx.out / "G10_run.log").write_text(out, encoding="utf-8")
    lines = [ln for ln in out.splitlines() if ln.startswith(("[gc_mutants]", "G10 "))]
    if re.search(r"^G10 baseline failed", out, re.M):
        return Result("fail", "quick gates fail without a mutant; kills are meaningless", lines)
    m = re.search(r"^G10 mutants=(\d+) killed=(\d+) survived=\[(.*)\] pending=\[(.*)\]$", out, re.M)
    if not m:
        return Result("fail", "tools/gc_mutants.py produced no G10 summary", lines[-40:])
    n, killed = int(m.group(1)), int(m.group(2))
    survived = [x.strip() for x in m.group(3).split(",") if x.strip()]
    pending = [x.strip() for x in m.group(4).split(",") if x.strip()]
    # 37 plan mutants plus our own (plan §10.2 G10 asks for at least five):
    # every mutant in tools/gc_mutants.py, 1-49, must run and be killed.
    if survived or n < 49 or killed != n or pending:
        return Result("fail", m.group(0), lines)
    return Result("pass", f"all {n} mutants killed", lines)


# --------------------------------------------------------------------------
# G11 steady state
# --------------------------------------------------------------------------

GC_LOG_RE = re.compile(r"^\[GC-LOG\] n=(\d+) .*?reason=\s*(\S+) live=(\d+) free=(\d+)", re.M)


def gate_G11(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    sp = spec(ctx, "G11")
    res = gate_runs(ctx, "G11")
    if not res:
        return Result("fail", "no steady-state tests selected", lines)
    for r in res:
        n = r.test.name
        logs = [(int(i), why, int(live), int(free)) for i, why, live, free in GC_LOG_RE.findall(r.text())]
        # A compile loop collects explicitly once per iteration; its other
        # collections land mid-compile and measure the compiler's scratch.
        if any(why == "explicit" for _, why, _, _ in logs) and (n.endswith("compile") or "compile-" in n):
            logs = [e for e in logs if e[1] == "explicit"]
        limit = int(sp.get("compile_limit", 16384) if n.startswith("gc-compile-") else sp.get("limit", 1024))
        if not r.ok:
            problems.append(f"{n}: FAIL {r.detail}")
            continue
        if len(logs) < 10:
            problems.append(f"{n}: {len(logs)} collections (< 10)")
            continue
        tail = logs[len(logs) // 2:]
        spread = max(e[2] for e in tail) - min(e[2] for e in tail)
        drift = logs[0][3] - logs[-1][3]
        lines.append(f"{n}: {len(logs)} collections, live spread {spread} B over the last half, "
                     f"free first {logs[0][3]} last {logs[-1][3]}")
        if spread > limit:
            problems.append(f"{n}: live spread {spread} B > {limit} B")
        if drift > 1024:
            problems.append(f"{n}: free bytes fell by {drift} B")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} steady-state problems", lines)
    return Result("pass", f"all {len(res)} steady-state tests plateau", lines)


# --------------------------------------------------------------------------
# G12 architectural configurations
# --------------------------------------------------------------------------

def gate_G12(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    if not ctx.full:
        return Result("fail", "G12 runs only in MODE=full", lines)
    sp = spec(ctx, "G12")
    res = gate_runs(ctx, "G12")
    if not res:
        return Result("fail", "G12 selected no tests", lines)
    n, probs = check_dumps(ctx, dumps_of(res))
    bad = failures(res)
    gcp = scan_gc_problems(res)
    lines.append(f"G12: {len(res)} runs, {len(bad)} failing, {n} dumps, {len(probs)} oracle, "
                 f"{len(gcp)} shadow/invariant")
    problems += bad + probs + gcp
    # test-caching's configurations with the collector on everywhere.
    tests = [t for t in all_tests() if t.area != "gc-long"]
    cres = gate_runs(ctx, "G12", "G12_caching", tests=tests,
                     configs=[hw_tests.Config(*c) for c in hw_tests.CACHING_CONFIGS],
                     plusargs=sp.get("caching_plusargs", ""))
    cbad = failures(cres)
    lines.append(f"G12_caching: {len(cres)} runs, {len(cbad)} failing")
    problems += cbad
    if problems:
        return Result("fail", f"{len(problems)} G12 problems", lines + problems[:80])
    return Result("pass", "G4 on [gc]+[gc-long] at every (CACHE_EN, MEM_LATENCY); "
                  "test-caching with GC_EN=1 green", lines)


# --------------------------------------------------------------------------
# G13 performance
# --------------------------------------------------------------------------

BENCH = {
    "full": "gc-bench-full",
    "churn": "gc-bench-churn",
    "deep": "gc-bench-deep",
    "wide": "gc-bench-wide",
}
COMPILE_LOOP = "gc-compile-loop"
GC_KEYS = ["collections", "live", "free", "largest", "max_pause", "total_pause",
           "mark_cyc", "sweep_cyc", "port_busy_mark", "stack_hw", "stack_spills",
           "run_pops", "need_heap", "reclaimed", "mark_xacts"]


def parse_gc_line(text: str) -> dict[str, int] | None:
    gc = hw_tests.parse_gc_line(text)
    return gc if all(k in gc for k in GC_KEYS) else None


def bitmap_words() -> int:
    import encoding  # noqa: PLC0415
    return int(encoding.GC_BITMAP_WORDS)


def perf_metrics(results: list[hw_tests.Result]) -> tuple[dict[str, dict], list[str], list[str]]:
    """P3-P7 from the bench and compile-loop runs: (metrics, lines, problems)."""
    lines: list[str] = []
    problems: list[str] = []
    metrics: dict[str, dict] = {}
    by_test = {r.test.name: r for r in results}
    stats: dict[str, dict[str, int]] = {}
    for key, name in list(BENCH.items()) + [("compile", COMPILE_LOOP)]:
        r = by_test.get(name)
        if r is None or not r.passed:
            problems.append(f"{name}: {r.detail if r else 'not run'}")
            continue
        gc = parse_gc_line(r.text())
        if not gc:
            problems.append(f"{name}: no GC counter line")
            continue
        gc["cycles"] = r.cycles or 0
        stats[key] = gc
        metrics[name] = gc
        lines.append(f"{name}: cycles={gc['cycles']} {gc}")
    full = stats.get("full")
    if full:
        util = full["port_busy_mark"] / max(1, full["mark_cyc"])
        metrics["P3"] = util
        lines.append(f"P3 port util {util:.3f}")
        if util < 0.80:
            problems.append(f"P3 mark-phase port utilisation {util:.3f} < 0.80")
        # P4 is per collection (plan: 4 cycles/bitmap slot + 6/run), not the
        # summed counter line; GC-LOG has each sweep.
        blog = by_test[BENCH["full"]].text()
        per = [int(x) for x in re.findall(r"\[GC-LOG\].*sweep_cyc=(\d+)", blog)]
        runs = [int(x) for x in re.findall(r"\[GC-LOG\].*\bruns=(\d+)", blog)]
        sweep_one = max(per) if per else full["sweep_cyc"]
        n_runs = max(runs) if runs else 1
        cap = 4 * bitmap_words() + 6 * n_runs
        metrics["P4"] = (sweep_one, cap)
        lines.append(f"P4 sweep {sweep_one} cycles (cap {cap}: {bitmap_words()} bitmap words, {n_runs} runs)")
        if sweep_one > cap:
            problems.append(f"P4 sweep {sweep_one} > {cap}")
        metrics["P5"] = full["max_pause"]
        lines.append(f"P5 max_pause {full['max_pause']}")
        if full["max_pause"] > 400_000:
            problems.append(f"P5 max pause {full['max_pause']} > 400000")
        for key in ("full", "deep"):
            s = stats.get(key)
            if s and s["mark_xacts"]:
                frac = s["stack_spills"] / s["mark_xacts"]
                metrics[f"P7 {key}"] = (s["stack_spills"], s["mark_xacts"])
                lines.append(f"P7 {BENCH[key]} spills {s['stack_spills']} / {s['mark_xacts']} "
                             f"mark transactions = {frac:.3f}")
                if frac > 0.05:
                    problems.append(f"P7 {BENCH[key]} spill traffic {frac:.3f} > 0.05")
    else:
        problems.append("P3/P4/P5/P7: bench_full did not produce counters")
    for key, name, cap, pid in (("compile", COMPILE_LOOP, 0.02, "P6a"), ("churn", BENCH["churn"], 0.25, "P6b")):
        s = stats.get(key)
        if s and s["cycles"]:
            share = s["total_pause"] / s["cycles"]
            metrics[pid] = (s["total_pause"], s["cycles"])
            lines.append(f"{pid} {name} GC share {s['total_pause']} / {s['cycles']} = {share:.4f}")
            if share > cap:
                problems.append(f"{pid} GC share {share:.4f} > {cap}")
        else:
            problems.append(f"{pid}: {name} did not produce counters")
    return metrics, lines, problems


def p8_rate(corpus: pathlib.Path) -> tuple[int, int]:
    """(run-list pops, allocations) over a gc_fuzz.py output directory."""
    pops = allocs = 0
    for p in corpus.rglob("*.log") if corpus.is_dir() else []:
        text = p.read_text(encoding="utf-8", errors="replace")
        pops += hw_tests.parse_gc_line(text).get("run_pops", 0)
        allocs += sum(int(m) for m in re.findall(r"^\[GC-SITE\] .*\ballocs=(\d+)", text, re.M))
    return pops, allocs


def gate_G13(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    res = gate_runs(ctx, "G13")
    _, plines, pprobs = perf_metrics(res)
    lines += plines
    problems += pprobs
    # P1 / P2: existing tests with GC_EN=1 vs G0. A test that never collects
    # must match G0 cycle for cycle; one that does may add only the pause
    # (plus 0.5%).
    p1p2 = gate_runs(ctx, "G13-p1")
    p1 = p2 = 0
    rel_zero: list[hw_tests.Test] = []
    for r in p1p2:
        if not r.passed:
            problems.append(f"P1/P2 {r.test.name}: {r.detail}")
            continue
        text = r.text()
        gc = parse_gc_line(text)
        coll = 0 if gc is None else gc["collections"]
        diffs = compare_to_baseline([r], check_cycles=(coll == 0))
        g0 = g0_cycles(r.test.name) or 0
        if coll == 0:
            p1 += 1
            zero_lines = hw_tests.parse_gc_line(text).get("zero_lines", 0)
            only_cycles = all(": cycles baseline=" in d for d in diffs)
            if diffs and only_cycles and gc is not None and gc["total_pause"] > 0:
                # No collection, but a rewinding _bi_heap_release zeroed the
                # bytes it handed back (B26, gc.md invariant 6). P1 as revised
                # (gc_plan.md G13): identical to G0 with the zeroing disabled
                # (mutant 46, rerun below), and with it the mutator time may
                # grow by at most 0.5% or 64 cycles per zeroed 64 B line.
                mut = (r.cycles or 0) - gc["total_pause"]
                allow = max(int(g0 * 0.005 + 0.5), 64 * zero_lines)
                rel_zero.append(r.test)
                lines.append(f"P1 {r.test.name}: {r.cycles} cycles (G0 {g0}), release zeroing "
                             f"{gc['total_pause']} cycles over {zero_lines} lines; "
                             f"mutator {mut} <= {g0 + allow}")
                if not g0 or mut > g0 + allow:
                    problems.append(f"P1 {r.test.name}: mutator {mut} > G0 {g0} + {allow} "
                                    f"(release zeroing {gc['total_pause']} cycles)")
                # One line write per 64 B line (about 14 cycles at
                # MEM_LATENCY=4) plus the edge words and the visit.
                if gc["total_pause"] > 16 * zero_lines + 64:
                    problems.append(f"P1 {r.test.name}: release zeroing {gc['total_pause']} "
                                    f"cycles > 16 x {zero_lines} lines + 64")
            else:
                problems += [f"P1 {d}" for d in diffs]
        else:
            p2 += 1
            problems += [f"P2 {d}" for d in diffs]
            mut = (r.cycles or 0) - gc["total_pause"]
            if g0 and mut > int(g0 * 1.005 + 0.5):
                problems.append(f"P2 {r.test.name}: mutator {mut} > G0 {g0} + 0.5%")
    if rel_zero:
        rz = gate_runs(ctx, "G13-p1", "G13-p1_nozero", tests=rel_zero,
                       plusargs=spec(ctx, "G13-p1").get("plusargs", "") + " +GC_MUTANT=46")
        for r in rz:
            if not r.passed:
                problems.append(f"P1 {r.test.name} without release zeroing: {r.detail}")
                continue
            problems += [f"P1 {d} (release zeroing disabled)" for d in compare_to_baseline([r])]
        if len(rz) != len(rel_zero):
            problems.append("P1: release-zero reruns missing")
    lines.append(f"P1 {p1} no-collect tests ({len(rel_zero)} differ only by release "
                 f"zeroing); P2 {p2} collecting tests")
    if p1 == 0:
        problems.append("P1: no existing test ran without a collection")
    # P8: run-list pops per allocation over the G8 corpus, when present.
    pops, allocs = p8_rate(ctx.out / "G8")
    if allocs:
        rate = pops / allocs
        lines.append(f"P8 run pops/alloc {rate:.4f} ({pops}/{allocs})")
        if rate > 0.05:
            problems.append(f"P8 run-list pops per allocation {rate:.4f} > 0.05")
    else:
        problems.append("P8: G8 corpus not present in this run")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} G13 targets missed", lines)
    return Result("pass", "G13 P1-P8 within targets", lines)


# --------------------------------------------------------------------------
# G14 full regression and hygiene
# --------------------------------------------------------------------------

def current_warnings() -> tuple[list[str], str]:
    for d in ("sim_img", "sim_img_twocore"):
        shutil.rmtree(ROOT / "build" / d, ignore_errors=True)
    rc, out = run(["make", "pycore-sim-img", "pycore-sim-img-twocore"])
    return gc_baseline.normalise_warnings(out), out


# Simulator output that existed at G0, plus the one GC counter line.
KNOWN_SIM_LINE = re.compile(
    r"^(tb_container: |PASS: |L1I hits=|CODC hits=|GIC hits=|RF spill_count=|"
    r"fetch mem_req=|PERF instr=|GC collections=|- \S+|PHASE_MARK |HEARTBEAT |"
    r"- .*Verilog \$finish|\[\d+\] )"
)


def unknown_output_lines(text: str) -> list[str]:
    """Simulator output lines (after the command line) that match no G0 format."""
    out = []
    for line in text.splitlines()[1:]:
        s = line.strip()
        if not s or KNOWN_SIM_LINE.match(s):
            continue
        out.append(s[:200])
    return out


def gate_G14(ctx: Context) -> Result:
    lines = []
    if not ctx.full:
        return Result("fail", "G14 runs only in MODE=full", lines)
    warns, build_out = current_warnings()
    (ctx.out / "G14_sim_build.log").write_text(build_out, encoding="utf-8")
    base = set(ln for ln in BASELINE_WARN.read_text(encoding="utf-8").splitlines()
               if ln and not ln.startswith("#"))
    new = [w for w in warns if w not in base]
    lines += [f"new warning: {w}" for w in new]
    rc, out = run(["make", "test-all", f"TEST_JOBS={ctx.jobs}"], timeout=8 * 3600)
    (ctx.out / "G14_test_all.log").write_text(out, encoding="utf-8")
    lines.append(f"make test-all exit={rc}")
    # "Default runs print nothing new": each simulator's own output, from the
    # default-config logs test-all just wrote for every test G0 has.
    unknown = []
    names = hw_tests.baseline_names()
    for t in all_tests():
        if t.name not in names or t.kind not in hw_tests.IMAGE_KINDS:
            continue
        log = hw_tests.BUILD / t.name / f"sim-{DEFAULT.slug}.log"
        if not log.exists():
            unknown.append(f"{t.name}: no default-config log")
            continue
        unknown += [f"{t.name}: {u}" for u in unknown_output_lines(log.read_text(errors="replace"))]
    lines += [f"unexpected output: {u}" for u in unknown[:40]]
    if rc != 0 or new or unknown:
        return Result("fail", f"test-all rc={rc}, {len(new)} new warnings, "
                      f"{len(unknown)} unexpected output lines", lines)
    return Result("pass", "make test-all green; no new Verilator warnings; no new output", lines)


# --------------------------------------------------------------------------
# G15 independent review
# --------------------------------------------------------------------------

def gate_G15(ctx: Context) -> Result:
    reviews = ROOT / "planning" / "gc_reviews.md"
    if not reviews.is_file():
        return Result("fail", "planning/gc_reviews.md does not exist (no review round recorded)")
    text = reviews.read_text(encoding="utf-8")
    rounds = re.findall(r"^## Review round at ([0-9a-f]{40})", text, flags=re.M)
    if not rounds:
        return Result("fail", "no review round recorded")
    last = rounds[-1]
    section = text.split(f"## Review round at {last}")[-1]
    m = re.search(r"correctness findings:\s*(\d+)", section, flags=re.I)
    if not m:
        return Result("fail", f"latest round ({last[:10]}) does not state 'correctness findings: N'")
    if int(m.group(1)) != 0:
        return Result("fail", f"latest round ({last[:10]}) reported {m.group(1)} correctness findings")
    try:
        subprocess.run(["git", "merge-base", "--is-ancestor", last, ctx.head], cwd=ROOT, check=True,
                       capture_output=True)
        changed = set(subprocess.run(["git", "diff", "--name-only", last, ctx.head], cwd=ROOT,
                                     capture_output=True, text=True).stdout.split())
    except subprocess.CalledProcessError:
        return Result("fail", f"reviewed commit {last[:10]} is not an ancestor of HEAD")
    extra = sorted(changed - RECORD_ONLY)
    if extra:
        return Result("fail", f"reviewed commit {last[:10]} differs from HEAD in {len(extra)} files",
                      extra[:40])
    return Result("pass", f"latest review round at {last[:10]} reported zero correctness findings")


# --------------------------------------------------------------------------
# G16 docs and CI
# --------------------------------------------------------------------------

GC_DOC_HEADINGS = [
    "Architecture and interfaces", "Roots", "Traversal", "Invariants",
    "Prior art and design decisions", "Performance", "Debugging",
]
COMPANION_DOCS = [
    "pycore/docs/memory_hierarchy.md", "pycore/docs/architecture.md",
    "pycore/docs/code_loading.md", "pycore/docs/object_model.md",
    "excore/docs/mmio_map.md", "README.md",
]


def gate_G16(ctx: Context) -> Result:
    lines = []
    problems = []
    gc_doc = ROOT / "pycore" / "docs" / "gc.md"
    if not gc_doc.is_file():
        return Result("fail", "pycore/docs/gc.md does not exist")
    doc = gc_doc.read_text(encoding="utf-8")
    heads = re.findall(r"^#+\s+(.*)$", doc, flags=re.M)
    for h in GC_DOC_HEADINGS:
        if not any(h.lower() in x.lower() for x in heads):
            problems.append(f"gc.md lacks a '{h}' section")
    status_line = next((ln for ln in doc.splitlines() if ln.startswith("Status:")), "")
    if not status_line or "in progress" in status_line.lower():
        problems.append("gc.md 'Status:' line is missing or still says in progress")
    for d in COMPANION_DOCS:
        text = (ROOT / d).read_text(encoding="utf-8")
        if "gc.md" not in text and "garbage collect" not in text.lower():
            problems.append(f"{d} does not mention the collector")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    if "compile()` leaks its working set" in readme:
        problems.append("README 'Still open' GC line is unchanged")
    if "code-RAM" not in readme and "code RAM" not in readme:
        problems.append("README does not state the code-RAM ceiling")
    preadme = (ROOT / "planning" / "README.md").read_text(encoding="utf-8")
    grad = preadme.split("Graduated", 1)[-1] if "Graduated" in preadme else ""
    if "gc_plan" not in grad:
        problems.append("planning/README.md does not list gc_plan.md under Graduated")
    mk = (ROOT / "Makefile").read_text(encoding="utf-8")
    test_all = mk.split("\ntest-all:", 1)[-1].split("\n\n", 1)[0]
    if "pycore-gc" not in test_all:
        problems.append("test-all does not run the GC engine testbench (pycore-gc)")
    wf = ROOT / ".github" / "workflows" / "all-tests.yml"
    wf_text = wf.read_text(encoding="utf-8") if wf.is_file() else ""
    if not re.search(r"area: \[[^\]]*\bgc\b", wf_text):
        problems.append("all-tests.yml does not run the gc area")
    nightly = ROOT / ".github" / "workflows" / "gc-nightly.yml"
    nt = nightly.read_text(encoding="utf-8") if nightly.is_file() else ""
    for need in ("schedule:", "test-gc-long", "pycore-gc-fuzz"):
        if need not in nt:
            problems.append(f"gc-nightly.yml does not contain {need!r}")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} doc/CI problems", lines)
    return Result("pass", "gc.md complete; companion docs, README, planning index, Makefile, CI updated",
                  lines)

