# Cross-function LIST / DICT / TUPLE stress.
#
# Helpers allocate and mutate containers, pass handles as arguments, and
# return tagged container values across CALL/RETURN boundaries.

def build_row(a, b, c):
    return [a, b, c]


def bump_mid(row, value):
    row[1] = value
    return row


def row_sum(row):
    return row[0] + row[1] + row[2]


def score_map(key_a, key_b, va, vb):
    d = {}
    d[key_a] = va
    d[key_b] = vb
    return d[key_a] + d[key_b]


def pair_tail(x, y):
    t = (x, y)
    return t[1]


def managed_entry():
    row = bump_mid(build_row(10, 20, 30), 40)
    mapped = score_map("x", "yy", 2, 5)
    return row_sum(row) + mapped + pair_tail(7, 9)


managed_entry()
