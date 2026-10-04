#!/usr/bin/env python3
"""Run Makefile fixture suites one leaf target at a time (planning/gc_plan.md §10).

`make all-tests` interleaves hundreds of simulator runs in one log, and the
`PASS:` line names only the program hex, not the top or the memory settings.
The GC gates need every result attributed exactly, so this module:

1. parses the Makefile rule graph and expands a suite target (`pycore-img`,
   `pycore-img-two-core`, ...) into its leaf targets (rules with a recipe);
2. runs the phony prerequisites of those leaves (`excore-fw`, fixture
   generators) once, then runs every leaf as its own `make -o <prereq> ...
   <leaf>` with its own log, in parallel, holding a lock on each `build/<dir>`
   the leaf writes so two leaves never share an image directory concurrently;
3. parses each log into one record per simulator run: top, CACHE_EN,
   MEM_LATENCY, return or trap, tag/value or trap code, cycles, and the GC
   counter line when present.

Used by `tools/gc_baseline.py` (G0) and `tools/gc_acceptance.py` (G1, G4,
G7, G8, G12, G14).
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
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


def merge_plusargs(base: str, extra: str) -> str:
    """Append `extra`, with a later `+NAME=value` replacing an earlier one.

    G7/G8 append `+HEAP_DYN_BYTES=` after a fixture's Makefile value. Verilator
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

RULE_RE = re.compile(r"^([A-Za-z0-9_.%/-]+(?:[ \t]+[A-Za-z0-9_.%/-]+)*)[ \t]*:(?![=:])(.*)$")
PASS_RE = re.compile(
    r"^PASS: (?P<prog>\S*) \S+ (?:tag=(?P<tag>\d+) value=0x(?P<value>[0-9a-fA-F]+)"
    r"|trapped code=(?P<trap>\d+)) cycles=(?P<cycles>\d+)"
)
CACHE_RE = re.compile(r"^tb_container: CACHE_EN=(\d+)")
GC_LINE_RE = re.compile(r"^GC collections=")
SIM_RE = re.compile(r"build/(sim_img_twocore|sim_img)/Vtb_container")
MKDIR_RE = re.compile(r"mkdir -p (build/[^\s;]+)")
FAIL_MARKERS = ("[FAIL]", "%Error", "%Fatal", "*** [")


@dataclass
class Rule:
    prereqs: list[str] = field(default_factory=list)
    has_recipe: bool = False


def parse_makefile(path: Path) -> dict[str, Rule]:
    """Return {target: Rule} for every explicit rule in `path`."""
    rules: dict[str, Rule] = {}
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    current: list[str] = []
    in_define = False
    while i < len(lines):
        line = lines[i]
        if line.startswith("define "):
            in_define = True
        if in_define:
            if line.startswith("endef"):
                in_define = False
            i += 1
            continue
        if line.startswith("\t"):
            for name in current:
                rules[name].has_recipe = True
            i += 1
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        joined = line
        while joined.endswith("\\") and i + 1 < len(lines):
            i += 1
            joined = joined[:-1] + " " + lines[i]
        i += 1
        m = RULE_RE.match(joined)
        if not m or "=" in joined.split(":", 1)[0]:
            current = []
            continue
        targets = m.group(1).split()
        rest = m.group(2).split(";", 1)
        prereqs = [p for p in rest[0].split() if p != "|"]
        current = []
        for name in targets:
            if name.startswith("."):
                continue
            rule = rules.setdefault(name, Rule())
            rule.prereqs.extend(prereqs)
            if len(rest) > 1 and rest[1].strip():
                rule.has_recipe = True
            current.append(name)
    return rules


def expand(rules: dict[str, Rule], suites: list[str]) -> list[str]:
    """Leaf targets (rules with a recipe) reachable from `suites`, in order."""
    out: list[str] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        if name in seen:
            return
        seen.add(name)
        rule = rules.get(name)
        if rule is None:
            raise KeyError(f"no Makefile rule for {name}")
        if rule.has_recipe:
            out.append(name)
            return
        for p in rule.prereqs:
            visit(p)

    for s in suites:
        visit(s)
    return out


def leaf_prereqs(rules: dict[str, Rule], leaves: list[str]) -> list[str]:
    out: list[str] = []
    for leaf in leaves:
        for p in rules[leaf].prereqs:
            if p in rules and p not in out:
                out.append(p)
    return out


@dataclass
class SimRun:
    target: str
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
              returncode: int, log: str) -> list[SimRun]:
    """One SimRun per simulator invocation found in a leaf's make log."""
    runs: list[SimRun] = []
    top = ""
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
            f"make exited {returncode}" if returncode else "no PASS line")
        if runs and returncode == 0 and not fail_lines:
            pass
        else:
            runs.append(SimRun(
                target=target, index=len(runs), top=top or "unknown",
                cache_en=cur_cache, mem_latency=mem_latency, status="fail",
                detail=detail[:600], log=log,
            ))
    return runs


class DirLocks:
    def __init__(self) -> None:
        self._guard = threading.Lock()
        self._locks: dict[str, threading.Lock] = {}

    def get(self, names: list[str]) -> list[threading.Lock]:
        with self._guard:
            return [self._locks.setdefault(n, threading.Lock()) for n in sorted(set(names))]


def make_vars(cache_en: int, mem_latency: int, extra: dict[str, str] | None) -> list[str]:
    out = [f"PYCORE_CACHE_EN={cache_en}", f"PYCORE_MEM_LATENCY={mem_latency}"]
    for k, v in (extra or {}).items():
        out.append(f"{k}={v}")
    return out


def dry_run_dirs(repo: Path, leaf: str, skip: list[str]) -> list[str]:
    cmd = ["make", "-n"] + [a for p in skip for a in ("-o", p)] + [leaf]
    res = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
    return sorted(set(MKDIR_RE.findall(res.stdout)))


def leaf_top(repo: Path, leaf: str) -> str:
    """'twocore' or 'single', from the simulator the leaf's recipe invokes."""
    res = subprocess.run(["make", "-n", leaf], cwd=repo, capture_output=True, text=True)
    m = SIM_RE.findall(res.stdout)
    return "twocore" if "sim_img_twocore" in m else "single"


def run_leaves(
    repo: Path,
    leaves: list[str],
    cache_en: int,
    mem_latency: int,
    log_dir: Path,
    jobs: int,
    extra_vars: dict[str, str] | None = None,
    timeout: float = 6 * 3600,
    progress: bool = True,
    rules: dict[str, Rule] | None = None,
    per_leaf: dict[str, str] | None = None,
) -> list[SimRun]:
    """Run `leaves` in parallel. `per_leaf[leaf]` is appended to that leaf's
    PYCORE_GC_PLUSARGS (per-fixture torture parameters)."""
    rules = rules or parse_makefile(repo / "Makefile")
    skip = leaf_prereqs(rules, leaves)
    log_dir.mkdir(parents=True, exist_ok=True)
    if skip:
        pre = subprocess.run(["make"] + skip, cwd=repo, capture_output=True, text=True)
        (log_dir / "_prereqs.log").write_text(pre.stdout + pre.stderr, encoding="utf-8")
        if pre.returncode != 0:
            return [SimRun(target=p, index=0, top="unknown", cache_en=cache_en,
                           mem_latency=mem_latency, status="fail",
                           detail="prerequisite failed", log=str(log_dir / "_prereqs.log"))
                    for p in skip]
    for kind in ("img", "twocore"):
        subprocess.run([sys.executable, "tools/ensure_sim.py", kind], cwd=repo,
                       capture_output=True, text=True)
    locks = DirLocks()
    dirs = {leaf: dry_run_dirs(repo, leaf, skip) for leaf in leaves}
    mv = make_vars(cache_en, mem_latency, extra_vars)
    results: list[SimRun] = []
    done = 0
    t0 = time.time()
    lock_out = threading.Lock()

    def one(leaf: str) -> list[SimRun]:
        held = locks.get(dirs[leaf])
        for lk in held:
            lk.acquire()
        try:
            log = log_dir / f"{leaf}.log"
            # "{leaf}" in a make-variable value becomes the leaf's name, so
            # per-run artefacts (GC dumps) never collide.
            leaf_mv = [a.replace("{leaf}", leaf) for a in mv]
            if per_leaf and per_leaf.get(leaf):
                key = "PYCORE_GC_PLUSARGS="
                if not any(a.startswith(key) for a in leaf_mv):
                    leaf_mv.append(key)
                leaf_mv = [
                    (a.split("=", 1)[0] + "=" + merge_plusargs(a.split("=", 1)[1], per_leaf[leaf])
                     if a.startswith(key) else a)
                    for a in leaf_mv
                ]
            for a in leaf_mv:
                for tok in a.split():
                    if tok.startswith("+GC_DUMP_EACH="):
                        pathlib.Path(repo / tok.split("=", 1)[1]).mkdir(parents=True, exist_ok=True)
            cmd = ["make"] + [a for p in skip for a in ("-o", p)] + [leaf] + leaf_mv
            try:
                res = subprocess.run(cmd, cwd=repo, capture_output=True, text=True,
                                     timeout=timeout)
                text = res.stdout + res.stderr
                rc = res.returncode
            except subprocess.TimeoutExpired as exc:
                text = (exc.stdout or b"").decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
                text += f"\n[FAIL] runner timeout after {timeout}s\n"
                rc = 124
            log.write_text(" ".join(cmd) + "\n" + text, encoding="utf-8")
            return parse_log(leaf, text, cache_en, mem_latency, rc, str(log))
        finally:
            for lk in held:
                lk.release()

    with cf.ThreadPoolExecutor(max_workers=max(1, jobs)) as ex:
        futs = {ex.submit(one, leaf): leaf for leaf in leaves}
        for fut in cf.as_completed(futs):
            runs = fut.result()
            with lock_out:
                results.extend(runs)
                done += 1
                if progress and (done % 25 == 0 or done == len(leaves)):
                    bad = sum(1 for r in results if r.status != "pass")
                    print(f"[gc_suite] CE={cache_en} LAT={mem_latency} "
                          f"{done}/{len(leaves)} leaves, {bad} failing, "
                          f"{time.time() - t0:.0f}s", flush=True)
    order = {leaf: i for i, leaf in enumerate(leaves)}
    results.sort(key=lambda r: (order.get(r.target, 1 << 30), r.index))
    return results


def results_to_json(results: list[SimRun]) -> list[dict]:
    return [asdict(r) for r in results]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("suites", nargs="+", help="suite or leaf targets")
    ap.add_argument("--repo", default=str(ROOT))
    ap.add_argument("--cache-en", type=int, default=1)
    ap.add_argument("--mem-latency", type=int, default=4)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--log-dir", default="build/gc_suite/logs")
    ap.add_argument("--out", default="")
    ap.add_argument("--var", action="append", default=[], help="extra make VAR=value")
    ap.add_argument("--list", action="store_true", help="print leaves and exit")
    args = ap.parse_args()
    repo = Path(args.repo).resolve()
    rules = parse_makefile(repo / "Makefile")
    leaves = expand(rules, args.suites)
    if args.list:
        print("\n".join(leaves))
        return 0
    extra = dict(v.split("=", 1) for v in args.var)
    results = run_leaves(repo, leaves, args.cache_en, args.mem_latency,
                         Path(args.log_dir).resolve(), args.jobs, extra, rules=rules)
    if args.out:
        Path(args.out).write_text(json.dumps(results_to_json(results), indent=1), encoding="utf-8")
    bad = [r for r in results if r.status != "pass"]
    for r in bad:
        print(f"FAIL {r.target}: {r.detail} ({r.log})")
    print(f"{len(results) - len(bad)} pass, {len(bad)} fail")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
