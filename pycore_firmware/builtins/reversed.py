"""Reverse a sequence — returns a list (no reverse iterator).

Negative indices TYPE-trap, so length is counted explicitly.
"""


def reversed(seq):
    xs = []
    for x in seq:
        xs += [x]
    n = 0
    for _ in xs:
        n = n + 1
    out = []
    i = n
    while i > 0:
        i = i - 1
        out += [xs[i]]
    return out
