"""Same-key STORE_SUBSCR overwrite (no new-key insert / no grow)."""


def managed_entry():
    d = {}
    d[7] = 1
    d[7] = 99
    return d[7]


managed_entry()
