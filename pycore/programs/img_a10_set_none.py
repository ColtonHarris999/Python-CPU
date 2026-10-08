"""None as a set element (A10). Fixed with the container accelerator.

Today BI_SET treats a None slot as empty, so this returns 0. CPython
returns 1.
"""


def managed_entry():
    s = set((None, 5))
    if None in s:
        return 1
    return 0


managed_entry()
