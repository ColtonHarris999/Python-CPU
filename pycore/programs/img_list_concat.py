"""BINARY_OP add: LIST+LIST / TUPLE+TUPLE sequence concat.

Lifts the TYPE trap on PyBGL ``damerau_levenshtein_distance_naive``
(``[a, b, c] + ([d] if cond else [])``) after slice-const folding.
"""


def managed_entry():
    a = [1, 2]
    b = [3]
    c = a + b
    total = c[0] + 10 * c[1] + 100 * c[2]
    total += len(a) + 10 * len(b) + 100 * len(c)

    empty = [] + [7]
    total += 1000 * empty[0]
    if len([] + []) == 0:
        total += 10000

    x = 4
    y = 5
    z = 6
    t = (x, y) + (z,)
    total += t[0] + 10 * t[1] + 100 * t[2]

    take = 1
    xs = [8, 9] + ([2] if take else [])
    total += xs[0] + xs[2]
    return total


managed_entry()
