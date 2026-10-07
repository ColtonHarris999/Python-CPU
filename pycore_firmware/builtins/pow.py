"""base ** exp, or modular exponentiation when mod is given.

The three-argument form follows ``long_pow``: the result has the sign of
``mod`` (``pow(2, 3, -5) == -2``), ``mod == 0`` raises ``ValueError``, and a
negative exponent is the power of the modular inverse (``pow(3, -1, 7) ==
5``), ``ValueError`` when ``base`` is not invertible.

Products are never formed on the hart when they could leave int64: the
hart traps ``OVERFLOW`` instead of wrapping, so ``_mulmod`` multiplies by
doubling for moduli above 2 ** 31 and uses the plain product (< 2 ** 62)
below.  ``|mod|`` up to 2 ** 62 is exact; see ``pycore/docs/limitations.md``.

``_mulmod`` and ``_modinv`` are ROM builtins-dict entries as well (see
``ROM_FIRMWARE_BUILTINS``): ROM code resolves names through LOAD_GLOBAL,
so a helper must be a dict key to be callable on the device.
"""


def pow(base, exp, mod=None):
    if mod is None:
        return base ** exp
    if mod == 0:
        raise ValueError  # pow() 3rd argument cannot be 0
    m = mod
    if m < 0:
        m = -m
    if exp < 0:
        base = _modinv(base, m)
        exp = -exp
    b = base % m
    result = 1 % m  # pow(x, 0, 1) == 0
    e = exp
    while e > 0:
        if e % 2 == 1:
            result = _mulmod(result, b, m)
        b = _mulmod(b, b, m)
        e = e // 2
    if mod < 0 and result != 0:
        result = result + mod
    return result


def _mulmod(a, b, m):
    # a * b % m for 0 <= a, b < m without forming a product that could leave
    # int64.  Below 2 ** 31 the product itself is below 2 ** 62.
    if m <= 2147483648:
        return a * b % m
    r = 0
    while b > 0:
        if b % 2 == 1:
            # r = (r + a) % m, written so the sum never exceeds m
            if r >= m - a:
                r = r - (m - a)
            else:
                r = r + a
        if a >= m - a:
            a = a - (m - a)
        else:
            a = a + a
        b = b // 2
    return r


def _modinv(a, m):
    # Extended Euclid on (a mod m, m): returns x in [0, m) with a x == 1 (mod m).
    # Intermediate q * t stays within 2 |m|, so |m| below 2 ** 62 is exact.
    if m == 1:
        return 0
    r0 = a % m
    r1 = m
    t0 = 1
    t1 = 0
    while r1 != 0:
        q = r0 // r1
        r2 = r0 - q * r1
        r0 = r1
        r1 = r2
        t2 = t0 - q * t1
        t0 = t1
        t1 = t2
    if r0 != 1:
        raise ValueError  # base is not invertible for the given modulus
    return t0 % m
