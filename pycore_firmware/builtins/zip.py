"""Iterate two iterables in parallel — returns a list of pairs.

*iterables / strict= need CALL_FUNCTION_EX / CALL_KW (deferred).
Deviation: materializes pairs; two-iterable form only.
"""


def zip(a, b):
    la = []
    for x in a:
        la += [x]
    lb = []
    for x in b:
        lb += [x]
    na = 0
    for _ in la:
        na = na + 1
    nb = 0
    for _ in lb:
        nb = nb + 1
    n = na
    if nb < n:
        n = nb
    out = []
    i = 0
    while i < n:
        out += [(la[i], lb[i])]
        i = i + 1
    return out
