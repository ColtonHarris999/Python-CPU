"""Gate implementations for tools/gc_acceptance.py (planning/gc_plan.md §10.2).

Every gate returns a Result. A gate that cannot evaluate its evidence (missing
file, target, or unparsable output) returns `fail`: the runner fails closed.
"""

from __future__ import annotations

import csv
import json
import pathlib
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_suite  # noqa: E402
import gc_baseline  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE_TSV = ROOT / "pycore" / "tests" / "data" / "gc_baseline_cycles.tsv"
BASELINE_WARN = ROOT / "pycore" / "tests" / "data" / "gc_baseline_verilator_warnings.txt"
BASELINE_AUX = ROOT / "pycore" / "tests" / "data" / "gc_baseline_aux.tsv"
RECORD_ONLY = {"planning/gc_progress.md", "planning/gc_reviews.md"}


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


_TESTS: dict = {}


def tests() -> dict:
    """{name: hw_tests.Test} from pycore/programs/hw_tests.toml, read once."""
    if not _TESTS:
        _TESTS.update(gc_suite.manifest())
    return _TESTS


def names(suites: list[str]) -> list[str]:
    return gc_suite.expand(suites, tests())


def gc_set(ctx: "Context") -> list[str]:
    """The GC fixtures a gate runs: the per-PR [gc] area in MODE=quick, both
    GC areas ([gc] and [gc-long]) in MODE=full."""
    return ["gc-all"] if ctx.full else ["gc"]


# --------------------------------------------------------------------------
# Baseline helpers
# --------------------------------------------------------------------------

def load_baseline() -> list[dict[str, str]]:
    rows = []
    with BASELINE_TSV.open(encoding="utf-8") as fh:
        lines = [ln for ln in fh if not ln.startswith("#")]
    reader = csv.DictReader(lines, delimiter="\t")
    for row in reader:
        rows.append(row)
    return rows


def keyed(rows: list[dict[str, str]]) -> dict[tuple, dict[str, str]]:
    """Key rows by (target, top, cache_en, mem_latency, occurrence)."""
    seen: Counter = Counter()
    out = {}
    for r in rows:
        base = (r["target"], r["top"], str(r["cache_en"]), str(r["mem_latency"]))
        out[base + (seen[base],)] = r
        seen[base] += 1
    return out


def simruns_to_rows(results: list[gc_suite.SimRun]) -> list[dict[str, str]]:
    out = []
    for r in results:
        out.append({
            "target": r.target, "top": r.top, "cache_en": str(r.cache_en),
            "mem_latency": str(r.mem_latency),
            "kind": r.kind if r.status == "pass" else "fail",
            "tag_or_trap_code": str(r.tag_or_trap_code), "value": r.value,
            "cycles": str(r.cycles),
        })
    return out


def compare_to_baseline(results: list[gc_suite.SimRun], configs: set[tuple[str, str]],
                        check_cycles: bool = True, targets: set[str] | None = None) -> list[str]:
    """Differences between `results` and the G0 rows of the same configurations."""
    base = keyed([r for r in load_baseline()
                  if (r["cache_en"], r["mem_latency"]) in configs
                  and (targets is None or r["target"] in targets)])
    got = keyed(simruns_to_rows(results))
    diffs = []
    for k, b in base.items():
        g = got.get(k)
        if g is None:
            diffs.append(f"missing run {k}")
            continue
        fields = ["kind", "tag_or_trap_code", "value"] + (["cycles"] if check_cycles else [])
        for f in fields:
            if b[f] != g[f]:
                diffs.append(f"{k}: {f} baseline={b[f]} got={g[f]}")
    return diffs


def run_config(ctx: Context, name: str, sel: list[str], ce: int, lat: int,
               plusargs: str = "") -> list[gc_suite.SimRun]:
    return gc_suite.run_tests(sel, ce, lat, ctx.out / "runs" / name, ctx.jobs,
                              plusargs=plusargs, tests=tests())


# --------------------------------------------------------------------------
# G0 baseline
# --------------------------------------------------------------------------

def gate_G0(ctx: Context) -> Result:
    lines = []
    for p in (BASELINE_TSV, BASELINE_WARN, BASELINE_AUX):
        if not p.is_file():
            return Result("fail", f"missing {p.relative_to(ROOT)}")
    rows = load_baseline()
    if not rows:
        return Result("fail", "baseline TSV has no rows")
    # Coverage is judged against the fixtures that existed at the baseline
    # commit; GC fixtures added later have no G0 value by construction.
    first = BASELINE_TSV.read_text(encoding="utf-8").splitlines()[0]
    m = re.search(r"at ([0-9a-f]{40})", first)
    if not m:
        return Result("fail", "baseline TSV header does not name its commit")
    rc, toml = run(["git", "show", f"{m.group(1)}:pycore/programs/hw_tests.toml"])
    if rc != 0:
        return Result("fail", f"cannot read hw_tests.toml at baseline commit {m.group(1)[:10]}")
    need = gc_baseline.required_pairs(gc_suite.manifest(toml))
    have = {(row["target"], row["cache_en"], row["mem_latency"]) for row in rows}
    missing = [n for n in need if n not in have]
    fails = [row for row in rows if row["kind"] == "fail"]
    aux = BASELINE_AUX.read_text(encoding="utf-8").splitlines()[1:]
    aux_fail = [a for a in aux if not a.endswith("\tpass")]
    lines.append(f"{len(rows)} baseline rows; {len(need)} (test, config) pairs required")
    lines += [f"missing: {m}" for m in missing[:50]]
    lines += [f"pre-existing failure: {f['target']} {f['cache_en']}/{f['mem_latency']}" for f in fails]
    lines += [f"aux step failed at G0: {a}" for a in aux_fail]
    # Every pre-existing failure must be listed in the ledger.
    ledger = (ROOT / "planning" / "gc_progress.md").read_text(encoding="utf-8")
    unlisted = [f["target"] for f in fails if f["target"] not in ledger]
    if missing:
        return Result("fail", f"baseline misses {len(missing)} test/config pairs "
                      "(new fixtures need the G0 procedure: see ledger)", lines)
    if unlisted:
        return Result("fail", f"{len(unlisted)} pre-existing failures not listed in the ledger", lines)
    return Result("pass", f"{len(rows)} rows cover all {len(need)} test/config pairs; "
                  f"{len(fails)} pre-existing failures", lines)


# --------------------------------------------------------------------------
# G1 GC_EN=0 transparency
# --------------------------------------------------------------------------

GC_OFF = "+GC_EN=0"


def gate_G1(ctx: Context) -> Result:
    lines = []
    diffs: list[str] = []
    configs = gc_baseline.ALL_TESTS_CONFIGS if ctx.full else gc_baseline.ALL_TESTS_CONFIGS[:1]
    base_rows = load_baseline()
    for name, suites, ce, lat, scope in configs:
        if not ctx.full:
            suites = ["img"]
        targets = ({row["target"] for row in base_rows
                    if (row["cache_en"], row["mem_latency"]) == (str(ce), str(lat))}
                   & set(gc_baseline.config_tests(suites, scope, tests())))
        off = GC_OFF + (f" +GC_MUTANT={ctx.mutant}" if ctx.mutant else "")
        sel = [n for n in names(suites) if n in targets]
        res = run_config(ctx, f"G1_{name}", sel, ce, lat, off)
        d = compare_to_baseline(res, {(str(ce), str(lat))}, targets=targets)
        lines.append(f"{name}: {len(res)} runs, {len(d)} differences")
        diffs += [f"{name}: {x}" for x in d]
    if ctx.full:
        for step in gc_baseline.AUX_STEPS:
            rc, out = run(["make", step])
            (ctx.out / f"G1_aux_{step}.log").write_text(out, encoding="utf-8")
            lines.append(f"aux {step}: {'pass' if rc == 0 else 'fail'}")
            if rc != 0:
                diffs.append(f"aux step {step} failed")
    lines += diffs[:200]
    if diffs:
        return Result("fail", f"{len(diffs)} differences from G0 with GC_EN=0", lines)
    return Result("pass", "every result and cycle count identical to G0 with GC_EN=0", lines)


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

# The single-core top reclaims (Phase 1+). The two-core top runs the
# collector verify-only until the excore grant protocol exists (Phase 3):
# firmware would otherwise allocate past heap_limit_r.
TWO_CORE_RECLAIMS = True
GC_ON = "+GC_EN=1 +GC_ROOT_STASH=1 +MAX_CYCLES_SCALE=40"
GC_ON_VERIFY = GC_ON + " +GC_VERIFY_ONLY=1"
def tops(leaves: list[str]) -> dict[str, str]:
    return {leaf: gc_suite.top_of(leaf, tests()) for leaf in leaves}


def gc_plusargs_for(top: str) -> str:
    return GC_ON if (top == "single" or TWO_CORE_RECLAIMS) else GC_ON_VERIFY


def check_dump_file(path: str) -> tuple[str, list[str]]:
    sys.path.insert(0, str(ROOT / "pycore" / "tools"))
    import gc_model  # noqa: PLC0415
    try:
        return path, gc_model.check_dump(gc_model.load_dump(pathlib.Path(path)))
    except Exception as exc:  # noqa: BLE001 - an unreadable dump is a failure
        return path, [f"unreadable dump: {exc}"]


def check_dumps(ctx: Context, root: pathlib.Path) -> tuple[int, list[str]]:
    import concurrent.futures as cf
    dumps = sorted(str(p) for p in root.rglob("*.gcdump"))
    problems = []
    with cf.ProcessPoolExecutor(max_workers=max(1, ctx.jobs)) as ex:
        for path, probs in ex.map(check_dump_file, dumps, chunksize=4):
            for p in probs[:4]:
                problems.append(f"{pathlib.Path(path).relative_to(ROOT)}: {p}")
    return len(dumps), problems


def gc_runs(ctx: Context, name: str, suites: list[str], ce: int, lat: int, extra_plus: str,
            only: set[str] | None = None, dump: bool = True,
            per_leaf: dict[str, str] | None = None) -> tuple[list[gc_suite.SimRun], pathlib.Path]:
    """Run `suites` with the collector on (reclaiming on tops that support
    it), optionally dumping every collection under dumps/<name>/<leaf>."""
    dump_root = ctx.out / "dumps" / name
    subprocess.run(["rm", "-rf", str(dump_root)])
    leaves = [x for x in names(suites) if only is None or x in only]
    by_top = tops(leaves)
    results: list[gc_suite.SimRun] = []
    groups: dict[str, list[str]] = defaultdict(list)
    for leaf in leaves:
        groups[by_top[leaf]].append(leaf)
    mut = f"+GC_MUTANT={ctx.mutant}" if ctx.mutant else ""
    for top, sel in sorted(groups.items()):
        plus = f"{gc_plusargs_for(top)} {mut} {extra_plus}"
        if dump:
            plus += f" +GC_DUMP_EACH={dump_root.relative_to(ROOT)}/{{leaf}}"
        results += gc_suite.run_tests(sel, ce, lat, ctx.out / "runs" / name, ctx.jobs,
                                      plusargs=" ".join(plus.split()), per_test=per_leaf,
                                      tests=tests())
    return results, dump_root


def gate_G4(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    gc_suites = gc_set(ctx)
    if not names(gc_suites):
        problems.append(f"no tests in {gc_suites}")
    existing = {row["target"] for row in load_baseline()}
    sets = [("gcall", gc_suites, "", None)] if names(gc_suites) else []
    configs = [(1, 4)] if not ctx.full else [(1, 4), (0, 4)]
    if ctx.full:
        sets.append(("exit", ["img"], "+GC_AT_EXIT=1", existing))
    total_dumps = 0
    for set_name, suites, extra, only in sets:
        for ce, lat in configs:
            name = f"G4_{set_name}_ce{ce}_lat{lat}"
            res, dump_root = gc_runs(ctx, name, suites, ce, lat, extra, only)
            bad = [x for x in res if x.status != "pass"]
            n, probs = check_dumps(ctx, dump_root)
            total_dumps += n
            # Every clean-return image fixture must have collected at least
            # once. Legacy BOOT_EN=0 hex streams have no managed_entry frame,
            # so +GC_AT_EXIT cannot fire there.
            def boots(x: gc_suite.SimRun) -> bool:
                return "+BOOT_EN=0" not in pathlib.Path(x.log).read_text(errors="replace")
            no_dump = [x.target for x in res if x.status == "pass" and x.kind == "return"
                       and boots(x) and not any((dump_root / x.target).glob("*.gcdump"))]
            if set_name == "gcall":
                no_dump = []
            lines.append(f"{name}: {len(res)} runs, {len(bad)} failing, {n} dumps, "
                         f"{len(probs)} oracle problems, {len(no_dump)} without a collection")
            problems += [f"{name}: FAIL {x.target}: {x.detail}" for x in bad]
            problems += [f"{name}: {p}" for p in probs]
            problems += [f"{name}: no collection in {t}" for t in no_dump]
    # Coherent-dump self-test (plan §6.1): the same fixture dumped with
    # caches on and off must show identical heap, metadata and roots.
    if ctx.full:
        a = ctx.out / "dumps" / "G4_exit_ce1_lat4"
        b = ctx.out / "dumps" / "G4_exit_ce0_lat4"
        compared = 0
        for da in sorted(a.rglob("*.gcdump")):
            db = b / da.relative_to(a)
            if not db.exists():
                problems.append(f"coherent-dump self-test: {db.relative_to(ROOT)} missing")
                continue
            ka = [ln for ln in da.read_text().splitlines() if ln.startswith(("mem ", "root "))]
            kb = [ln for ln in db.read_text().splitlines() if ln.startswith(("mem ", "root "))]
            compared += 1
            if ka != kb:
                problems.append(f"coherent-dump self-test: {da.relative_to(a)} differs between CACHE_EN=1 and 0")
        lines.append(f"coherent-dump self-test: {compared} dump pairs compared")
        if compared == 0:
            problems.append("coherent-dump self-test compared nothing")
    lines += problems[:300]
    if problems:
        return Result("fail", f"{len(problems)} problems over {total_dumps} dumps", lines)
    if not ctx.full:
        return Result("pass", f"quick: {total_dumps} dumps exact on the [gc] area", lines)
    return Result("pass", f"{total_dumps} dumps exact vs gc_model (free set, roots, counters, run list)",
                  lines)


# --------------------------------------------------------------------------
# G5 shadow-heap checker, G6 in-RTL invariants
# --------------------------------------------------------------------------

def gc_logs(ctx: Context) -> list[pathlib.Path]:
    """Logs of every GC-enabled run this acceptance run made so far."""
    runs = ctx.out / "runs"
    if not runs.is_dir():
        return []
    return [p for d in runs.iterdir() if d.is_dir() and not d.name.startswith("G1_")
            for p in d.glob("*.log")]


def gate_G5(ctx: Context) -> Result:
    lines = []
    problems = []
    cases = [("gc-verify-containers", ["gc-verify-containers"], "")] if not ctx.mutant else []
    if ctx.full:
        two = [n for n in names(["containers"])
               if tests()[n].core == "twocore" and tests()[n].kind in gc_suite.IMAGE_KINDS]
        cases.append(("containers-two-core", two, "+GC_AT_EXIT=1"))
    for label, sel, extra in cases:
        plus = f"+GC_EN=1 +GC_VERIFY_ONLY=1 +GC_SHADOW_SELFTEST=1 +MAX_CYCLES_SCALE=40 {extra}".strip()
        # The self-test faults on purpose, so these logs stay out of runs/
        # (G5/G6 scan runs/ for real violations).
        res = gc_suite.run_tests(sel, 1, 4, ctx.out / "G5_selftest" / label, ctx.jobs,
                                 plusargs=plus, tests=tests(), progress=False)
        quiet = [x.target for x in res
                 if "[GC-SHADOW] use-after-free: master=selftest"
                 not in pathlib.Path(x.log).read_text(encoding="utf-8", errors="replace")]
        passed = [x.target for x in res if x.status == "pass"]
        lines.append(f"self-test on {label}: {len(sel) - len(set(quiet))}/{len(sel)} fired, "
                     f"{len(passed)} passed anyway")
        if not sel or quiet or passed:
            problems.append(f"shadow self-test did not fire on {label}: "
                            f"{sorted(set(quiet) | set(passed))[:10]}")
    logs = gc_logs(ctx)
    hits = [p for p in logs if "[GC-SHADOW] use-after-free" in p.read_text(encoding="utf-8", errors="replace")]
    lines.append(f"{len(logs)} GC gate logs scanned, {len(hits)} with a shadow violation")
    problems += [f"shadow violation in {p.relative_to(ROOT)}" for p in hits]
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
        for m in re.finditer(r"^GC collections=(\d+)", text, flags=re.M):
            collections += int(m.group(1))
    lines.append(f"{len(logs)} GC gate logs, {collections} collections, {len(fired)} with [GC-INV]")
    lines += [f"invariant fired: {p.relative_to(ROOT)}" for p in fired]
    if fired:
        return Result("fail", f"{len(fired)} runs tripped an in-RTL invariant", lines)
    if collections == 0:
        return Result("fail", "no collections ran under the invariants", lines)
    return Result("pass", f"no invariant fired over {collections} collections in {len(logs)} runs", lines)


# --------------------------------------------------------------------------
# G7 torture
# --------------------------------------------------------------------------

PERF_RE = re.compile(r"^PERF instr=(\d+)", re.M)
CYC_RE = re.compile(r"cycles=(\d+)")
LOG_LIVE_RE = re.compile(r"^\[GC-LOG\] .*\blive=(\d+)", re.M)
COLL_RE = re.compile(r"^GC collections=(\d+)", re.M)
TB_MAX_SCALE = 1 << 20      # the testbench clamps MAX_CYCLES * scale


def prev_prime(n: int) -> int:
    def prime(k: int) -> bool:
        return k >= 2 and all(k % d for d in range(2, int(k ** 0.5) + 1))
    while n > 2 and not prime(n):
        n -= 1
    return max(n, 1)


def leaf_logs(ctx: Context, prefix: str) -> dict[str, str]:
    """leaf -> log text for every run directory of this acceptance run whose
    name starts with `prefix` (later directories win)."""
    out: dict[str, str] = {}
    runs = ctx.out / "runs"
    if runs.is_dir():
        for d in sorted(runs.iterdir()):
            if d.is_dir() and d.name.startswith(prefix):
                for p in d.glob("*.log"):
                    out[p.stem] = p.read_text(encoding="utf-8", errors="replace")
    return out


def peak_live(ctx: Context, leaf: str, extra_logs: list[str]) -> int:
    """Peak occupancy the mutator needed, from G4 dumps and GC-LOG lines.

    A dump's `meta live` is the reachable set *after* the collection. Compile
    scratch and other dropped temps sit in `meta reclaimed`. G7 (a)/(c) shrink
    the heap to 2× this peak (§10.2), so using only post-collect live
    MEM_FAULTs programs whose high-water mark is the pre-collect occupancy.
    """
    peak = 0
    dumps = ctx.out / "dumps"
    if dumps.is_dir():
        for p in dumps.glob(f"G4_*/{leaf}/*.gcdump"):
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


def scan_gc_problems(results: list[gc_suite.SimRun]) -> list[str]:
    out = []
    for x in results:
        text = pathlib.Path(x.log).read_text(encoding="utf-8", errors="replace")
        if "[GC-SHADOW]" in text:
            out.append(f"{x.target}: shadow-heap violation")
        if "[GC-INV]" in text:
            out.append(f"{x.target}: in-RTL invariant fired")
    return out


def gate_G7(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    suites = ["img"] + gc_set(ctx) if ctx.full else gc_set(ctx)
    leaves = names(suites)
    by_top = tops(leaves)
    gc_all = set(names(["gc-all"]))
    run_set = [x for x in leaves if by_top[x] == "single" or TWO_CORE_RECLAIMS]
    pending = sorted(set(leaves) - set(run_set))
    base_targets = {row["target"] for row in load_baseline()}
    # Instruction counts and cycles from this run's G4 logs; measure if absent.
    g4 = leaf_logs(ctx, "G4_")
    missing = [x for x in run_set if not PERF_RE.search(g4.get(x, ""))]
    if missing:
        gc_runs(ctx, "G7_count", suites, 1, 4, "", only=set(missing), dump=False)
        g4.update(leaf_logs(ctx, "G7_count"))
    instr = {x: int(m.group(1)) for x in run_set if (m := PERF_RE.search(g4.get(x, "")))}
    cycles = {x: int(m.group(1)) for x in run_set if (m := CYC_RE.search(g4.get(x, "")))}
    no_count = [x for x in run_set if x not in instr or x not in cycles]
    problems += [f"no instruction/cycle count for {x}" for x in no_count]
    run_set = [x for x in run_set if x not in no_count]

    def k_for(leaf: str) -> int:
        if leaf in gc_all or instr[leaf] < 50:
            return 1
        return prev_prime(instr[leaf] // 50)

    # Bump-cursor identity / above-cursor trap: a collection between mark
    # and release is §5.4 superseded no-op or first-fit, not the G0 result.
    # Evidence: G7_b at f326e22 (heap-mark-release 0x2b67→0x271b;
    # heap-release-stale-trap expected trap 7, returned cleanly).
    # Recipe heap is the condition under test. G7 (a) at 10b2ba8 replaced
    # the 40 KB fragmented heap with 67200 B (first +HEAP_DYN_BYTES wins);
    # the 800-element list then fit and the program returned 0.
    recipe_heap = {
        "gc-fragmented-alloc",
        "gc-fragmented-alloc-two-core",
        # Fills each grant to a `_bi_heap_free()` margin so the next growth
        # answers NEED_HEAP (G9 two-core rows 14/15/17); a 2.5x-peak heap
        # moves the margin those rows depend on.
        "gc-grant-churn-two-core",
        # Same margin fill before each _bi_code_new (G9 row 31).
        "gc-code-new-churn",
        "gc-code-new-churn-two-core",
        # +GC_AUTO=0: the skip-then-MemoryError sequence needs its own heap.
        "gc-release-zero-after-oom",
        "gc-release-zero-after-oom-two-core",
    }
    bump_cursor = {
        "heap-mark-release",
        "heap-release-stale-trap",
        # Fill-until-OOM then drop: AT_BOUNDARY first-fit leaves a 64 B hole
        # while the junk chain is still live, so the last tuple traps 7
        # (G7_b pycore-img-gc-root-closure at b639619, largest=64).
        "gc-root-closure",
        "gc-mutant-8",
        "gc-mutant-27",
        "gc-mutant-34",
        "gc-mutant-36",
    }

    mode_b_logs: dict[str, str] = {}
    modes = ["b", "a", "c"] if ctx.full else ["a"]
    for mode in modes:
        per_leaf: dict[str, str] = {}
        for leaf in run_set:
            if leaf in bump_cursor:
                per_leaf[leaf] = (f"+GC_LOG=1 +GC_SITE_STATS=1 +MAX_CYCLES_SCALE={TB_MAX_SCALE}"
                                  + (" +GC_POISON=1" if mode == "c" else ""))
            elif mode == "b":
                k = k_for(leaf)
                want = instr[leaf] // max(k, 1)
                scale = (cycles[leaf] + (want + 2) * 400_000) // max(1, cycles[leaf]) + 2
                per_leaf[leaf] = (f"+GC_AT_BOUNDARY_EVERY={k} +GC_LOG=1 +GC_SITE_STATS=1 "
                                  f"+MAX_CYCLES_SCALE={min(scale, TB_MAX_SCALE)}")
            elif leaf in recipe_heap:
                per_leaf[leaf] = (f"+GC_EVERY_N_RUNS=1 +GC_LOG=1 +GC_SITE_STATS=1 "
                                  f"+MAX_CYCLES_SCALE={TB_MAX_SCALE}"
                                  + (" +GC_POISON=1" if mode == "c" else ""))
            else:
                peak = peak_live(ctx, leaf, [mode_b_logs.get(leaf, "")])
                # 2.5× peak: 2× still OOMs G8 seed 2 after EVERY_N_RUNS=1
                # first-fit (largest hole 11 KB, trap 7). 2.25× PASSES.
                heap = (max(peak * 5 // 2, peak + 8192) + 63) & ~63
                per_leaf[leaf] = (f"+GC_EVERY_N_RUNS=1 +HEAP_DYN_BYTES={heap} +GC_LOG=1 "
                                  f"+GC_SITE_STATS=1 +MAX_CYCLES_SCALE={TB_MAX_SCALE}"
                                  + (" +GC_POISON=1" if mode == "c" else ""))
        name = f"G7_{mode}"
        res, dump_root = gc_runs(ctx, name, suites, 1, 4, "", only=set(run_set), per_leaf=per_leaf)
        by_target = {x.target: x for x in res}
        if mode == "b":
            mode_b_logs = {x.target: pathlib.Path(x.log).read_text(errors="replace") for x in res}
        # Golden results (cycles differ by design); new GC fixtures check
        # their own expected value.
        base_res = [x for x in res if x.target in base_targets]
        diffs = compare_to_baseline(base_res, {("1", "4")}, check_cycles=False,
                                    targets={x.target for x in base_res})
        bad = [x for x in res if x.target not in base_targets and x.status != "pass"]
        n, probs = check_dumps(ctx, dump_root)
        gcp = scan_gc_problems(res)
        few = []
        if mode == "b":
            for leaf in run_set:
                m = COLL_RE.search(mode_b_logs.get(leaf, ""))
                got = int(m.group(1)) if m else 0
                # N instructions produce N-1 FETCH transitions from a
                # completed instruction (G7_b: root-caller-rf 48/49,
                # for-iter-end-for 3/4).
                need = min(50, max(instr[leaf] - 1, 1))
                if (leaf not in bump_cursor
                        and got < need
                        and by_target.get(leaf) and by_target[leaf].status == "pass"):
                    few.append(f"{leaf}: {got} boundary collections (K={k_for(leaf)}, {instr[leaf]} instr)")
        lines.append(f"{name}: {len(res)} runs, {len(diffs)} golden diffs, {len(bad)} failing GC fixtures, "
                     f"{n} dumps, {len(probs)} oracle problems, {len(gcp)} shadow/invariant, "
                     f"{len(few)} under-collected")
        problems += [f"{name}: {d}" for d in diffs]
        problems += [f"{name}: FAIL {x.target}: {x.detail}" for x in bad]
        problems += [f"{name}: {p}" for p in probs]
        problems += [f"{name}: {p}" for p in gcp + few]
    if pending:
        lines.append(f"pending-phase-3: {len(pending)} two-core fixtures not yet run with reclamation")
    lines += problems[:300]
    if problems:
        return Result("fail", f"{len(problems)} torture problems", lines)
    if pending:
        return Result("pending-phase-3",
                      f"modes {','.join(modes)} over {len(run_set)} single-core fixtures pass; "
                      f"{len(pending)} two-core fixtures wait for Phase 3", lines)
    return Result("pass", f"modes {','.join(modes)} over {len(run_set)} fixtures: goldens equal, "
                  "dumps exact, no shadow/invariant failure", lines)


# --------------------------------------------------------------------------
# G8 randomized differential fuzzing
# --------------------------------------------------------------------------

def gate_G8(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    n = 1000 if ctx.full else 50
    top_list = ["single", "twocore"] if ctx.full else ["single"]
    for top in top_list:
        if top == "twocore" and not TWO_CORE_RECLAIMS:
            lines.append("two-core fuzzing pending the excore grant protocol (Phase 3)")
            continue
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
    if "twocore" in top_list and not TWO_CORE_RECLAIMS:
        return Result("pending-phase-3",
                      f"{n} seeds on the single-core top, 0 failures; two-core waits for Phase 3",
                      lines)
    return Result("pass", f"{n} seeds per top, 0 failures, coverage complete", lines)


# --------------------------------------------------------------------------
# G9 allocation-site abort coverage
# --------------------------------------------------------------------------

def site_texts(ctx: Context) -> dict[str, list[str]]:
    """Per top: logs of passing G7 runs and passing G8 seeds."""
    import gc_sites  # noqa: F401,PLC0415
    out: dict[str, list[str]] = {"single": [], "twocore": []}
    runs = ctx.out / "runs"
    if runs.is_dir():
        for d in runs.iterdir():
            if not (d.is_dir() and d.name.startswith("G7_") and d.name != "G7_count"):
                continue
            for p in d.glob("*.log"):
                text = p.read_text(encoding="utf-8", errors="replace")
                res = gc_suite.parse_log(p.stem, text, 1, 4, 0, str(p), top=tops([p.stem])[p.stem])
                if res and all(x.status == "pass" for x in res):
                    out[tops([p.stem])[p.stem]].append(text)
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
        if top == "twocore" and not TWO_CORE_RECLAIMS:
            lines.append("two-core site coverage pending the excore grant protocol (Phase 3)")
            continue
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
    if not TWO_CORE_RECLAIMS:
        return Result("pending-phase-3",
                      "single-core rows have >= 10 abort/collect/re-dispatch events; "
                      "excore rows wait for Phase 3", lines)
    return Result("pass", "every integrated §1.3 row has >= 10 abort/collect/re-dispatch events", lines)


# --------------------------------------------------------------------------
# G11 steady state
# --------------------------------------------------------------------------

STEADY = ["gc-steady-list", "gc-steady-dict", "gc-steady-set", "gc-steady-str",
          "gc-steady-exc", "gc-steady-closure", "gc-steady-compile"]
COMPILE_LOOP = [
    "gc-compile-loop",
    "gc-compile-loop-two-core",
    "gc-compile-syntaxerror",
    "gc-compile-syntaxerror-two-core",
]
GC_LOG_RE = re.compile(r"^\[GC-LOG\] n=(\d+) .*?reason=\s*(\S+) live=(\d+) free=(\d+)", re.M)


def gate_G11(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    wanted = list(STEADY) + list(COMPILE_LOOP)
    targets = [t for t in wanted if t in tests()]
    problems += [f"missing fixture {t}" for t in wanted if t not in tests()]
    if not targets:
        return Result("fail", "no steady-state fixtures in hw_tests.toml", lines)
    res, _ = gc_runs(ctx, "G11", targets, 1, 4, "+GC_LOG=1", dump=False)
    for x in res:
        text = pathlib.Path(x.log).read_text(encoding="utf-8", errors="replace")
        logs = [(int(n), why, int(live), int(free)) for n, why, live, free in GC_LOG_RE.findall(text)]
        if any(why == "explicit" for _, why, _, _ in logs) and (
            x.target.endswith("compile") or "compile-" in x.target
        ):
            logs = [e for e in logs if e[1] == "explicit"]
        limit = 16384 if x.target in COMPILE_LOOP else 1024
        if x.status != "pass":
            problems.append(f"{x.target}: FAIL {x.detail}")
            continue
        if len(logs) < 10:
            problems.append(f"{x.target}: {len(logs)} collections (< 10)")
            continue
        tail = logs[len(logs) // 2:]
        spread = max(e[2] for e in tail) - min(e[2] for e in tail)
        drift = logs[0][3] - logs[-1][3]
        lines.append(f"{x.target}: {len(logs)} collections, live spread {spread} B over the last half, "
                     f"free first {logs[0][3]} last {logs[-1][3]}")
        if spread > limit:
            problems.append(f"{x.target}: live spread {spread} B > {limit} B")
        if drift > 1024:
            problems.append(f"{x.target}: free bytes fell by {drift} B")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} steady-state problems", lines)
    extra = []
    if not TWO_CORE_RECLAIMS:
        extra.append("two-core waits for Phase 3")
    if extra:
        return Result("pending-phase-3" if not TWO_CORE_RECLAIMS else "pass",
                      "single-core steady fixtures plateau; " + "; ".join(extra), lines)
    return Result("pass", "every steady fixture plateaus", lines)


# --------------------------------------------------------------------------
# G10 mutation testing
# --------------------------------------------------------------------------

def gate_G10(ctx: Context) -> Result:
    rc, out = run([sys.executable, str(ROOT / "tools" / "gc_mutants.py"), "--jobs", str(ctx.jobs),
                   "--out", str(ctx.out / "G10")], timeout=24 * 3600)
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
# G12 architectural configurations
# --------------------------------------------------------------------------

G12_CONFIGS = [(0, 1), (0, 4), (0, 30), (1, 1), (1, 4), (1, 30)]


def gate_G12(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    if not ctx.full:
        return Result("fail", "G12 runs only in MODE=full", lines)
    gc_all = [x for x in names(["gc-all"])
              if tops([x])[x] == "single" or TWO_CORE_RECLAIMS]
    if not gc_all:
        return Result("fail", "the GC areas are empty", lines)
    for ce, lat in G12_CONFIGS:
        name = f"G12_gcall_ce{ce}_lat{lat}"
        res, dump_root = gc_runs(ctx, name, ["gc-all"], ce, lat, "", only=set(gc_all))
        bad = [x for x in res if x.status != "pass"]
        n, probs = check_dumps(ctx, dump_root)
        gcp = scan_gc_problems(res)
        lines.append(f"{name}: {len(res)} runs, {len(bad)} failing, {n} dumps, "
                     f"{len(probs)} oracle, {len(gcp)} shadow/invariant")
        problems += [f"{name}: FAIL {x.target}: {x.detail}" for x in bad]
        problems += [f"{name}: {p}" for p in probs + gcp]
    # Whole-suite cache and latency gates with the collector enabled. Two-core
    # stays verify-only until the grant protocol (Phase 3).
    plus = "+GC_EN=1 +GC_ROOT_STASH=1 +GC_AT_EXIT=1 +MAX_CYCLES_SCALE=40"
    hw = [sys.executable, str(ROOT / "pycore" / "tools" / "hw_tests.py"), "--jobs", str(ctx.jobs),
          "--exclude-area", "gc-long", "--plusargs", plus]
    for label, args in (
        ("default", hw + ["--area", "all", "--config", "1,4"]),
        ("caching", hw + ["--caching"]),
    ):
        rc, out = run(args, timeout=6 * 3600)
        (ctx.out / f"G12_{label}.log").write_text(out, encoding="utf-8")
        lines.append(f"{label}: rc={rc}")
        if rc != 0:
            problems.append(f"{label} failed")
    if problems:
        return Result("fail", f"{len(problems)} G12 problems", lines + problems[:80])
    if not TWO_CORE_RECLAIMS:
        return Result("pending-phase-3",
                      "single-core G4/G5 at every (CACHE_EN, MEM_LATENCY) and "
                      "cache/latency sweeps with GC_EN=1 pass; two-core waits for Phase 3",
                      lines)
    return Result("pass", "G4/G5 on the GC areas at every config; hw tests and caching gate green",
                  lines)


# --------------------------------------------------------------------------
# G13 performance
# --------------------------------------------------------------------------

GC_LINE_RE = re.compile(
    r"^GC collections=(\d+) live=(\d+) free=(\d+) largest=(\d+) max_pause=(\d+) "
    r"total_pause=(\d+) mark_cyc=(\d+) sweep_cyc=(\d+) port_busy_mark=(\d+) "
    r"stack_hw=(\d+) stack_spills=(\d+) run_pops=(\d+) need_heap=(\d+) "
    r"reclaimed=(\d+).*mark_xacts=(\d+)",
    re.M,
)
BENCH = {
    "full": "gc-bench-full",
    "churn": "gc-bench-churn",
    "deep": "gc-bench-deep",
    "wide": "gc-bench-wide",
}


ZERO_LINES_RE = re.compile(r"^GC collections=.*zero_lines=(\d+)", re.M)


def parse_gc_line(text: str) -> dict[str, int] | None:
    m = GC_LINE_RE.search(text)
    if not m:
        return None
    keys = ["collections", "live", "free", "largest", "max_pause", "total_pause",
            "mark_cyc", "sweep_cyc", "port_busy_mark", "stack_hw", "stack_spills",
            "run_pops", "need_heap", "reclaimed", "mark_xacts"]
    return dict(zip(keys, map(int, m.groups())))


def gate_G13(ctx: Context) -> Result:
    lines: list[str] = []
    problems: list[str] = []
    missing = [t for t in BENCH.values() if t not in tests()]
    if missing:
        return Result("fail", f"missing bench targets: {missing}", lines)
    res, _ = gc_runs(ctx, "G13_bench", list(BENCH.values()), 1, 4, "+GC_LOG=1", dump=False)
    stats: dict[str, dict[str, int]] = {}
    by_target = {x.target: x for x in res}
    for name, target in BENCH.items():
        x = by_target.get(target)
        if x is None or x.status != "pass":
            problems.append(f"{target}: {x.detail if x else 'not run'}")
            continue
        text = pathlib.Path(x.log).read_text(encoding="utf-8", errors="replace")
        gc = parse_gc_line(text)
        if not gc:
            problems.append(f"{target}: no GC counter line")
            continue
        stats[name] = gc
        lines.append(f"{name}: {gc}")
    # P1 / P2: existing fixtures with GC_EN=1 vs G0. A fixture that never
    # collects must match G0 cycle-for-cycle; one that does collect may add
    # only the pause (plus 0.5%).
    existing = {row["target"] for row in load_baseline()}
    p1p2, _ = gc_runs(ctx, "G13_p1p2", ["img"], 1, 4, "", only=existing)
    p1 = p2 = 0
    rel_zero: list[str] = []
    for x in p1p2:
        if x.status != "pass":
            problems.append(f"P1/P2 {x.target}: {x.detail}")
            continue
        text = pathlib.Path(x.log).read_text(encoding="utf-8", errors="replace")
        gc = parse_gc_line(text)
        coll = 0 if gc is None else gc["collections"]
        diffs = compare_to_baseline([x], {("1", "4")}, check_cycles=(coll == 0),
                                    targets={x.target})
        if coll == 0:
            p1 += 1
            zl = ZERO_LINES_RE.search(text)
            zero_lines = int(zl.group(1)) if zl else 0
            only_cycles = all(": cycles baseline=" in d for d in diffs)
            if diffs and only_cycles and gc is not None and gc["total_pause"] > 0:
                # No collection, but a rewinding _bi_heap_release zeroed the
                # bytes it handed back (B26, gc.md invariant 6). P1 as revised
                # (gc_plan.md G13): identical to G0 with the zeroing disabled
                # (mutant 46, rerun below), and with it the mutator time may
                # grow by at most 0.5% or 64 cycles per zeroed 64 B line.
                base = [row for row in load_baseline()
                        if row["target"] == x.target and row["cache_en"] == "1"
                        and row["mem_latency"] == "4"]
                g0 = int(base[0]["cycles"]) if base else 0
                mut = x.cycles - gc["total_pause"]
                allow = max(int(g0 * 0.005 + 0.5), 64 * zero_lines)
                rel_zero.append(x.target)
                lines.append(f"P1 {x.target}: {x.cycles} cycles (G0 {g0}), release zeroing "
                             f"{gc['total_pause']} cycles over {zero_lines} lines; "
                             f"mutator {mut} <= {g0 + allow}")
                if not base or mut > g0 + allow:
                    problems.append(f"P1 {x.target}: mutator {mut} > G0 {g0} + {allow} "
                                    f"(release zeroing {gc['total_pause']} cycles)")
                # The pass itself: one line write per 64 B line (measured about
                # 14 cycles at MEM_LATENCY=4) plus the edge words and the visit.
                if gc["total_pause"] > 16 * zero_lines + 64:
                    problems.append(f"P1 {x.target}: release zeroing {gc['total_pause']} "
                                    f"cycles > 16 x {zero_lines} lines + 64")
            else:
                problems += [f"P1 {d}" for d in diffs]
        else:
            p2 += 1
            base = [row for row in load_baseline()
                    if row["target"] == x.target and row["cache_en"] == "1"
                    and row["mem_latency"] == "4"]
            if not base:
                continue
            g0 = int(base[0]["cycles"])
            mut = x.cycles - gc["total_pause"]
            if mut > int(g0 * 1.005 + 0.5):
                problems.append(f"P2 {x.target}: mutator {mut} > G0 {g0} + 0.5%")
    if rel_zero:
        rz, _ = gc_runs(ctx, "G13_p1_nozero", ["img"], 1, 4, "+GC_MUTANT=46",
                        only=set(rel_zero), dump=False)
        for x in rz:
            if x.status != "pass":
                problems.append(f"P1 {x.target} without release zeroing: {x.detail}")
                continue
            problems += [f"P1 {d} (release zeroing disabled)"
                         for d in compare_to_baseline([x], {("1", "4")}, check_cycles=True,
                                                      targets={x.target})]
        if len(rz) != len(rel_zero):
            problems.append("P1: release-zero reruns missing")
    lines.append(f"P1 {p1} no-collect fixtures ({len(rel_zero)} differ only by release "
                 f"zeroing); P2 {p2} collecting fixtures")
    if p1 == 0:
        problems.append("P1: no existing fixture ran without a collection")
    full = stats.get("full")
    if full:
        util = full["port_busy_mark"] / max(1, full["mark_cyc"])
        lines.append(f"P3 port util {util:.3f}")
        if util < 0.80:
            problems.append(f"P3 mark-phase port utilisation {util:.3f} < 0.80")
        # P4 is per collection (plan: 4 cycles/bitmap slot + 6/run), not the
        # summed counter line. bench_full collects twice; GC-LOG has each sweep.
        blog = pathlib.Path(by_target[BENCH["full"]].log).read_text(errors="replace")
        per = [int(x) for x in re.findall(r"\[GC-LOG\].*sweep_cyc=(\d+)", blog)]
        runs = [int(x) for x in re.findall(r"\[GC-LOG\].*\bruns=(\d+)", blog)]
        sweep_one = max(per) if per else full["sweep_cyc"]
        n_runs = max(runs) if runs else 1
        cap = 4 * 480 + 6 * n_runs
        lines.append(f"P4 sweep {sweep_one} cycles (cap {cap}, runs {n_runs})")
        if sweep_one > cap:
            problems.append(f"P4 sweep {sweep_one} > {cap}")
        lines.append(f"P5 max_pause {full['max_pause']}")
        if full["max_pause"] > 400_000:
            problems.append(f"P5 max pause {full['max_pause']} > 400000")
        if full["mark_xacts"]:
            spill_frac = full["stack_spills"] / full["mark_xacts"]
            lines.append(f"P7 spill traffic {spill_frac:.3f}")
            if spill_frac > 0.05:
                problems.append(f"P7 mark-stack spill traffic {spill_frac:.3f} > 0.05")
    else:
        problems.append("P3/P4/P5/P7: bench_full did not produce counters")
    churn = stats.get("churn")
    if churn and by_target.get(BENCH["churn"]):
        text = pathlib.Path(by_target[BENCH["churn"]].log).read_text(errors="replace")
        cm = CYC_RE.search(text)
        if cm:
            share = churn["total_pause"] / max(1, int(cm.group(1)))
            lines.append(f"P6b GC share {share:.3f}")
            if share > 0.25:
                problems.append(f"P6b GC share {share:.3f} > 0.25")
        else:
            problems.append("P6b: bench_churn printed no cycle count")
    else:
        problems.append("P6b: bench_churn did not produce counters")
    compile_t = "gc-compile-loop"
    if compile_t in tests():
        cres, _ = gc_runs(ctx, "G13_p6a", [compile_t], 1, 4, "+GC_LOG=1", dump=False)
        if cres and cres[0].status == "pass":
            text = pathlib.Path(cres[0].log).read_text(errors="replace")
            gc = parse_gc_line(text)
            cm = CYC_RE.search(text)
            if gc and cm:
                share = gc["total_pause"] / max(1, int(cm.group(1)))
                lines.append(f"P6a GC share {share:.3f}")
                if share > 0.02:
                    problems.append(f"P6a GC share {share:.3f} > 0.02")
            else:
                problems.append("P6a: img_gc_compile_loop printed no counters")
        else:
            problems.append(f"P6a {cres[0].detail if cres else 'not run'}")
    else:
        problems.append("P6a: gc-compile-loop is not in hw_tests.toml")
    # P8: run-list pops per allocation over the G8 corpus, when present.
    g8 = ctx.out / "G8"
    if g8.is_dir():
        pops = allocs = 0
        for p in g8.rglob("*.log"):
            text = p.read_text(encoding="utf-8", errors="replace")
            gc = parse_gc_line(text)
            if gc:
                pops += gc["run_pops"]
            for m in re.finditer(r"allocs=(\d+)", text):
                allocs += int(m.group(1))
        if allocs:
            rate = pops / allocs
            lines.append(f"P8 run pops/alloc {rate:.4f} ({pops}/{allocs})")
            if rate > 0.05:
                problems.append(f"P8 run-list pops per allocation {rate:.4f} > 0.05")
        else:
            problems.append("P8: no G8 site-stat allocs to score")
    else:
        problems.append("P8: G8 corpus not present in this run")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} G13 targets missed", lines)
    return Result("pass", "G13 P1-P8 within targets", lines)


# --------------------------------------------------------------------------
# G14 full regression and hygiene
# --------------------------------------------------------------------------

WARN_RE = re.compile(r"^%Warning-([A-Z0-9_]+): ([^:]+):\d+:\d+: (.*)$")


def current_warnings() -> tuple[list[str], str]:
    for d in ("sim_img", "sim_img_twocore"):
        subprocess.run(["rm", "-rf", str(ROOT / "build" / d)])
    rc, out = run(["make", "pycore-sim-img", "pycore-sim-img-twocore"])
    return gc_baseline.normalise_warnings(out), out


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
    rc, out = run(["make", "all-tests", f"TEST_JOBS={ctx.jobs}"], timeout=6 * 3600)
    (ctx.out / "G14_all_tests.log").write_text(out, encoding="utf-8")
    lines.append(f"make all-tests exit={rc}")
    # "Default runs print nothing new": judge each simulator's own output.
    # Scanning the -j all-tests log attributed other jobs' recipe echoes
    # and generator messages to whichever simulator was open (09-28 run:
    # 93,301 "unexpected" lines, all make/python/mkdir echoes).
    name, suites, ce, lat, scope = gc_baseline.ALL_TESTS_CONFIGS[0]
    leaves = gc_baseline.config_tests(suites, scope, tests())
    dres = gc_suite.run_tests(leaves, ce, lat, ctx.out / "runs" / "G14_default", ctx.jobs,
                              tests=tests())
    unknown = []
    for x in dres:
        if x.status != "pass":
            unknown.append(f"{x.target}: {x.status} {x.detail}"[:200])
            continue
        text = pathlib.Path(x.log).read_text(encoding="utf-8", errors="replace")
        unknown += [f"{x.target}: {u}" for u in unknown_output_lines(text)]
    lines.append(f"default-config runs: {len(dres)}")
    lines += [f"unexpected output: {u}" for u in unknown[:40]]
    if rc != 0 or new or unknown:
        return Result("fail", f"all-tests rc={rc}, {len(new)} new warnings, "
                      f"{len(unknown)} unexpected output lines", lines)
    return Result("pass", "make all-tests green; no new Verilator warnings; no new output", lines)


# Simulator output that existed at G0, plus the one GC counter line.
KNOWN_SIM_LINE = re.compile(
    r"^(tb_container: CACHE_EN=|PASS: |L1I hits=|CODC hits=|GIC hits=|RF spill_count=|"
    r"fetch mem_req=|PERF instr=|GC collections=|- \S+|PHASE_MARK |HEARTBEAT )"
)


PLUSARG_ECHO = re.compile(r"^(\+[A-Z][A-Z0-9_]*=\S*\s*)+\\?$")


def unknown_output_lines(text: str) -> list[str]:
    """Lines between a simulator invocation and its PERF line that match no G0 format."""
    out = []
    in_sim = False
    for line in text.splitlines():
        if gc_suite.SIM_RE.search(line) and "Vtb_container" in line and not line.startswith("PASS"):
            in_sim = True
            continue
        if not in_sim:
            continue
        if line.startswith("PERF instr="):
            in_sim = False
            continue
        s = line.strip()
        if not s or KNOWN_SIM_LINE.match(s):
            continue
        # make's echo of a multi-line recipe (`Vtb_container \` then one
        # `+PLUSARG=... \` per line, raw-hex excore fixtures): command text,
        # not simulator output.
        if PLUSARG_ECHO.match(s):
            continue
        out.append(s[:200])
    return out


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
    if not re.search(r"^all-tests:", mk, flags=re.M):
        problems.append("Makefile has no all-tests target")
    at_block = mk.split("\ntest-all:", 1)[-1].split("\n\n", 1)[0]
    if "pycore-gc" not in at_block:
        problems.append("test-all does not run the GC engine testbench (pycore-gc)")
    if "gc" not in {t.area for t in tests().values()}:
        problems.append("hw_tests.toml has no [gc] area")
    wf = ROOT / ".github" / "workflows" / "all-tests.yml"
    matrix = re.search(r"area:\s*\[([^\]]*)\]", wf.read_text(encoding="utf-8")) if wf.is_file() else None
    if not matrix or "gc" not in [a.strip() for a in matrix.group(1).split(",")]:
        problems.append("CI workflow's hardware matrix does not run the gc area")
    lines += problems
    if problems:
        return Result("fail", f"{len(problems)} doc/CI problems", lines)
    return Result("pass", "gc.md complete; companion docs, README, planning index, test-all, CI updated",
                  lines)
