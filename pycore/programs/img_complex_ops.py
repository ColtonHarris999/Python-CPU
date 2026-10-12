# complex(), literals, .real/.imag, and abs() on a complex.
# The 4x4 count is the published iteration at limit 20 (9 pixels).
# Host golden is this function's return.


def inside(cr, ci):
    z = 0j
    c = complex(cr, ci)
    i = 0
    while i < 20:
        z = z * z + c
        if abs(z) > 2.0:
            return 0
        i = i + 1
    return 1


def managed_entry():
    z = 3 + 4j
    out = 0
    if z.real == 3.0:
        out = out + 1
    if z.imag == 4.0:
        out = out + 2
    if abs(z) == 5.0:
        out = out + 4
    c = complex(1, -2)
    if c.real == 1.0:
        out = out + 8
    if c.imag == -2.0:
        out = out + 16
    if complex() == 0j:
        out = out + 32
    w = complex(1 + 2j)
    if w.real == 1.0:
        if w.imag == 2.0:
            out = out + 64
    if complex(True) == (1 + 0j):
        out = out + 128
    if (1j * 1j) == (-1 + 0j):
        out = out + 256
    if abs(-3) == 3:
        out = out + 512
    if abs(-1.5) == 1.5:
        out = out + 1024
    n = 0
    y = 0
    while y < 4:
        ci = 2.0 * y / 4.0 - 1.0
        x = 0
        while x < 4:
            cr = 2.0 * x / 4.0 - 1.5
            n = n + inside(cr, ci)
            x = x + 1
        y = y + 1
    if n == 9:
        out = out + 2048
    return out


managed_entry()
