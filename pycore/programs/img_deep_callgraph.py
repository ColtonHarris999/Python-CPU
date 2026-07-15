# Deep multi-function call-graph stress test.
#
# Ten mutually-recursive helpers (stage0..stage9) call each other in a ring
# with extra branching from stage0 into stage5.  Starting at n=24 yields a
# maximum live call depth of ~25 function frames — well above the fib(10)
# recursion depth of 10 — while exercising mixed arithmetic, bitwise ops,
# and multi-argument CALL/RETURN across distinct code objects.
#
# Expected return is derived by host CPython via run_image_test.py.

def stage0(n, acc):
    if n <= 0:
        return acc
    a = stage1(n - 1, acc + n)
    if (n & 3) == 0:
        b = stage5(n >> 2, 1)
        return a + (b & 15)
    return a


def stage1(n, acc):
    if n <= 0:
        return acc
    return stage2(n - 1, acc + 1)


def stage2(n, acc):
    if n <= 0:
        return acc
    return stage3(n - 1, acc ^ n)


def stage3(n, acc):
    if n <= 0:
        return acc
    return stage4(n - 1, acc + (n & 3))


def stage4(n, acc):
    if n <= 0:
        return acc
    return stage5(n - 1, acc - 1)


def stage5(n, acc):
    if n <= 0:
        return acc
    return stage6(n - 1, acc + 2)


def stage6(n, acc):
    if n <= 0:
        return acc
    return stage7(n - 1, acc + n)


def stage7(n, acc):
    if n <= 0:
        return acc
    return stage8(n - 1, acc + 1)


def stage8(n, acc):
    if n <= 0:
        return acc
    return stage9(n - 1, acc + (n >> 1))


def stage9(n, acc):
    if n <= 0:
        return acc
    return stage0(n - 1, acc + 3)


def managed_entry():
    return stage0(24, 0)


managed_entry()
