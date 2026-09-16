"""Missing dict key → MEM_FAULT."""


def managed_entry():
    k = 1
    v = 10
    d = {k: v}
    return d[2]


managed_entry()
