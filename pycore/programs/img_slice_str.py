"""BINARY_SLICE on SHORT_STR: interior, prefix, suffix, full and empty ranges.

Bounds must be non-literal: CPython folds `s[1:3]` into a `slice` constant plus
NB_SUBSCR, and only emits BINARY_SLICE when a bound is not a literal.
"""


def managed_entry():
    s = "abcdef"
    zero = 0
    one = 1
    two = 2
    three = 3
    four = 4
    six = 6
    total = 0
    if s[one:three] == "bc":
        total += 1
    if s[zero:two] == "ab":
        total += 10
    if s[four:six] == "ef":
        total += 100
    if s[zero:six] == "abcdef":
        total += 1000
    if s[two:two] == "":
        total += 10000
    if s[three:one] == "":
        total += 100000
    return total


managed_entry()
