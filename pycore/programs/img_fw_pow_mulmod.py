"""Firmware pow(base, exp, mod): CPython long_pow semantics on int64.

Sign of the result follows mod, pow(x, 0, 1) == 0, moduli above 2 ** 31 go
through the overflow-safe doubling mulmod, mod == 0 raises ValueError.
"""


def managed_entry():
    total = 0
    total += pow(2, 10, 1000)
    total += pow(2, 3, -5) + 10
    total += pow(3, -1, 7) * 100
    total += pow(3, -2, 7) * 1000
    total += pow(7, 0, 1) * 10000
    total += pow(-5, 3, 7) * 10000
    total += pow(123456789, 1000, 4611686018427387847) % 100000 * 100000
    total += pow(4611686018427387903, 77, 4611686018427387903) % 1000
    total += pow(3, 50, -4611686018427387847) % 1000 * 1000
    try:
        pow(2, 1, 0)
    except ValueError:
        total += 10000000000
    return total


managed_entry()
