"""DELETE_SUBSCR first and last elements.

[1, 2, 3, 4] → del [0] → [2, 3, 4] → del last → [2, 3]; return 2+3=5.
"""


def managed_entry():
    x0 = 1
    x1 = 2
    x2 = 3
    x3 = 4
    a = [x0, x1, x2, x3]
    del a[0]
    del a[2]
    return a[0] + a[1]


managed_entry()
