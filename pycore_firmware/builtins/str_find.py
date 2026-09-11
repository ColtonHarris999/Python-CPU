"""str.find — native method table entry 9.

Returns -1 on miss (CPython). Empty needle matches at 0.
"""


def str_find(self, sub):
    n = len(sub)
    m = len(self)
    if n == 0:
        return 0
    i = 0
    limit = m - n + 1
    while i < limit:
        if self[i:i + n] == sub:
            return i
        i = i + 1
    return -1
