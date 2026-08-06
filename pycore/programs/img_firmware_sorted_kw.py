"""Wave 3B: sorted(..., reverse=) and sum(..., start=) via CALL_KW.

Two-core (list materialization / grow). Host golden: 460.
"""


def managed_entry():
    a = 1
    b = 3
    c = 2
    xs = [a, b, c]
    s = sorted(xs, reverse=True)
    total = s[0] * 100 + s[1] * 10 + s[2]
    s2 = sorted(xs, reverse=False)
    total += s2[0] * 100 + s2[1] * 10 + s2[2]
    total += sum(xs, start=10)
    return total


managed_entry()
