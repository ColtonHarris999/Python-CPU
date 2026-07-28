"""Delete then reinsert the same key (tombstone reuse on pycore)."""


def managed_entry():
    d = {}
    d[1] = 10
    d[2] = 20
    d[3] = 30
    del d[2]
    d[2] = 40
    return d[1] + d[2] + d[3]


managed_entry()
