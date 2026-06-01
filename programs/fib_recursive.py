def fib(n: int) -> int:
    if n <= 1:
        return n
    return fib(n - 1) + fib(n - 2)


def managed_entry() -> int:
    # Included as a stress/input candidate for CALL/RETURN evolution.
    return fib(6)
