"""Return a new sorted list from an iterable (bubble sort).

Positional-only in wave 3A; ``reverse=`` / ``key=`` land in wave 3B
(``CALL_KW`` is live for CODE_OBJECT). COMPARE_OP is numeric-only on
pycore — sorting strings/containers TYPE-traps.
"""


def sorted(iterable):
    out = []
    for x in iterable:
        out += [x]
    n = 0
    for _ in out:
        n = n + 1
    i = 0
    while i < n:
        j = 0
        while j < n - 1 - i:
            if out[j] > out[j + 1]:
                tmp = out[j]
                out[j] = out[j + 1]
                out[j + 1] = tmp
            j = j + 1
        i = i + 1
    return out
