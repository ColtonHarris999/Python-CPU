"""Round a number to a given precision in decimal digits.

``round(x)`` returns the nearest ``int`` with ties to even, as CPython's
``float.__round__`` / ``int.__round__`` do; ``round(x, n)`` keeps the
operand's type (``float`` stays ``float``; an ``int`` is rounded to a
multiple of ``10 ** -n`` for ``n < 0`` and returned unchanged otherwise).

CPython rounds a float to ``n`` places exactly (``_Py_dg_dtoa`` mode 3 on
the decimal expansion, then ``strtod``).  The hart has only IEEE ``+ - *
/``, so the float path scales by the exact power of ten ``10 ** |n|``
(``|n| <= 22``), rounds the scaled value to an integer and unscales with
one correctly rounded operation -- the same double CPython's ``strtod``
returns for that decimal.  The one place a scaled value can lie is an
apparent ``.5`` tie that the multiply or divide rounded onto; an
error-free two-product (Dekker / Veltkamp splitting) recovers the exact
sign of the error there, so ties are decided on the exact product.  The
result is bit-identical to CPython for ``|n| <= 22``; beyond that the
power of ten is itself inexact and the result can differ in the last
place (``pycore/docs/limitations.md``).

NaN / infinity: ``round(x)`` raises ``ValueError`` (CPython raises
``ValueError`` / ``OverflowError``); ``round(x, n)`` returns ``x`` as
CPython does; an overflowing result raises ``ValueError`` (CPython:
``OverflowError``).  A ``round(x)`` result outside int64 traps.

``_is_int`` probes the tag with ``_bi_code_kind`` (INT 1 / BOOL 4).

Every module-level helper here is also a ROM builtins-dict entry (see
``ROM_FIRMWARE_BUILTINS``): ROM code resolves names through LOAD_GLOBAL,
so a helper must be a dict key to be callable on the device.
"""


def round(number, ndigits=None):
    if ndigits is None:
        if _is_int(number):
            return number + 0  # bool -> int, as CPython
        return int(_round_half_even(number))
    if _is_int(number):
        if ndigits >= 0:
            return number + 0
        if ndigits < -18:
            return 0  # |int64| < 0.5 * 10 ** 19: every such rounding is 0
        p = 10 ** (-ndigits)
        q = number // p
        r = number - q * p
        if r + r > p or (r + r == p and q % 2 == 1):
            q = q + 1
        return q * p
    return _round_float(number, ndigits)


def _is_int(x):
    k = _bi_code_kind(x)
    return k == 1 or k == 4


def _round_half_even(x):
    if x != x or x - x != 0:
        raise ValueError
    f = x // 1
    d = x - f  # exact: x and floor(x) share an exponent when d matters
    if d > 0.5 or (d == 0.5 and f % 2 == 1):
        f = f + 1
    return f


def _round_half_away(y):
    # C round(): nearest integral value, halfway cases away from zero.
    if y >= 0:
        f = y // 1
        if y - f >= 0.5:
            f = f + 1
        return f
    m = -y
    f = m // 1
    if m - f >= 0.5:
        f = f + 1
    return -f


def _pow10(n):
    # Exact for n <= 22 (every such 10 ** n is a double).  Above that the
    # correctly rounded constants 1e256 / 1e128 / 1e64 / 1e32 / 1e22 are
    # combined, so at most five roundings reach the result.
    p = 1.0
    if n >= 256:
        p = p * 1e256
        n = n - 256
    if n >= 128:
        p = p * 1e128
        n = n - 128
    if n >= 64:
        p = p * 1e64
        n = n - 64
    if n >= 32:
        p = p * 1e32
        n = n - 32
    if n > 22:
        p = p * 1e22
        n = n - 22
    q = 1.0
    while n > 0:
        q = q * 10.0
        n = n - 1
    return p * q


def _two_prod_err(a, b, p):
    # a * b - p exactly, for p = a * b rounded (Dekker with Veltkamp's
    # 2 ** 27 + 1 split).  Exact unless the product over- or underflows.
    c = 134217729.0 * a
    ah = c - (c - a)
    al = a - ah
    c = 134217729.0 * b
    bh = c - (c - b)
    bl = b - bh
    return ((ah * bh - p) + ah * bl + al * bh) + al * bl


def _settle_tie(y, z, err):
    # y is the scaled value, z its half-away rounding with |y - z| == 0.5,
    # err the sign of (exact scaled value - y).  Picks the integer nearest
    # the exact value, ties to even.
    if err == 0:
        return 2.0 * _round_half_away(y / 2.0)
    d = y - z
    if (err > 0) == (d > 0):
        return z + d + d  # the exact value lies on the other side of y
    return z


def _even_neighbour(y, err):
    # y is an integer-valued double in [2 ** 52, 2 ** 53) and the exact
    # scaled value is y + err with |err| == 0.5: a tie, decided to even.
    if y % 2 == 0:
        return y
    if err > 0:
        return y + 1
    return y - 1


def _round_float(x, ndigits):
    if x != x or x - x != 0:
        return x
    big = 9007199254740992.0  # 2 ** 53
    half_big = 4503599627370496.0  # 2 ** 52
    if ndigits >= 0:
        pow1 = _pow10(ndigits)
        y = x * pow1
        if y != y or y - y != 0:
            return x  # the product overflowed: x has no digits to round
        if y >= big or y <= -big:
            return x  # 10 ** -n is below ulp(x): x is already rounded
        z = _round_half_away(y)
        d = y - z
        if d == 0.5 or d == -0.5:
            z = _settle_tie(y, z, _two_prod_err(x, pow1, y))
        elif y >= half_big or y <= -half_big:
            # y is integral but the exact product may still be y +- 0.5
            err = _two_prod_err(x, pow1, y)
            if err == 0.5 or err == -0.5:
                z = _even_neighbour(y, err)
        return z / pow1
    pow1 = _pow10(-ndigits)
    y = x / pow1
    if y >= big or y <= -big:
        return x
    z = _round_half_away(y)
    d = y - z
    ph = y * pow1  # x == ph + pl + (exact quotient error) * pow1
    pl = _two_prod_err(y, pow1, ph)
    if d == 0.5 or d == -0.5:
        # exact quotient = y + err with sign(err) = sign(x - y * pow1)
        z = _settle_tie(y, z, (x - ph) - pl)
    elif y >= half_big or y <= -half_big:
        # integral y; the exact quotient is y +- 0.5 iff x == (y +- 0.5) * pow1
        s = x - ph
        half = pow1 / 2
        if s - half == pl:
            z = _even_neighbour(y, 0.5)
        elif s + half == pl:
            z = _even_neighbour(y, -0.5)
    z = z * pow1
    if z != z or z - z != 0:
        raise ValueError  # CPython: OverflowError("overflow occurred during round")
    return z
