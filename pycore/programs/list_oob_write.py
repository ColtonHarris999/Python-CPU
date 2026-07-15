"""List OOB write → MEM_FAULT."""

def managed_entry() -> int:
    lst = [1]
    lst[5] = 9
    return 0
