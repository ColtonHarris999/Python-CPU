"""Releasing to a mark above the current cursor must fault, not un-free.

A stale mark is the main hazard of a bump-and-rewind scheme, so it is validated
rather than trusted: PY_TRAP_MEM_FAULT (7).
"""


def managed_entry():
    mark = _bi_heap_mark()
    _bi_heap_release(mark + 64)
    return 0


managed_entry()
