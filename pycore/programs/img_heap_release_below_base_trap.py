"""Releasing below the heap base must fault: PY_TRAP_MEM_FAULT (7)."""


def managed_entry():
    _bi_heap_release(0)
    return 0


managed_entry()
