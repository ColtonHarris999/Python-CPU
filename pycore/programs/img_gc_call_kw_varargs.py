"""CALL_KW with *args, keyword-only, and **kwargs across collections (B18).

G7 (b) `img_compile_kwargs`: the binder reservation for `f(1, 5, 9, c=0,
z=4)` failed in the current run, the CALL unwound and re-dispatched, and
the callee then read the `*rest` tuple as `c`. The loop below allocates the
`*rest` tuple and `**kw` dict on every call, so a small heap puts the
budget check at the run end many times.
"""


def f(a, b=2, *rest, c=3, **kw):
    return a + b + len(rest) + c + len(kw)


def managed_entry():
    total = 0
    for i in range(60):
        total = total + f(1)
        total = total + f(1, 5, 9, c=0, z=4)
        total = total + f(i, 1, 2, 3, z=1, y=2)
    return total


managed_entry()
