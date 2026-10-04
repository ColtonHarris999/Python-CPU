"""CALL with a *args tuple and no **kwargs across collections (G9 row 29).

Since B18 the binder reserves the *args tuple before it binds, so a heap
shortfall aborts at the reservation, not at the tuple placement. With no
**kwargs parameter the testbench keys that abort `callres.args` (row 29).
`img_gc_call_kw_varargs` covers row 30. The loop allocates a fresh `*rest`
tuple on every call, so a small heap puts the reservation at the run end
many times. It is a `pycore-img-gc-sites` loop (G7 (b) K from the
instruction count, not K=1).
"""


def f(a, b=2, *rest, c=3):
    return a + b + len(rest) + c


def g(*rest):
    return len(rest)


def managed_entry():
    total = 0
    for i in range(400):
        total = total + f(1, 5, 9, c=0)
        total = total + f(i, 1, 2, 3, 4, 5, 6, 7)
        total = total + g(i, i, i, i, i, i, i, i, i)
    return total


managed_entry()
