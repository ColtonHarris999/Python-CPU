"""CALL_KW unexpected keyword → CALL_FILTER (trap 6)."""


def g(a, b=0):
    return a + b


def managed_entry():
    return g(1, z=9)


managed_entry()
