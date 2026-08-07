"""Return a new sorted list from an iterable (bubble sort).

Supports ``reverse=`` via CALL_KW (CODE_OBJECT binder). ``key=`` is not
implemented — passing a key is unsupported. COMPARE_OP is numeric-only on
pycore — sorting strings/containers TYPE-traps.
"""


def sorted(iterable, reverse=False):
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
            left = out[j]
            right = out[j + 1]
            swap = 0
            if reverse:
                if left < right:
                    swap = 1
            else:
                if left > right:
                    swap = 1
            if swap:
                tmp = out[j]
                out[j] = out[j + 1]
                out[j + 1] = tmp
            j = j + 1
        i = i + 1
    return out
