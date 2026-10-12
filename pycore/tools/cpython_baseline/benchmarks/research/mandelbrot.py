# Computer Language Benchmarks Game, mandelbrot.
# The published iteration is z = z*z + c with a bailout of abs(z) > 2.
# This file does that computation: a complex literal, complex(), and abs().
# The PBM writer (sys.argv, import, bytes) is still later. Official pictures
# are 200 to 16000 on a side. SIZE=32 keeps the 50-iteration limit and
# finishes under Callgrind. The inside-pixel count at this size is the same
# 414 the old squared test printed.

SIZE = 32
LIMIT = 50


def inside(cr, ci):
    z = 0j
    c = complex(cr, ci)
    i = 0
    while i < LIMIT:
        z = z * z + c
        if abs(z) > 2.0:
            return 0
        i = i + 1
    return 1


def mandelbrot(size):
    count = 0
    y = 0
    while y < size:
        ci = 2.0 * y / size - 1.0
        x = 0
        while x < size:
            cr = 2.0 * x / size - 1.5
            count = count + inside(cr, ci)
            x = x + 1
        y = y + 1
    return count


if __name__ == "__main__":
    print(mandelbrot(SIZE))
