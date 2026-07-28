"""UNPACK_SEQUENCE: fixed-count unpack from LIST and TUPLE.

Tests:
- Unpack a 2-element list: a, b = [10, 20]
- Unpack a 3-element tuple: x, y, z = (1, 2, 3)
- Verify: a+b+x+y+z = 10+20+1+2+3 = 36
"""


def managed_entry():
    lst = [10, 20]
    a, b = lst
    x, y, z = (1, 2, 3)
    return a + b + x + y + z


managed_entry()
