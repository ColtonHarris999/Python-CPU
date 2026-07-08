# Tests nested function calls: functions calling other functions.
# Exercises the call frame stack across multiple call depths.
def managed_entry() -> int:
    x = step(4)
    y = step(x)
    return x + y  # step(4)=13, step(13)=40, total=53


def step(n: int) -> int:
    a = double(n)     # 2n
    b = increment(a)  # 2n + 1
    c = double(b)     # 4n + 2
    return c - 3      # 4n - 1


def double(x: int) -> int:
    return x * 2


def increment(x: int) -> int:
    return x + 1
