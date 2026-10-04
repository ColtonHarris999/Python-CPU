"""Allocation-site statistics (planning/gc_plan.md §1.3, G8 coverage, G9).

The testbench (`+GC_SITE_STATS=1`) prints one line per dispatch context:

    [GC-SITE] key=cont0 allocs=12 aborts=3 collects=2 redispatch=3

`cont<n>` is a container op, `call<phase>.<sub>` a CALL FSM phase and sub-op,
`stracc<op>.<variant>` a STRACC command, `state<s>.op<opcode>` anything else
(the excore result adoption in S_TRAP_WAIT). This module maps keys to §1.3
rows and aggregates them.
"""

from __future__ import annotations

import re
from collections import defaultdict

SITE_RE = re.compile(r"^\[GC-SITE\] key=(\S+) allocs=(\d+) aborts=(\d+) collects=(\d+) redispatch=(\d+)",
                     re.M)

# Container ops (pycore_cont_defs.svh CONT_*).
CONT_ROW = {
    0: 2,    # BUILD_LIST
    6: 3,    # BUILD_TUPLE
    3: 4,    # BUILD_MAP
    23: 5,   # BUILD_SET
    34: 9,   # LIST_TO_TUPLE
    49: 10,  # SEQ_REPEAT
    50: 10,  # SEQ_CONCAT
    35: 11,  # UNPACK_EX
    27: 12,  # GET_ITER (SHORT_STR spill word)
    26: 16,  # SET_UPDATE bulk
    37: 17,  # DICT_UPDATE bulk
    36: 18,  # DICT_MERGE bulk
    51: 20,  # MAKE_CELL
    55: 21,  # SET_FUNCTION_ATTRIBUTE 8
    39: 23,  # RAISE type -> exception
    29: 24,  # LOAD_ATTR bound method
}
# CALL FSM (phase, sub) -> row. Phase 13 = builtin, 12 = TYPE, 14 = binder.
# Subs are the call_sub_r value at the heap_ptr advance (see pycore_call_fsm.svh).
CALL_ROW: dict[tuple[int, int], int] = {
    (13, 15): 25,   # range wide (96 B tuple)
    (13, 27): 26,   # set(...)
    (12, 0): 27,    # user TYPE -> INSTANCE
    (12, 23): 28,   # exception TYPE
    (14, 20): 29,   # *args packing (bump is in sub 20; site_sub_q is the prior cycle)
    (14, 21): 29,
    (14, 23): 29,
    (14, 24): 29,
    (14, 45): 30,   # **kwargs leftover dict (enter 52 from 45; first-cycle bump)
    (14, 52): 30,
    (14, 53): 30,
    (13, 20): 31,   # _bi_code_new (historical)
    (13, 63): 31,   # _bi_code_new (sub 63; seed 2 compile: call13.63 allocs=3)
    # CALL_PHASE_GC_UNWIND is 25; abort rises after unwind so G9 keys are
    # call25.<original sub> (call_sub_r is kept).
    (25, 15): 25,
    (25, 27): 26,
    (25, 0): 27,
    (25, 23): 28,
    (25, 20): 29,
    (25, 21): 29,
    (25, 24): 29,
    (25, 32): 29,   # binder reservation (KW / *args budget)
    (25, 45): 30,
    (25, 52): 30,
    (25, 53): 30,
    (25, 63): 31,
}
# STRACC PY_SA_SPLIT variants: 0-2 split/rsplit/splitlines, 3-4 partitions.
SPLIT_OP = 14

# Rows whose integration needs abort/collect/re-dispatch coverage (G9), by top.
ROWS_SINGLE = [2, 3, 4, 5, 9, 10, 11, 12, 16, 17, 18, 20, 21, 23, 24,
               25, 26, 27, 28, 29, 30, 31, 33, 34, 35]
ROWS_EXCORE = [7, 8, 14, 15, 19]
# DICT_MERGE's allocating pycore path runs only for a contaminated operand.
# Valid programs emit DICT_MERGE only for call **kwargs, whose keys are
# strings, so that bit is never set (pycore_cont_bulk.svh CONT_DICT_MERGE).
# With excore on, the string-key merge is row 19. Row 18 has no host-runnable
# program on the two-core top.
ROWS_UNREACHABLE_TWOCORE = [18]


def rows_for(top: str) -> list[int]:
    rows = [r for r in ROWS_SINGLE if not (top == "twocore" and r in ROWS_UNREACHABLE_TWOCORE)]
    if top == "twocore":
        rows += ROWS_EXCORE
    return rows


def row_of(key: str) -> int | None:
    # Binder reservation abort (B18): the CALL aborts before the binder
    # places its *args tuple (row 29) or **kwargs dict (row 30).
    if key == "callres.kw":
        return 30
    if key == "callres.args":
        return 29
    m = re.fullmatch(r"cont(\d+)", key)
    if m:
        return CONT_ROW.get(int(m.group(1)))
    m = re.fullmatch(r"call(\d+)\.(\d+)", key)
    if m:
        return CALL_ROW.get((int(m.group(1)), int(m.group(2))))
    m = re.fullmatch(r"stracc(\d+)\.(\d+)", key)
    if m:
        op, var = int(m.group(1)), int(m.group(2))
        if op == SPLIT_OP:
            return 35 if var <= 2 else 34
        return 33
    # S_TRAP_WAIT is state 11. Excore adopts RES_HEAP_PTR there, so the bump
    # is not a container op. The opcode is the trapping bytecode (CPython 3.14).
    m = re.fullmatch(r"state11\.op(\d+)", key)
    if m:
        return {
            78: 7,    # LIST_APPEND grow
            79: 8,    # LIST_EXTEND
            44: 8,    # BINARY_OP += on a list (LIST_EXTEND trap)
            110: 14,  # STORE_ATTR instance-dict grow
            38: 14,   # STORE_SUBSCR dict grow
            98: 14,   # MAP_ADD dict grow
            107: 15,   # SET_ADD grow
            66: 19,   # DICT_MERGE uncontaminated
            67: 19,   # DICT_UPDATE uncontaminated
            109: 19,   # SET_UPDATE uncontaminated
        }.get(int(m.group(1)))
    return None


def aggregate(texts) -> tuple[dict[int, list[int]], dict[str, list[int]]]:
    """Sum [allocs, aborts, collects, redispatch] per row, and per unmapped key."""
    rows: dict[int, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
    unmapped: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0, 0])
    for text in texts:
        for key, *nums in SITE_RE.findall(text):
            row = row_of(key)
            dest = rows[row] if row is not None else unmapped[key]
            for i, n in enumerate(nums):
                dest[i] += int(n)
    return rows, unmapped


def table(rows: dict[int, list[int]], wanted: list[int]) -> list[str]:
    out = ["row  allocs  aborts  collects  redispatch"]
    for r in wanted:
        a, b, c, d = rows.get(r, [0, 0, 0, 0])
        out.append(f"{r:>3}  {a:>6}  {b:>6}  {c:>8}  {d:>10}")
    return out
