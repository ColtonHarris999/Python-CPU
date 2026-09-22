"""Subset-safe helpers for the firmware compiler.

List/tuple slicing and negative indices still trap (compiler_design.md C3).
Call these instead of ``xs[a:b]`` / ``xs[-1]``. String slicing is native
and does not need a helper.

No caller today -- every pass that needs a sub-range indexes the SoA arenas
directly (§5.2 Rule 1), which is cheaper than copying. The module stays as
the documented C3 workaround for a pass that does need one; it costs three
``_PYC_G`` keys and ~119 code-RAM slots of 50 028. Delete it, not work
around it, if that ever matters.
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
