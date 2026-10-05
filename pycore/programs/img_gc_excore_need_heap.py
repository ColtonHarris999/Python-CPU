"""Phase 3: LIST_APPEND grow after the current run is too short (gc_plan.md §3.6).

Dropped tuples fill the grant to leftover < 128 B. The first append of an
empty list needs a 128 B buffer. Excore returns NEED_HEAP, PyCore collects
the drop chain, re-dispatches, and the grow succeeds. Two-core only.
"""


def managed_entry():
    drop = None
    # Stay at leftover in [128, 192) so BUILD_LIST 0 (64 B) does not abort
    # and collect. The first append then needs a 128 B buffer that does not
    # fit the grant → NEED_HEAP.
    while _bi_heap_free() >= 192:
        drop = (drop, 1)
    drop = None
    # Comprehension emits LIST_APPEND; a display `[1, 2]` is BUILD_LIST.
    xs = [x for x in (1, 2)]
    return xs[0] + xs[1]


managed_entry()
