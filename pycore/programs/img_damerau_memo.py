"""Memoized Damerau shape: class + dict() + tuple-key get/store.

PyBGL ``damerau_levenshtein_distance`` does
``self.memoize.get((i, j))`` then ``self.memoize[(i, j)] = ...``.
Expected: 3232 (32 + 100*32).
"""


class Memo:
    def __init__(self):
        self.memoize = dict()

    def compute(self, i, j):
        ret = self.memoize.get((i, j))
        if ret is None:
            ret = i + 10 * j
            self.memoize[(i, j)] = ret
        again = self.memoize.get((i, j))
        return ret + 100 * again


def managed_entry():
    return Memo().compute(2, 3)


managed_entry()
