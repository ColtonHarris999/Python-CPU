"""Exercise ROM-seeded enumerate / zip / map (list-materializing forms).

Bodies use ``out += [...]`` so non-empty growth needs excore (two-core).
Host golden: 78.
"""


def add1(x):
    return x + 1


def managed_entry():
    a = 10
    b = 20
    c = 30
    xs = [a, b, c]
    pairs = enumerate(xs)
    total = 0
    for p in pairs:
        total += p[0] + p[1]
    ys = [1, 2]
    zs = [3, 4]
    zipped = zip(ys, zs)
    for p in zipped:
        total += p[0] + p[1]
    mapped = map(add1, ys)
    for v in mapped:
        total += v
    return total


managed_entry()
