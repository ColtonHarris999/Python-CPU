def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def managed_entry():
    return fib(16)


managed_entry()
