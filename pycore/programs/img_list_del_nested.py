"""Nested list handles survive DELETE_SUBSCR of a sibling slot.

outer = [[11], [22], [33]]; del outer[1] → [[11], [33]];
return outer[0][0] + outer[1][0] = 44.
"""


def managed_entry():
    a = [11]
    b = [22]
    c = [33]
    outer = [a, b, c]
    del outer[1]
    return outer[0][0] + outer[1][0]


managed_entry()
