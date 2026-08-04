"""Convert a number or numeric string to an integer.

Supports: int(), int(x) for INT/BOOL (truthiness/identity via arithmetic),
and a minimal base-10 digit string parser for SHORT_STR ASCII digits.
Full CPython parsing (bases, signs, underscores) is partial.
"""


def int(x=0, base=None):
    if base is not None:
        # Non-decimal bases: only when x is a string of digits
        return _parse_int_string(x, base)
    # Numeric path: truncate toward zero via // 1 for floats; ints unchanged
    if x == 0:
        return 0
    # BOOL/INT: x // 1 works for INT; for BOOL True//1 → 1
    # FLOAT: toward-zero truncate
    if x >= 0:
        return x // 1
    # toward zero for negatives: -((-x) // 1) is floor for negatives in Python
    # use (x / 1) truncated: for Python // is floor.
    # Toward-zero: 
    q = x // 1
    if q < 0:
        if q * 1 != x:
            return q + 1
    return q


def _parse_int_string(s, base):
    if base == 0:
        base = 10
    neg = 0
    n = 0
    started = 0
    for ch in s:
        # Character iteration yields one-char SHORT_STR values.
        # Compare against digit literals.
        val = -1
        if ch == "-":
            if started == 0:
                neg = 1
                continue
            raise 1
        if ch == "+":
            if started == 0:
                continue
            raise 1
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
        elif ch == "a":
            val = 10
        elif ch == "b":
            val = 11
        elif ch == "c":
            val = 12
        elif ch == "d":
            val = 13
        elif ch == "e":
            val = 14
        elif ch == "f":
            val = 15
        elif ch == "A":
            val = 10
        elif ch == "B":
            val = 11
        elif ch == "C":
            val = 12
        elif ch == "D":
            val = 13
        elif ch == "E":
            val = 14
        elif ch == "F":
            val = 15
        if val < 0:
            raise 1
        if val >= base:
            raise 1
        n = n * base + val
        started = 1
    if started == 0:
        raise 1
    if neg:
        return -n
    return n
