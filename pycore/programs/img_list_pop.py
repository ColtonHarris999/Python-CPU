"""Native list.pop last-element path (single-core, no grow).

Locals avoid compile() LIST_EXTEND for the list display.
[10, 20, 30].pop() → 30; remaining 10+20. Expected: 60.
"""


def managed_entry():
    x0 = 10
    x1 = 20
    x2 = 30
    a = [x0, x1, x2]
    x = a.pop()
    return x + a[0] + a[1]


managed_entry()
