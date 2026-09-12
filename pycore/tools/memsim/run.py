#!/usr/bin/env python3.14
"""PyCore memory-system study: trace -> access model -> cache experiments."""
from __future__ import annotations

import json
import pathlib
import sys
from collections import Counter, defaultdict

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import layout as L                     # noqa: E402
import model as M                      # noqa: E402
from cachesim import Cache, DirectTagCache   # noqa: E402
from tracer import trace_module, CACHES      # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]

# --- cycle model, derived from the RTL ---------------------------------
# S_FETCH: 3 cycles for the first slot, +2 for every skipped CACHE/EXTENDED_ARG
#          slot (each is its own imem req/ack round trip).
# S_DECODE + S_EXEC + S_WB: 3 cycles on the scalar path.
# Each dependent dmem access inside S_CONTAINER / S_CALL / S_RETURN: 3 cycles
#          (issue, bank turnaround, observe).
FETCH_FIRST = 3          # S_FETCH: issue, bank turnaround, observe
FETCH_EXTRA_SLOT = 2     # every skipped CACHE / EXTENDED_ARG slot
PIPE_SCALAR = 4          # S_DECODE + S_EXEC + S_MEM + S_WB
PIPE_CONTAINER = 3       # S_DECODE + S_EXEC + terminal phase
DMEM_CYCLES = 3          # one dependent dmem access inside S_CONTAINER/S_CALL
PIPE_FIXED = PIPE_SCALAR


def _code_tree(co):
    yield co
    for c in co.co_consts:
        if isinstance(c, type(co)):
            yield from _code_tree(c)


def collect(path: pathlib.Path):
    src = path.read_text()
    if "managed_entry()" not in src.split("def managed_entry")[-1]:
        src += "\nmanaged_entry()\n"
    folded, lay = L.build_from_source(src, path.name)
    try:
        tr = trace_module(folded, {"__name__": "__main__"})
        remap = None
    except Exception:
        # Class folding rewrites module code into a form only the hardware can
        # run.  Trace the unfolded module instead and remap code identities by
        # (qualname, firstlineno), which folding preserves.
        plain = compile(src, path.name, "exec")
        tr = trace_module(plain, {"__name__": "__main__"})
        key = {(c.co_qualname, c.co_firstlineno): id(c) for c in _code_tree(folded)}
        remap = {}
        for cid, c in tr.codes.items():
            tgt = key.get((c.co_qualname, c.co_firstlineno))
            if tgt is not None:
                remap[cid] = tgt
    allowed = set(lay.code_layout)
    steps = []
    for s in tr.steps:
        cid = remap.get(s.code_id, s.code_id) if remap else s.code_id
        if cid not in allowed:
            continue
        s.code_id = cid
        if s.callee_id:
            s.callee_id = remap.get(s.callee_id, s.callee_id) if remap else s.callee_id
        steps.append(s)
    codes = dict(tr.codes)
    costs = M.expand(lay, steps, codes, CACHES)
    return lay, steps, tr, costs


def summarize(name, lay, steps, tr, costs):
    ops = len(costs)
    slots = sum(c.slots for c in costs)
    acc = [a for c in costs for a in c.accesses]
    by_cls = Counter(a.cls for a in acc)
    cyc_fetch = sum(FETCH_FIRST + FETCH_EXTRA_SLOT * (c.slots - 1) for c in costs)
    cyc_pipe = sum(PIPE_SCALAR if not c.accesses else PIPE_CONTAINER
                   for c in costs)
    cyc_dmem = DMEM_CYCLES * len(acc)
    total = cyc_fetch + cyc_pipe + cyc_dmem
    return {
        "program": name,
        "dynamic_ops": ops,
        "imem_slots": slots,
        "cache_slots": slots - ops,
        "dmem_accesses": len(acc),
        "dmem_by_class": dict(by_cls),
        "cycles_fetch": cyc_fetch,
        "cycles_pipe": cyc_pipe,
        "cycles_dmem": cyc_dmem,
        "cycles_total": total,
        "CPO": total / ops,
        "op_hist": Counter(c.opname for c in costs),
    }


def imem_stream(lay, costs, steps):
    """Byte addresses of every imem slot fetched, in order."""
    out = []
    for c, st in zip(costs, steps):
        cl = lay.code_layout.get(st.code_id)
        if cl is None:
            continue
        base_slot = cl.entry_slot + st.offset // 2
        for k in range(c.slots):
            out.append((base_slot + k) * 8)
    return out


def run_program(path: pathlib.Path):
    lay, steps, tr, costs = collect(path)
    s = summarize(path.stem, lay, steps, tr, costs)
    s["_lay"], s["_steps"], s["_costs"] = lay, steps, costs
    return s
