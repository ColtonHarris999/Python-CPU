"""Convert a number to floating point (``x * 1.0``).

String parsing: ``_parse_float_string(s)`` for ASCII decimal literals.
Automatic str-vs-number dispatch needs a runtime tag probe (blocked).
"""


def float(x=0.0):
    return x * 1.0


def _parse_float_string(s):
    neg = 0
    started = 0
    value = 0.0
    frac = 0.0
    place = 0.1
    in_frac = 0
    for ch in s:
        if ch == "-":
            if started == 0:
                neg = 1
                continue
            raise 1
        if ch == "+":
            if started == 0:
                continue
            raise 1
        if ch == ".":
            if in_frac:
                raise 1
            in_frac = 1
            started = 1
            continue
        val = -1
        if ch == "0":
            val = 0
        elif ch == "1":
            val = 1
        elif ch == "2":
            val = 2
        elif ch == "3":
            val = 3
        elif ch == "4":
            val = 4
        elif ch == "5":
            val = 5
        elif ch == "6":
            val = 6
        elif ch == "7":
            val = 7
        elif ch == "8":
            val = 8
        elif ch == "9":
            val = 9
        if val < 0:
            raise 1
        started = 1
        if in_frac:
            frac = frac + val * place
            place = place * 0.1
        else:
            value = value * 10.0 + val * 1.0
    if started == 0:
        raise 1
    result = value + frac
    if neg:
        return -result
    return result
