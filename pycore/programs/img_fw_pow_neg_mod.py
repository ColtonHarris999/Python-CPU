"""Firmware pow(): a negative exponent needs an invertible base.

``pow(2, -1, 5)`` is the modular inverse 3 (CPython 3.8+); ``pow(2, -1, 4)``
raises a catchable ValueError because gcd(2, 4) != 1.
"""


def managed_entry():
    total = pow(2, -1, 5) * 10
    try:
        pow(2, -1, 4)
    except ValueError:
        total += 43
    return total


managed_entry()
