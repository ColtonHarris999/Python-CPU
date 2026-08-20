"""_bi_heap_mark takes no arguments: wrong argc is PY_TRAP_CALL_FILTER (6)."""


def managed_entry():
    return _bi_heap_mark(1)


managed_entry()
