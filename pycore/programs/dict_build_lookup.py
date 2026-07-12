"""Build a one-entry dict {key: value} and return d[key].

Expected result: INT 42
"""


def managed_entry() -> int:
    k = 7
    v = 42
    d = {k: v}
    return d[k]
