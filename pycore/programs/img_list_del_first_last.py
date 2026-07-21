"""DELETE_SUBSCR first and last elements.

[1, 2, 3, 4] → del [0] → [2, 3, 4] → del last → [2, 3]; return 2+3=5.
"""


def managed_entry():
    a = [1, 2, 3, 4]
    del a[0]
    del a[2]
    return a[0] + a[1]


managed_entry()
