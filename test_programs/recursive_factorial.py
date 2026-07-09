# Tests recursion: factorial via recursive function calls.
# factorial(6) = 720 — exercises 6 levels of call frame push/pop.
def managed_entry() -> int:
    return factorial(6)


def factorial(n: int) -> int:
    if n <= 1:
        return 1
    return n * factorial(n - 1)
