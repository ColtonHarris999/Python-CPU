"""base**exp, or modular exponentiation when mod is given.

Negative exp with mod raises (fatal PY_TRAP_RAISE until handlers exist).
"""


def pow(base, exp, mod=None):
    if mod is None:
        return base ** exp
    result = 1
    b = base % mod
    e = exp
    if e < 0:
        raise 0
    while e > 0:
        if e % 2 == 1:
            result = (result * b) % mod
        b = (b * b) % mod
        e = e // 2
    return result % mod
