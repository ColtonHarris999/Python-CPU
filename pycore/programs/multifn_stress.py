# Stress test: multiple sequential calls from main, LOAD_CONST constant, STORE/LOAD_FAST.
# managed_entry must be first so it lands at slot 0.
#
# Execution trace:
#   a = get_const()   →  100  (LOAD_CONST INT)
#   b = inc(a)        →  101
#   c = inc(b)        →  102
#   return add(c, a)  →  202
# Expected return: 202

def managed_entry() -> int:
    a = get_const()
    b = inc(a)
    c = inc(b)
    return add(c, a)


def get_const() -> int:
    return 100


def inc(x: int) -> int:
    return x + 1


def add(a: int, b: int) -> int:
    return a + b
