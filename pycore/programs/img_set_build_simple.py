"""BUILD_SET from locals + CONTAINS_OP checksum.

CPython emits BUILD_SET 3 for {a,b,c} (not the frozenset+SET_UPDATE form).
Expected: 1+1+1+1 = 4 (three hits + one not-in).
"""


def managed_entry():
    a = 1
    b = 2
    c = 3
    s = {a, b, c}
    n = 0
    if 1 in s:
        n = n + 1
    if 2 in s:
        n = n + 1
    if 3 in s:
        n = n + 1
    if 4 not in s:
        n = n + 1
    return n


managed_entry()
