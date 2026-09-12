"""Empty and 1-tuple dict keys (two unique keys, no DICT_GROW).

Expected: 46 (6 + 10*4).
"""


def managed_entry():
    d = {}
    d[()] = 4
    d[(9,)] = 6
    return d.get((9,)) + 10 * d.get(())


managed_entry()
