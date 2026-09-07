"""BINARY_OP multiply: LIST/TUPLE * INT/BOOL sequence repeat.

Lifts the TYPE trap on cjkfuzz ``jaro.similarity`` (``[False] * s1_len``).
"""


def managed_entry():
    n = 4
    flags = [False] * n
    flags[0] = True
    flags[3] = True
    total = 0
    if flags[0]:
        total += 1
    if not flags[1]:
        total += 10
    if not flags[2]:
        total += 100
    if flags[3]:
        total += 1000

    more = 3 * [7]
    total += more[0] + more[1] + more[2]

    if len([1] * 0) == 0:
        total += 10000
    if len([1] * -2) == 0:
        total += 100000

    if len([9] * True) == 1:
        total += 1000000
    if len([9] * False) == 0:
        total += 10000000

    pair = [2, 5] * 2
    total += pair[0] + pair[1] + pair[2] + pair[3]

    t = (3,) * 3
    total += t[0] + t[1] + t[2]
    return total


managed_entry()
