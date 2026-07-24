"""Single-core O(1) last-element DELETE_SUBSCR (no LIST_DELETE trap).

[10, 20, 30] → del [2] → [10, 20]; return 10 + 20 = 30.
"""


def managed_entry():
    x0 = 10
    x1 = 20
    x2 = 30
    a = [x0, x1, x2]
    del a[2]
    return a[0] + a[1]


managed_entry()
