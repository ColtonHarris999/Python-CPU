"""G10 mutant 34: CALL **kwargs budget 96 B short (gc_plan.md §10.2).

Eight kwargs → min_slots=16 → place_end(0, 16)+64 = 1664 B. The mutant
subtracts 96 B. Filling until free is in [1600, 1664) puts the current run
inside that window and below GC_CALL_FAST_BYTES, so the budget check runs.
Junk stays live, so a collection cannot enlarge the run. Honest aborts and
MEM_FAULTs; the mutant accepts the short budget and returns.
"""


def f(**k):
    return len(k) + k["a"] + k["h"]


def managed_entry():
    junk = None
    while _bi_heap_free() >= 1664:
        junk = (junk, 1)
    return f(a=1, b=2, c=3, d=4, e=5, g=6, h=7, i=8)


managed_entry()
