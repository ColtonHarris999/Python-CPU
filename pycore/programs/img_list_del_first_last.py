"""DELETE_SUBSCR first (LIST_DELETE trap) and last (O(1) on pycore).

[1, 2, 3, 4] → del [0] → [2, 3, 4] → del last → [2, 3]; return 2+3=5.
Needs EXCORE_EN=1 for the mid/first shift.
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
