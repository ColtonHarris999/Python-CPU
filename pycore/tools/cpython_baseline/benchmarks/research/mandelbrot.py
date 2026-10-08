# Computer Language Benchmarks Game, mandelbrot.
# The usual Python 3 entry maps each pixel to a complex c and iterates
# z = z*z + c up to 50 times, emitting a 1 bit when |z| stays <= 2.
# Complex numbers and the PBM writer are not used: two floats, and a count
# of the pixels that stay inside. Official pictures are 200 to 16000 on a
# side. SIZE=32 keeps the 50-iteration limit and finishes under Callgrind.

SIZE = 32
LIMIT = 50


def inside(cr, ci):
    zr = 0.0
    zi = 0.0
    tr = 0.0
    ti = 0.0
    i = 0
    while i < LIMIT:
        zi = 2.0 * zr * zi + ci
        zr = tr - ti + cr
        tr = zr * zr
        ti = zi * zi
        if tr + ti > 4.0:
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
