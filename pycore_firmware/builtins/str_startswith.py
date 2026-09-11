"""str.startswith — native method table entry 7.

Uses BINARY_SLICE with non-negative bounds (omitted/negative slices trap).
"""


def str_startswith(self, prefix):
    n = len(prefix)
    m = len(self)
    if n > m:
        return False
    if n == 0:
        return True
    return self[0:n] == prefix
