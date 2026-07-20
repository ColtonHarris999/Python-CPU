# Exercises TO_BOOL across INT (0 / nonzero), BOOL, and FLOAT (0.0 / nonzero).
#
# Each `if <local>:` emits TO_BOOL then POP_JUMP_IF_FALSE.  Falsy INT skips
# +1, truthy INT takes +10, truthy BOOL takes +100, falsy FLOAT (0.0) skips
# +1000, truthy FLOAT takes +10000 -> host golden 10110.  The FLOAT cases
# prove the mantissa/exponent truth path (0.0 is falsy; 2.5 is truthy).
# A broken conversion (wrong tag rewrite or wrong truth table) fails the
# entry-return check.


def managed_entry():
    z = 0
    n = 5
    b = True
    fz = 0.0
    fnz = 2.5
    out = 0
    if z:
        out += 1
    if n:
        out += 10
    if b:
        out += 100
    if fz:
        out += 1000
    if fnz:
        out += 10000
    return out


managed_entry()
