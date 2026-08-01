"""Immutable sequence of numbers — interim list materialization.

Native BI_RANGE emits PY_TAG_RANGE (preferred). This firmware form
returns a list so FOR_ITER still works, at O(n) memory cost.
"""


def range(start, stop=None, step=1):
    if stop is None:
        stop = start
        start = 0
    if step == 0:
        # CPython ValueError; RAISE deferred — div-by-zero trap
        return 1 % 0
    out = []
    i = start
    if step > 0:
        while i < stop:
            out += [i]
            i = i + step
    else:
        while i > stop:
            out += [i]
            i = i + step
    return out
