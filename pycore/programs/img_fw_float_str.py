"""Firmware float(): numeric promotion and correctly rounded str parsing.

Covers the Clinger fast path, the double-double path (1e23, 18-digit
mantissas, DBL_MAX and subnormal edges), inf / nan spellings, whitespace
and underscores, and ValueError on malformed strings.
"""


def rejects(s):
    try:
        float(s)
    except ValueError:
        return 1
    return 0


def managed_entry():
    total = 0
    if float(7) == 7.0:
        total += 1
    if float(True) == 1.0:
        total += 2
    if float("1.5") == 1.5:
        total += 4
    if float("-2.5e3") == -2500.0:
        total += 8
    if float("  .25  ") == 0.25:
        total += 16
    if float("1_000") == 1000.0:
        total += 32
    if float("0.1") == 0.1:
        total += 64
    if float("1e23") == 1e23:
        total += 128
    if float("9007199254740993") == 9007199254740992.0:
        total += 256
    if float("123456789012345678e-5") == 1234567890123.45678:
        total += 512
    if float("2.2250738585072011e-308") == 2.2250738585072011e-308:
        total += 1024
    if float("4.9e-324") == 5e-324:
        total += 2048
    if float("1.7976931348623158e308") == 1.7976931348623157e308:
        total += 4096
    if float("1e400") > 1e308:
        total += 8192
    x = float("nan")
    if x != x:
        total += 16384
    if float("-Infinity") < -1e308:
        total += 32768
    total += rejects("1..2") * 65536
    total += rejects("") * 131072
    total += rejects("1__0") * 262144
    return total


managed_entry()
