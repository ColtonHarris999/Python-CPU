"""str.endswith — native method table entry 8.

Slice start is ``len(self) - len(suffix)`` so the bound stays non-negative.
"""


def str_endswith(self, suffix):
    n = len(suffix)
    m = len(self)
    if n > m:
        return False
    if n == 0:
        return True
    return self[m - n:m] == suffix
