"""str.join — native method table entry 6.

Concatenates with BINARY_OP +. Keep parts small enough that the result
fits pycore string limits in tests; overflow TYPE-traps.
"""


def str_join(self, iterable):
    out = ""
    first = True
    for part in iterable:
        if first:
            out = part
            first = False
        else:
            out = out + self + part
    return out
