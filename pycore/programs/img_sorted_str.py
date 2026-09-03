"""sorted() on SHORT_STR list — needs COMPARE_OP string ordering.

sorted([\"c\",\"a\",\"b\"])[0] == \"a\" → return 1.
"""


def managed_entry():
    xs = ["c", "a", "b"]
    ys = sorted(xs)
    if ys[0] == "a":
        return 1
    return 0


managed_entry()
