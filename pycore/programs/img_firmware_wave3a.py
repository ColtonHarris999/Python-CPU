"""Wave 3A.1 ROM builtins — single-core (no non-empty LIST_EXTEND).

Covers divmod, pow, round (float eq), bin/hex/oct, empty tuple, min(a, b).
Host golden: 432.
"""


def managed_entry():
    total = 0
    q, r = divmod(17, 5)
    total += q + r
    total += pow(2, 8)
    total += pow(3, 3, 7)
    if round(5) == 5.0:
        total += 1
    if bin(5) == "0b101":
        total += 10
    if hex(10) == "0xa":
        total += 20
    if oct(8) == "0o10":
        total += 30
    # Empty tuple via ROM ``tuple()`` (None-default CALL fill).
    if len(tuple()) == 0:
        total += 100
    total += min(9, 4)
    return total


managed_entry()
