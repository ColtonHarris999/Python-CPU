# Demo for `make exec-file` / `make shell`: PyCore compiles this file with its
# on-device compile() and runs it; the output is checked against CPython 3.14.
#
# print() on PyCore takes int / bool / None and strings up to 15 bytes today.


def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


def isqrt(n):
    try:
        if n < 0:
            raise ValueError("negative")
        r = 0
        while (r + 1) * (r + 1) <= n:
            r += 1
        return r
    except ValueError:
        return -1


def main():
    print("fib(30):", fib(30))
    counts = {}
    for w in ["a", "b", "a", "c", "a"]:
        counts[w] = counts.get(w, 0) + 1
    print("a:", counts["a"], "c:", counts["c"])
    print("isqrt:", isqrt(99), isqrt(-4))
    print("squares:", sum([x * x for x in range(5)]))


if __name__ == "__main__":
    main()
