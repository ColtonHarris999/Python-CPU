"""Simple list DELETE_SUBSCR: delete middle element.

[10, 20, 30] → del [1] → [10, 30]; return 10 + 30 = 40.
"""


def managed_entry():
    a = [10, 20, 30]
    del a[1]
    return a[0] + a[1]


managed_entry()
