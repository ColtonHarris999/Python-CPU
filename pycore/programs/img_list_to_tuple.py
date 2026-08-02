# CALL_INTRINSIC_1 arg 6 (INTRINSIC_LIST_TO_TUPLE) from starred tuple display.


def managed_entry():
    x = 1
    lst = [x, 2, 3]
    t = (*lst,)
    return t[0] + t[1] + t[2]


managed_entry()
