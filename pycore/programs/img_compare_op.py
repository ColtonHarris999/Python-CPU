"""COMPARE_OP across all CPython 3.14 selectors and packed forms.

Expression assignments emit the six non-coercing opargs; direct ``if``
conditions emit the six force-bool forms.  The remaining comparisons cover
BOOL, FLOAT, and small mixed numeric operands.  Host CPython supplies the
golden score through run_image_test.py.
"""


def managed_entry():
    a = 2
    b = 3
    truth = True
    falsehood = False
    x = 2.5
    y = 3.5

    raw_lt = a < b
    raw_le = a <= a
    raw_eq = a == a
    raw_ne = a != b
    raw_gt = b > a
    raw_ge = b >= b

    out = 0
    if raw_lt:
        out += 1
    if raw_le:
        out += 2
    if raw_eq:
        out += 4
    if raw_ne:
        out += 8
    if raw_gt:
        out += 16
    if raw_ge:
        out += 32

    if a < b:
        out += 64
    if a <= a:
        out += 128
    if a == a:
        out += 256
    if a != b:
        out += 512
    if b > a:
        out += 1024
    if b >= b:
        out += 2048

    if truth > falsehood:
        out += 4096
    if truth == a:
        out += 8192
    if x < y:
        out += 16384
    if a < y:
        out += 32768
    return out


managed_entry()
