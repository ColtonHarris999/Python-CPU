# Test: chained calls — main calls double which calls add.
# Expected return: 42  (double(21) = add(21, 21) = 42)
#
# NOTE: managed_entry must be defined first so the multi-function
# preprocessor places it at imem slot 0 (the entry point).

def managed_entry() -> int:
    return double(21)


def double(x: int) -> int:
    return add(x, x)


def add(a: int, b: int) -> int:
    return a + b
