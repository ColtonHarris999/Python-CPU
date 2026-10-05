"""GC: fragmentation makes a large request fail while small ones succeed (gc_plan.md §6.4).

The Makefile target shrinks the dynamic heap. Every other small object is
kept, so after collection the free space is many small runs whose total
exceeds the big request but none of which fits it. Small allocations keep
succeeding; the big list (one contiguous buffer) is a clean out-of-memory
(`PY_TRAP_MEM_FAULT` in v1, `MemoryError` from Phase 5), not a hang.

# pycore-expect: 1
"""


def managed_entry():
    keep = None
    # Four alternating 3.2 KB list buffers fill a 40 KB dynamic heap while
    # leaving the dropped buffers as individually-too-small holes.
    for i in range(4):
        keep = (keep, [i] * 100)
        drop = [i] * 100
    drop = None
    _bi_gc_collect()
    small = [7] * 20
    try:
        big = [9] * 800
    except MemoryError:
        # The small allocation above succeeded even though no free run can
        # satisfy the large request.
        return 1
    return 0


managed_entry()
