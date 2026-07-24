"""Simple list DELETE_SUBSCR: delete middle element (needs EXCORE_EN=1).

Locals force BUILD_LIST 3 (not LIST_EXTEND grow).
[10, 20, 30] → del [1] → [10, 30]; return 10 + 30 = 40.
Mid delete raises PY_TRAP_LIST_DELETE.
"""


def managed_entry():
    x0 = 10
    x1 = 20
    x2 = 30
    a = [x0, x1, x2]
    del a[1]
    return a[0] + a[1]


managed_entry()
