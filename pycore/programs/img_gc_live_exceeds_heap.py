"""GC: genuinely live data larger than the heap is a clean OOM (gc_plan.md §6.4).

Every allocation stays reachable through the chain, so each collection frees
nothing; after the loop guard's second fruitless collection the allocation
fails with `PY_TRAP_MEM_FAULT` (v1) instead of hanging or corrupting.

# pycore-expect: 1
"""


def managed_entry():
    chain = None
    n = 0
    try:
        while n < 100:
            chain = (chain, [n] * 128)
            n = n + 1
    except MemoryError:
        return 1
    return 0


managed_entry()
