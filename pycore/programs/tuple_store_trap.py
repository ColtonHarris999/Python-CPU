"""STORE_SUBSCR on tuple → TYPE trap."""

def managed_entry() -> int:
    a = 1
    b = 2
    t = (a, b)
    t[0] = 9  # type: ignore
    return 0
