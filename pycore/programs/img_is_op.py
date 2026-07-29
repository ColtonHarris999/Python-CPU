# Exercises IS_OP (is / is not) across INT, BOOL, None, and LIST handles.
#
# Bit-score: each true condition adds a power of two.  Host golden is 251
# (1+2+8+16+32+64+128).  Avoid `x is None` / `x is not None` — CPython
# peepholes those to unsupported POP_JUMP_IF_*_NONE.


def managed_entry():
    a = 1
    b = 2
    t = True
    f = False
    n = None
    m = None
    x = []
    one = 1
    out = 0
    if a is a:
        out += 1
    if a is not b:
        out += 2
    if t is f:
        out += 4
    if t is True:
        out += 8
    if n is m:
        out += 16
    if t is not one:
        out += 32
    if x is x:
        out += 64
    y = []
    z = []
    if y is not z:
        out += 128
    return out


managed_entry()
