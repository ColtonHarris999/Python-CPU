"""List OOB write → MEM_FAULT."""


def managed_entry():
    lst = [1]
    lst[5] = 9
    return 0


managed_entry()
