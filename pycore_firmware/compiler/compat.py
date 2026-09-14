"""Subset-safe helpers for the firmware compiler.

List/tuple slicing and negative indices still trap (compiler_design.md C3).
Call these instead of ``xs[a:b]`` / ``xs[-1]``. String slicing is native
and does not need a helper.
"""


def copy_range(xs, start, end):
    n = end - start
    if n <= 0:
        return []
    out = [0] * n
    i = start
    j = 0
    while i < end:
        out[j] = xs[i]
        i = i + 1
        j = j + 1
    return out


def last(xs):
    return xs[len(xs) - 1]


def rest(xs):
    return copy_range(xs, 1, len(xs))
