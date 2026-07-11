# Tests nested function calls: functions calling other functions.
# Exercises the call frame stack across multiple call depths.
# step(n) = 4*n - 1 ;  managed_entry = step(4) + step(step(4)) = 15 + 59 = 74
def managed_entry() -> int:
    x = step(4)   # 15
    y = step(x)   # step(15) = 59
    return x + y  # 74


def step(n: int) -> int:
    a = double(n)     # 2n
    b = increment(a)  # 2n + 1
    c = double(b)     # 4n + 2
    return c - 3      # 4n - 1


def double(x: int) -> int:
    return x * 2


def increment(x: int) -> int:
    return x + 1
