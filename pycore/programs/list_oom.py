"""BUILD_LIST that exceeds remaining heap → MEM_FAULT.
Test sets HEAP_INIT_PTR near PYCORE_HEAP_LIMIT so a small list OOMs.
"""

def managed_entry() -> int:
    a = 1
    b = 2
    c = 3
    lst = [a, b, c]
    return lst[0]
