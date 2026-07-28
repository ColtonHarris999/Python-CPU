"""List OOB read → MEM_FAULT."""

def managed_entry() -> int:
    lst = [1]
    return lst[5]
