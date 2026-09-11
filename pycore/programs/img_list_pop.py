"""Native list.pop last-element path (single-core, no grow).

[10, 20, 30].pop() → 30; remaining 10+20. Expected: 60.
"""


def managed_entry():
    a = [10, 20, 30]
    x = a.pop()
    return x + a[0] + a[1]


managed_entry()
