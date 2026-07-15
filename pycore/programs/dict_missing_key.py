"""Missing dict key → MEM_FAULT."""

def managed_entry() -> int:
    d = {1: 10}
    return d[2]
