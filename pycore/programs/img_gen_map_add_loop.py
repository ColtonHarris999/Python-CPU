"""GC gen Phase 7: dict comprehensions (MAP_ADD) on a dict a minor made old.

MAP_ADD writes the dict the comprehension is building, so its owner is
young unless a collection lands inside the comprehension. Each iteration
builds a 24-entry dict whose values allocate, with the instruction count
varied per iteration, so with `+GC_AT_BOUNDARY_EVERY` some minors fall
between two MAP_ADDs and the later ones store young values into an old
dict. Mutant 73 (MAP_ADD does not log) leaves those values unmarked.
"""


def pad(n):
    t = 0
    for i in range(n):
        t = t + i
    return t


def managed_entry():
    keep = [None] * 60
    _bi_gc_collect()
    for it in range(60):
        keep[it] = {j: ["young-map-add-value", it, j] for j in range(24)}
        pad(it % 11)
    total = 0
    for d in keep:
        for k in d:
            v = d[k]
            total = total + k + v[1] * 3 + v[2] + len(v[0])
    return total


managed_entry()
