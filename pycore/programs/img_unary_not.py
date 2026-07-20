# Exercises UNARY_NOT via assignment form `a = not x` (TO_BOOL + UNARY_NOT).
#
# Do not use `if not x:` — CPython peepholes that to TO_BOOL + POP_JUMP_IF_TRUE
# with no UNARY_NOT.  Bit-score: not 0 / not False take (+1, +8); not 5 /
# not True skip → host golden 9.


def managed_entry():
    z = 0
    n = 5
    t = True
    f = False
    a = not z
    b = not n
    c = not t
    d = not f
    out = 0
    if a:
        out += 1
    if b:
        out += 2
    if c:
        out += 4
    if d:
        out += 8
    return out


managed_entry()
