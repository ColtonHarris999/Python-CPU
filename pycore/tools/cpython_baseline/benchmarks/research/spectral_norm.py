# pyperformance bm_spectral_norm, from the Computer Language Benchmarks Game.
# Sebastien Loisel; fixed by Isaac Gouy; sped up by Josh Goldfoot.
# MathWorld Hundred-Dollar Challenge, problem 3.
#
# Official size is n=130, ten applications of AᵀA. N=20 keeps that iteration
# count and finishes under Callgrind. eval_A and the power iteration are the
# published ones.
# Checksum: the spectral norm, scaled by 1e9 and truncated toward zero.

N = 20
ITERS = 10


def eval_a(i, j):
    return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)


def times_u(at, u):
    n = len(u)
    out = []
    i = 0
    while i < n:
        partial = 0.0
        j = 0
        while j < n:
            if at:
                a = eval_a(j, i)
            else:
                a = eval_a(i, j)
            partial = partial + a * u[j]
            j = j + 1
        out.append(partial)
        i = i + 1
    return out


def ata_times_u(u):
    return times_u(True, times_u(False, u))


def spectral_norm(n, iters):
    u = []
    i = 0
    while i < n:
        u.append(1.0)
        i = i + 1
    k = 0
    while k < iters:
        v = ata_times_u(u)
        u = ata_times_u(v)
        k = k + 1
    vbv = 0.0
    vv = 0.0
    i = 0
    while i < n:
        vbv = vbv + u[i] * v[i]
        vv = vv + v[i] * v[i]
        i = i + 1
    return (vbv / vv) ** 0.5


if __name__ == "__main__":
    print(int(spectral_norm(N, ITERS) * 1000000000.0))
