"""G10 mutant 27: run switch ignores the 64 B alignment slack (gc_plan.md §10.2).

Keep/drop pairs leave 64 B holes. The bump leftover is then filled to < 64 B
so the next runtime 64 B tuple cannot use the current run: it aborts and
collects. Honest wants `need+64 = 128` and MEM_FAULTs. Mutant 27 accepts
`size >= need` and returns.
"""


def managed_entry():
    keep = None
    drop = None
    i = 0
    while i < 80:
        keep = (keep, i)
        drop = (i, i)
        i = i + 1
    drop = None
    while _bi_heap_free() >= 64:
        keep = (keep, 1)
    # Leftover is in [0, 64). A 64 B tuple cannot use the current run, so it
    # aborts and collects. Holes from `drop` are 64 B; honest wants need+64
    # = 128 and MEM_FAULTs. Mutant 27 accepts size >= need and returns.
    x = (keep, 1)
    return keep[1] + x[1]


managed_entry()
