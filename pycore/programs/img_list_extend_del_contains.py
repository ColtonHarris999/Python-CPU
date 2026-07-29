"""LIST_EXTEND then DELETE_SUBSCR + CONTAINS_OP (needs EXCORE_EN=1).

Build via unpack (grow trap), delete an extended element, check membership.
Returns 1+2+40 = 43 if extend/delete/contains all behaved.
"""


def managed_entry():
    # Constant list literals compile to BUILD_LIST 0 + LIST_EXTEND — that is
    # intentional here (two-core grow path).
    x = [30, 40]
    y = [1, 2, *x]
    # y == [1, 2, 30, 40]
    del y[2]
    # y == [1, 2, 40]
    n = 0
    if 30 not in y:
        n = n + y[0]
    if 40 in y:
        n = n + y[1]
    n = n + y[2]
    return n


managed_entry()
