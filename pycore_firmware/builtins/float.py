"""Convert a number or string to floating point.

``float(x)`` probes the argument tag with ``_bi_code_kind``: SHORT_STR (7)
/ LONG_STR (8) go through ``_float_from_str``, everything else is
``x * 1.0`` (INT / BOOL / FLOAT; other tags TYPE-trap like CPython's
TypeError).  Strings follow CPython: optional surrounding whitespace,
``[+-]digits[.digits][e[+-]digits]`` with single underscores between
digits, and ``inf`` / ``infinity`` / ``nan`` in any case.

Every module-level helper here is also a ROM builtins-dict entry (see
``ROM_FIRMWARE_BUILTINS``): ROM code resolves names through LOAD_GLOBAL,
so a helper must be a dict key to be callable on the device.

The parser is correctly rounded for inputs of at most 18 significant
digits over the whole double range (verified bit-exact against CPython on
random and edge inputs).  The digits are accumulated exactly as an int;
when they fit 2 ** 53 and the decimal exponent is within +-22 the result
is one correctly rounded multiply or divide by an exact power of ten
(Clinger's fast path).  Otherwise the value is formed in double-double
arithmetic (~106 bits) with 10 ** n built by square-and-multiply, scaled
by 2 ** 600 for subnormal results and by 2 ** -64 next to DBL_MAX so the
final rounding is the only one.  More than 18 significant digits are
truncated to a sticky bit: the result is still right unless the exact
value sits within about 1e-18 relative of a rounding boundary (CPython's
dtoa is exact for any length; see ``pycore/docs/limitations.md``).
"""


def float(x=0.0):
    k = _bi_code_kind(x)
    if k == 7 or k == 8:
        return _float_from_str(x)
    return x * 1.0


def _digit(ch):
    if ch == "0":
        return 0
    if ch == "1":
        return 1
    if ch == "2":
        return 2
    if ch == "3":
        return 3
    if ch == "4":
        return 4
    if ch == "5":
        return 5
    if ch == "6":
        return 6
    if ch == "7":
        return 7
    if ch == "8":
        return 8
    if ch == "9":
        return 9
    return -1


def _ten_pow(n):
    # Exact for n <= 22: every such 10 ** n is a double.
    p = 1.0
    while n > 0:
        p = p * 10.0
        n = n - 1
    return p


# --- double-double helpers (error-free transformations) -------------------
# A value is held as hi + lo with |lo| <= ulp(hi) / 2, about 106 bits.  All
# of this is plain IEEE + - * /, so it runs on the FPU as is.


def _two_sum(a, b):
    s = a + b
    bb = s - a
    e = (a - (s - bb)) + (b - bb)
    return s, e


def _split(a):
    # Veltkamp: a == h + l with h and l both 26-bit.  (2 ** 27 + 1) * a
    # overflows above ~6.7e299, so scale by an exact power of two there.
    if a > 6.7e299 or a < -6.7e299:
        a = a * 3.725290298461914e-09  # 2 ** -28
        c = 134217729.0 * a
        h = c - (c - a)
        return h * 268435456.0, (a - h) * 268435456.0  # 2 ** 28
    c = 134217729.0 * a
    h = c - (c - a)
    return h, a - h


def _two_prod(a, b):
    # a * b == p + e exactly (Dekker).
    p = a * b
    if p != p or p - p != 0:
        return p, 0.0  # overflow: the error term would be nan
    ah, al = _split(a)
    bh, bl = _split(b)
    e = ((ah * bh - p) + ah * bl + al * bh) + al * bl
    return p, e


def _dd_mul(ah, al, bh, bl):
    p, e = _two_prod(ah, bh)
    if p != p or p - p != 0:
        return p, 0.0  # inf (or nan) stays as it is
    e = e + (ah * bl + al * bh)
    return _two_sum(p, e)


def _dd_div(nh, nl, dh, dl):
    # (nh + nl) / (dh + dl): one quotient, one exact remainder, one correction.
    q = nh / dh
    ph, pl = _two_prod(q, dh)
    rem = ((nh - ph) - pl) + (nl - q * dl)
    return _two_sum(q, rem / dh)


def _pow10_dd(n):
    # 10 ** n as a double-double, square-and-multiply from the exact 10.0.
    rh = 1.0
    rl = 0.0
    bh = 10.0
    bl = 0.0
    while n > 0:
        if n % 2 == 1:
            rh, rl = _dd_mul(rh, rl, bh, bl)
        n = n // 2
        if n > 0:
            bh, bl = _dd_mul(bh, bl, bh, bl)
    return rh, rl


def _special(word, neg):
    inf = 1e308 * 10.0
    if word == "inf" or word == "Inf" or word == "INF":
        v = inf
    elif word == "infinity" or word == "Infinity" or word == "INFINITY":
        v = inf
    elif word == "nan" or word == "NaN" or word == "NAN":
        v = inf - inf
    else:
        raise ValueError
    if neg:
        return -v
    return v


def _is_space(ch):
    if ch == " " or ch == "\t" or ch == "\n" or ch == "\r":
        return 1
    if ch == "\x0b" or ch == "\x0c":
        return 1
    return 0


def _float_from_str(s):
    neg = 0
    sign_seen = 0
    started = 0  # a mantissa digit has been seen
    mant = 0  # significant digits as an exact int (at most 18)
    ndig = 0
    exp10 = 0  # decimal exponent to apply to mant
    in_frac = 0
    in_exp = 0
    exp_sign_seen = 0
    exp_digits = 0
    exp_neg = 0
    exp_val = 0
    sticky = 0  # a nonzero digit was dropped past the 18th
    word = ""  # letters of an inf / nan spelling
    done = 0  # trailing whitespace reached; only more whitespace may follow
    after_digit = 0  # the previous character was a digit
    need_digit = 0  # the previous character was "_"
    for ch in s:
        if done:
            if _is_space(ch):
                continue
            raise ValueError
        if _is_space(ch):
            if need_digit:
                raise ValueError
            if sign_seen or started or in_frac or in_exp or word != "":
                done = 1
            continue
        if ch == "_":
            if after_digit == 0:
                raise ValueError
            after_digit = 0
            need_digit = 1
            continue
        if word != "":
            word = word + ch
            continue
        val = _digit(ch)
        if val < 0:
            if need_digit:
                raise ValueError
            after_digit = 0
            if in_exp:
                if (ch == "-" or ch == "+") and exp_sign_seen == 0 and exp_digits == 0:
                    exp_sign_seen = 1
                    if ch == "-":
                        exp_neg = 1
                    continue
                raise ValueError
            if ch == "-" or ch == "+":
                if sign_seen or started or in_frac:
                    raise ValueError
                sign_seen = 1
                if ch == "-":
                    neg = 1
                continue
            if ch == ".":
                if in_frac:
                    raise ValueError
                in_frac = 1
                continue
            if ch == "e" or ch == "E":
                if started == 0:
                    raise ValueError
                in_exp = 1
                continue
            if started == 0 and in_frac == 0:
                word = ch
                continue
            raise ValueError
        after_digit = 1
        need_digit = 0
        if in_exp:
            exp_digits = exp_digits + 1
            if exp_val < 100000:
                exp_val = exp_val * 10 + val
            continue
        started = 1
        if ndig < 18:
            if mant != 0 or val != 0:
                mant = mant * 10 + val
                ndig = ndig + 1
            if in_frac:
                exp10 = exp10 - 1
        else:
            if in_frac == 0:
                exp10 = exp10 + 1
            if val != 0:
                sticky = 1
    if need_digit:
        raise ValueError
    if word != "":
        return _special(word, neg)
    if started == 0:
        raise ValueError
    if in_exp and exp_digits == 0:
        raise ValueError
    if exp_neg:
        exp10 = exp10 - exp_val
    else:
        exp10 = exp10 + exp_val
    return _scale(mant, exp10, neg, sticky)


def _scale(mant, exp10, neg, sticky):
    # A set sticky flag implies 18 digits, so mant > 2 ** 53 and only the
    # double-double paths below can see it.
    if mant == 0:
        result = 0.0
    elif exp10 >= 0:
        # Fold tens into the int while it stays below 2 ** 53 (exact).
        while exp10 > 22 and mant < 900719925474099:
            mant = mant * 10
            exp10 = exp10 - 1
        if exp10 <= 22 and mant <= 9007199254740992:
            # Clinger: one correctly rounded multiply of two exact doubles
            result = (mant * 1.0) * _ten_pow(exp10)
        elif exp10 > 330:
            result = 1e308 * 10.0
        else:
            mh, ml = _dd_int(mant, sticky)
            ph, pl = _pow10_dd(exp10)
            if exp10 > 280:
                # Near DBL_MAX the 53-bit product can overflow although the
                # exact value still rounds down to it: form the product
                # 2 ** 64 smaller and scale back (exact unless it overflows).
                mh = mh * 5.421010862427522e-20
                ml = ml * 5.421010862427522e-20
                result, _ = _dd_mul(mh, ml, ph, pl)
                result = result * 18446744073709551616.0
            else:
                result, _ = _dd_mul(mh, ml, ph, pl)
    else:
        k = -exp10
        if k <= 22 and mant <= 9007199254740992:
            result = (mant * 1.0) / _ten_pow(k)
        elif k > 400:
            result = 0.0
        else:
            nh, nl = _dd_int(mant, sticky)
            scaled = 0
            if k >= 300:
                # The result may be subnormal, where the quotient itself
                # would round coarsely: form it 2 ** 600 larger (exact) in
                # the normal range and scale down once at the end.
                nh = nh * 4.149515568880993e180
                nl = nl * 4.149515568880993e180
                scaled = 1
            while k > 290:
                # 10 ** k is not a double there: peel exact factors of 1e22
                nh, nl = _dd_div(nh, nl, 1e22, 0.0)
                k = k - 22
            ph, pl = _pow10_dd(k)
            s, e = _dd_div(nh, nl, ph, pl)
            if scaled:
                result = _unscale(s, e)
            else:
                result = s
    if neg:
        return -result
    return result


def _unscale(s, e):
    # (s + e) * 2 ** -600 rounded once.  s * 2 ** -600 is exact unless it
    # lands in the subnormal range, where its own rounding is right except
    # on an exact midpoint of that coarser grid (|d| == 2 ** -475 scaled);
    # there the sign of e decides, and e == 0 keeps the tie-to-even choice.
    r = s * 2.409919865102884e-181  # 2 ** -600
    back = r * 4.149515568880993e180  # exact: r has at most 53 bits
    d = back - s  # exact: back and s are within one ulp of each other
    if d == 0 or e == 0:
        return r
    if d != 1.0250665447337477e-143 and d != -1.0250665447337477e-143:
        return r
    if (d > 0) == (e > 0):
        return r  # r already lies on the side of the exact value
    return (back - (d + d)) * 2.409919865102884e-181


def _dd_int(mant, sticky):
    # An int below 10 ** 18 as a double-double, exactly.  With sticky set
    # the true value lies strictly inside (mant, mant + 1); mant + 0.5 is
    # in the same interval and never on a decimal tie.
    hi = mant * 1.0
    lo = (mant - int(hi)) * 1.0
    if sticky:
        lo = lo + 0.5
    return hi, lo
