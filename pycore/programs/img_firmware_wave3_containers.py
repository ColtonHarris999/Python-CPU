"""Wave 3A.2 ROM builtins that materialize / grow lists (two-core).

Covers list, sorted, reversed, tuple(iterable), dict, filter, min(iterable).
Host golden: 349.
"""


def managed_entry():
    a = 3
    b = 1
    c = 2
    xs = list((a, b, c))
    s = sorted(xs)
    total = s[0] + s[1] + s[2]
    r = reversed(s)
    total += r[0] * 100
    t = tuple(xs)
    total += t[0] + t[1] + t[2]
    d = dict([(1, 10), (2, 20)])
    total += d[1] + d[2]
    f = filter(None, [0, 1, 2, 0, 3])
    for v in f:
        total += v
    total += min(xs)
    return total


managed_entry()
