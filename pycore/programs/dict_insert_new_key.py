"""Build {1:10}, then d[2]=20, return d[2]."""

def managed_entry() -> int:
    d = {1: 10}
    d[2] = 20
    return d[2]
