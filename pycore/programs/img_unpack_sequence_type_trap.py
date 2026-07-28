"""UNPACK_SEQUENCE type trap: sequence from a SET (unsupported type).

Unpacking a SET raises TYPE trap (code 1).
"""


def managed_entry():
    a = 1
    b = 2
    c = 3
    s = {a, b, c}
    x, y, z = s
    return x + y + z


managed_entry()
