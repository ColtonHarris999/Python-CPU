#!/usr/bin/env python3
"""G3: run the pycore_gc unit testbench against the gc_model.py oracle.

For each seed, pycore/tools/gc_heapgen.py builds a heap image and root set;
build/tb_gc/Vtb_gc collects it twice back to back (the second collection must
start from a clean bitmap) at every (CACHE_EN, MEM_LATENCY) in {0,1}x{1,4,30};
gc_model.check_dump compares the run list, live/free/largest counters, and the
mark-stack high-water mark. Every fourth seed runs with the on-chip mark stack
shrunk to two entries (spill/refill on every push), half of those also with
a 3-entry memory stack (children that do not fit go through the rescan list),
every third with poison. Directed cases: wide and deep graphs mark exactly
with tiny stacks (chunked scans, rescans), the collection is abandoned only
when the rescan list is full, and engine mutants selected with --mutant are
killed.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pycore" / "tools"))
import gc_heapgen  # noqa: E402
import gc_model  # noqa: E402
from encoding import EXC_STACK_BASE, HEAP_LIMIT, RF_SPILL_BASE, TAG_INT, int_value  # noqa: E402

BIN = ROOT / "build" / "tb_gc" / "Vtb_gc"
OUT = ROOT / "build" / "gc_unit"
CONFIGS = [(ce, lat) for ce in (0, 1) for lat in (1, 4, 30)]


def run_tb(plusargs: str, dump_prefix: pathlib.Path, extra: str = "") -> tuple[int, str]:
    cmd = [str(BIN)] + plusargs.split() + [f"+DUMP={dump_prefix}"] + extra.split()
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    return res.returncode, res.stdout + res.stderr


def prepare(seed: int) -> dict[str, str]:
    """Write one seed's image and roots (once, before any run reads them)."""
    return gc_heapgen.generate(seed).write(OUT / f"s{seed}", "heap")


def one(seed: int, ce: int, lat: int, mutant: int, info: dict[str, str]) -> tuple[str, list[str], dict]:
    d = OUT / f"s{seed}"
    onchip = 2 if seed % 4 == 0 else 0
    stack = 3 if seed % 8 == 4 else 0
    poison = 1 if seed % 3 == 0 else 0
    extra = f"+CACHE_EN={ce} +MEM_LATENCY={lat} +RUNS=2 +POISON={poison} +MUTANT={mutant}"
    if stack:
        extra += f" +STACK_LIMIT={stack}"
    # Every other seed keeps its unallocated tail as the current run and
    # asks for the next-fit start there (core keep-run / rover paths).
    if seed % 2 == 1 and info.get("keep"):
        extra += " " + info["keep"]
    if onchip:
        extra += f" +ONCHIP={onchip}"
    prefix = d / f"ce{ce}_lat{lat}_m{mutant}"
    rc, out = run_tb(info["plusargs"], prefix, extra)
    label = (f"seed={seed} ce={ce} lat={lat}" + (f" onchip={onchip}" if onchip else "")
             + (f" stack={stack}" if stack else ""))
    stats = {"spill": 0, "hw": 0, "rescans": 0}
    if rc != 0 or "TB_GC PASS" not in out:
        return label, [f"tb_gc failed rc={rc}: {out.strip().splitlines()[-1:]}"], stats
    problems = []
    for run in (0, 1):
        dump = gc_model.load_dump(pathlib.Path(f"{prefix}.{run}.gcdump"))
        problems += [f"run{run}: {p}" for p in gc_model.check_dump(dump, compare_hw=True)]
        stats["spill"] = max(stats["spill"], dump.meta.get("spill_xacts", 0))
        stats["hw"] = max(stats["hw"], dump.meta.get("stack_hw", 0))
        stats["rescans"] = max(stats["rescans"], dump.meta.get("rescans", 0))
    return label, problems, stats


def directed(name: str, heap: gc_heapgen.Heap,
             cases: list[tuple[str, int, bool]]) -> list[str]:
    """Collect `heap` once per (plusargs, want_overflow, want_rescans) case;
    every run must match the oracle exactly (or overflow when it should)."""
    d = OUT / name
    info = heap.write(d, "heap")
    problems = []
    for i, (extra, want_ovf, want_resc) in enumerate(cases):
        prefix = d / f"c{i}"
        rc, out = run_tb(info["plusargs"], prefix, f"{extra} +RUNS={1 if want_ovf else 2}")
        tag = f"{name} [{extra}]"
        if rc != 0 or "TB_GC PASS" not in out:
            problems.append(f"{tag}: tb_gc rc={rc}: {out.strip().splitlines()[-1:]}")
            continue
        for run in range(1 if want_ovf else 2):
            dump = gc_model.load_dump(pathlib.Path(f"{prefix}.{run}.gcdump"))
            m = dump.meta
            if m.get("overflow", 0) != int(want_ovf):
                problems.append(f"{tag}: overflow={m.get('overflow')} want {int(want_ovf)}")
            if not want_ovf and bool(m.get("rescans", 0)) != want_resc:
                problems.append(f"{tag}: rescans={m.get('rescans')} want {'>0' if want_resc else 0}")
            problems += [f"{tag} run{run}: {p}" for p in gc_model.check_dump(dump, compare_hw=True)]
    return problems


def wide_heap() -> gc_heapgen.Heap:
    """One 400-wide list of 1-tuples (four scan chunks)."""
    g = gc_heapgen.Gen(seed=7, size=0)
    kids = [g.tuple_(1) for _ in range(400)]
    h_list = g.b.alloc_list([k.handle for k in kids])
    return gc_heapgen.Heap(g.b, g.nodes, [h_list], kids, 0x440, min(HEAP_LIMIT, g.b.ptr + 64),
                           RF_SPILL_BASE, EXC_STACK_BASE, 0, set())


def deep_heap(n: int = 300) -> gc_heapgen.Heap:
    """A chain of n nodes (payload_list, next): depth-first marking leaves one
    payload per level on the stack."""
    g = gc_heapgen.Gen(seed=8, size=0)
    nxt = (TAG_INT, int_value(0))
    nodes = []
    for i in range(n):
        payload = g.b.alloc_list([(TAG_INT, int_value(i))])
        nxt = g.b.alloc_tuple([payload, nxt])
        nodes.append(nxt)
    return gc_heapgen.Heap(g.b, g.nodes, [nxt], [], 0x440, min(HEAP_LIMIT, g.b.ptr + 64),
                           RF_SPILL_BASE, EXC_STACK_BASE, 0, set())


def overflow_case() -> list[str]:
    """Wide and deep graphs need no more than a few stack entries: a full
    stack sends ranges to the rescan list, and only a full rescan list
    abandons the collection."""
    tiny = "+ONCHIP=2 +STACK_LIMIT=4"
    problems = directed("wide", wide_heap(), [
        ("+STACK_LIMIT=16", False, False),          # chunks: 129 entries fit
        (tiny, False, True),
        (f"{tiny} +RESCAN_LIMIT=1", True, False),
    ])
    problems += directed("deep", deep_heap(), [
        ("+STACK_LIMIT=4096", False, False),
        # One recorded node at a time: the stack drains before the next.
        ("+ONCHIP=2 +STACK_LIMIT=1 +RESCAN_LIMIT=1", False, True),
    ])
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, default=200)
    ap.add_argument("--first", type=int, default=0)
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("TEST_JOBS", os.cpu_count() or 2)))
    ap.add_argument("--mutant", type=int, default=0)
    ap.add_argument("--configs", default="all", help="'all' or 'default' (CACHE_EN=1, LAT=4)")
    args = ap.parse_args()
    if not BIN.exists():
        print(f"missing {BIN}; run make {BIN.relative_to(ROOT)}")
        return 2
    OUT.mkdir(parents=True, exist_ok=True)
    configs = CONFIGS if args.configs == "all" else [(1, 4)]
    tasks = [(s, ce, lat) for s in range(args.first, args.first + args.seeds) for ce, lat in configs]
    bad = 0
    max_spill = 0
    max_hw = 0
    max_resc = 0
    infos = {s: prepare(s) for s in range(args.first, args.first + args.seeds)}
    with cf.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        futs = [ex.submit(one, s, ce, lat, args.mutant, infos[s]) for s, ce, lat in tasks]
        for f in cf.as_completed(futs):
            label, problems, stats = f.result()
            max_spill = max(max_spill, stats["spill"])
            max_hw = max(max_hw, stats["hw"])
            max_resc = max(max_resc, stats["rescans"])
            if problems:
                bad += 1
                if bad <= 20:
                    print(f"FAIL {label}")
                    for p in problems[:6]:
                        print(f"  {p}")
                if args.mutant:
                    # A mutant needs one kill; skip the remaining runs.
                    for other in futs:
                        other.cancel()
                    break
    ov = overflow_case() if args.mutant == 0 else []
    for p in ov:
        print(f"FAIL {p}")
    spill_ok = max_spill > 0
    print(f"G3 seeds={args.seeds} configs={len(configs)} runs={len(tasks)} failing={bad} "
          f"overflow_guard={'ok' if not ov else 'FAIL'} spill_refill={'ok' if spill_ok else 'NOT EXERCISED'} "
          f"max_stack_hw={max_hw} max_rescans={max_resc}")
    return 0 if (bad == 0 and not ov and spill_ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
