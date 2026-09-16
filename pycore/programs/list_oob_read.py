"""List OOB read → MEM_FAULT."""


def managed_entry():
    lst = [1]
    return lst[5]


managed_entry()
