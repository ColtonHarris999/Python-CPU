"""A call before try/except must not hide the handler.

Table offsets are relative to the code entry. A normal return and a
builtin call both used to leave that register holding something else, so
a later raise in the same frame missed. Expected result: 7.
"""


def ok():
    return 1


def boom():
    raise TypeError


def managed_entry():
    ok()
    len([1])
    try:
        raise TypeError
    except TypeError:
        pass
    try:
        boom()
    except TypeError:
        return 7
    return 0


managed_entry()
