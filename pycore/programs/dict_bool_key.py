"""Bool key round-trip."""

def managed_entry() -> int:
    d = {True: 5}
    return d[True]
