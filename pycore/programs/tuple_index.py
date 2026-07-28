"""BUILD_TUPLE + NB_SUBSCR at index 0 and size-1."""

def managed_entry() -> int:
    a = 10
    b = 20
    c = 30
    t = (a, b, c)
    x = t[0]
    y = t[2]
    return x + y
