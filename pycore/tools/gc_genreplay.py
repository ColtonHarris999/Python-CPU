#!/usr/bin/env python3.14
"""Replay a generational policy over a dump sequence (generational GC plan §4).

Input: the dumps of a run with periodic full collections, for example
`+GC_EN=1 +GC_AT_BOUNDARY_EVERY=40000 +GC_DUMP_EACH=<dir>`. Each dump is a
point where a collection *could* run. A policy decides at which points it
does, and whether each is a minor or a major:

    --nursery BYTES      collect once this much was allocated since the last
                         collection (0: at every dump)
    --major-every M      every M-th collection is a major (0: never by count)
    --major-garbage F    a major when tenured garbage exceeds F x old live
                         bytes (0: never by garbage)

It tracks the old set the way sticky mark bits would (a minor promotes every
young survivor; a major keeps only what is live) and estimates each
collection's marking work in scanned slots, like gc_genstats.py: a minor
scans the young survivors and the remembered owners, a major everything.

    python3.14 pycore/tools/gc_genreplay.py <dir> [--nursery N] [--major-every M] ...
    python3.14 pycore/tools/gc_genreplay.py <dir> --check-genstats

The estimate ranks candidate defaults cheaply. It does not model sweep,
zeroing, run selection, barrier lookups or cache effects, and an object
identity is its address and kind across dumps (memory reuse can make a young
object look old). Phase 6 confirms every default on RTL with total cycles
(GG7); a replay number never stands in for a gate.

`--check-genstats` replays "a minor at every dump, never a major", which is
the question gc_genstats.py answers, and fails unless the totals agree.
"""

from __future__ import annotations

import argparse
import pathlib
import sys
from dataclasses import dataclass, field

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gc_genstats  # noqa: E402
import gc_model as g  # noqa: E402


@dataclass
class Policy:
    nursery: int = 0
    major_every: int = 0
    major_garbage: float = 0.0


@dataclass
class Replay:
    collections: int = 0
    minors: int = 0
    majors: int = 0
    full_slots: int = 0        # what a major at every collection point would scan
    work_slots: int = 0        # what the policy scans
    minor_slots: int = 0
    major_slots: int = 0
    alloc: int = 0
    minor_alloc: int = 0       # allocation in the intervals a minor ended
    young_survived: int = 0
    remset: int = 0
    remset_max: int = 0
    tenured_dead: int = 0      # old bytes that died before a major reclaimed them
    peak_garbage: int = 0      # largest tenured garbage held at once
    rows: list[tuple] = field(default_factory=list)


def slots(o: list) -> int:
    return max(o[2], 1)


def replay(dumps: list[pathlib.Path], pol: Policy) -> Replay:
    r = Replay()
    # Live old dynamic objects: addr -> (kind, bytes). A dead old object
    # leaves this map (it can never be reached again) but its bytes stay in
    # `garbage` until a major: sticky bits keep it marked.
    old: dict[int, tuple[str, int]] = {}
    garbage = 0
    since = 0                                 # bytes allocated since the last collection
    prev_live = None
    first = True
    for p in dumps:
        d = g.load_dump(p)
        m = d.meta
        dyn = m["dyn_base"]
        if prev_live is not None:
            since += m["live"] - prev_live + m.get("reclaimed", 0)
        prev_live = m["live"]
        if not first and since < pol.nursery:
            continue
        objs = gc_genstats.build_graph(d)
        dynobjs = {a: o for a, o in objs.items() if a >= dyn}
        full = sum(slots(o) for o in dynobjs.values())
        live_old = {a for a, o in dynobjs.items() if old.get(a, (None,))[0] == o[0]}
        died = sum(b for a, (_, b) in old.items() if a not in live_old)
        old_bytes = sum(old[a][1] for a in live_old)
        r.collections += 1
        major = first or bool(pol.major_every and r.collections % pol.major_every == 0) or bool(
            pol.major_garbage and garbage + died > pol.major_garbage * max(old_bytes, 1))
        ybytes = rem_n = 0
        if major:
            work = full
            r.majors += 1
            r.major_slots += work
            old = {a: (o[0], o[1]) for a, o in dynobjs.items()}
            garbage = 0
        else:
            young = [a for a in dynobjs if a not in live_old]
            youngset = set(young)
            ybytes = sum(dynobjs[a][1] for a in young)
            rem = [a for a, o in objs.items() if (a < dyn or a in live_old)
                   and any(c in youngset for c in o[3])]
            rem_n = len(rem)
            work = sum(slots(dynobjs[a]) for a in young) + sum(slots(objs[a]) for a in rem)
            r.minors += 1
            r.minor_slots += work
            r.remset += rem_n
            r.remset_max = max(r.remset_max, rem_n)
            garbage += died
            old = {a: old[a] for a in live_old}
            for a in young:
                old[a] = (dynobjs[a][0], dynobjs[a][1])
        if not first:
            r.full_slots += full
            r.work_slots += work
            r.tenured_dead += died
            if since > 0:          # survival is over intervals that allocated
                r.alloc += since
                if not major:
                    r.minor_alloc += since
                    r.young_survived += ybytes
        r.peak_garbage = max(r.peak_garbage, garbage)
        r.rows.append((gc_genstats.nat(p), "major" if major else "minor", since, ybytes, rem_n,
                       work, full, garbage))
        since = 0
        first = False
    return r


def report(r: Replay, pol: Policy, rows: bool) -> None:
    if rows:
        print(f"{'dump':>5} {'kind':>5} {'alloc':>9} {'young_srv':>9} {'remset':>6} "
              f"{'work':>8} {'full':>8} {'garbage':>8}")
        for row in r.rows:
            print(f"{row[0]:>5} {row[1]:>5} {row[2]:>9} {row[3]:>9} {row[4]:>6} {row[5]:>8} "
                  f"{row[6]:>8} {row[7]:>8}")
    print(f"REPLAY nursery={pol.nursery} major_every={pol.major_every} "
          f"major_garbage={pol.major_garbage} collections={r.collections} minors={r.minors} "
          f"majors={r.majors} alloc={r.alloc} survival={100.0 * r.young_survived / max(r.minor_alloc, 1):.2f}% "
          f"work={r.work_slots} full={r.full_slots} ratio={r.work_slots / max(r.full_slots, 1):.3f} "
          f"remset_avg={r.remset / max(r.minors, 1):.1f} remset_max={r.remset_max} "
          f"tenured_dead={r.tenured_dead} peak_garbage={r.peak_garbage}")


def check_genstats(dumps: list[pathlib.Path], dirpath: str) -> int:
    """A minor at every dump, never a major after the first, must give
    gc_genstats.py's totals (the research numbers come from those)."""
    r = replay(dumps, Policy())
    rows = gc_genstats.main(dirpath, quiet=True)
    want = dict(
        alloc=sum(x[2] for x in rows if x[2] > 0),
        young=sum(x[3] for x in rows if x[2] > 0),
        rem=sum(x[6] for x in rows),
        minor_slots=sum(x[9] for x in rows),
        full_slots=sum(x[8] for x in rows),
        tenured_dead=sum(x[10] for x in rows),
    )
    got = dict(alloc=r.alloc, young=r.young_survived, rem=r.remset, minor_slots=r.work_slots,
               full_slots=r.full_slots, tenured_dead=r.tenured_dead)
    bad = {k: (got[k], want[k]) for k in want if got[k] != want[k]}
    print(f"REPLAY-CHECK {dirpath}: " + " ".join(f"{k}={got[k]}" for k in got)
          + (" OK" if not bad else f" MISMATCH {bad}"))
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--nursery", type=int, default=0)
    ap.add_argument("--major-every", type=int, default=0)
    ap.add_argument("--major-garbage", type=float, default=0.0)
    ap.add_argument("--rows", action="store_true", help="print one row per collection")
    ap.add_argument("--check-genstats", action="store_true")
    args = ap.parse_args()
    rc = 0
    for dirpath in args.dirs:
        dumps = sorted(pathlib.Path(dirpath).glob("*.gcdump"), key=gc_genstats.nat)
        if not dumps:
            print(f"{dirpath}: no dumps")
            rc = 1
            continue
        if args.check_genstats:
            rc |= check_genstats(dumps, dirpath)
            continue
        pol = Policy(args.nursery, args.major_every, args.major_garbage)
        report(replay(dumps, pol), pol, args.rows)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
