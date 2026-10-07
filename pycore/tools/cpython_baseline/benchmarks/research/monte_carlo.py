# pyperformance scimark_monte_carlo, SciMark 2.0 (Roldan Pozo, NIST).
# Estimate pi by the fraction of uniform points that fall in the unit quarter
# circle. Official sample count is 100000, inside pyperf's outer loop.
# SAMPLES=5000 keeps the same generator and test and finishes under Callgrind.
#
# The generator is SciMark's 17-word lagged Fibonacci, seed 113. pyperformance
# writes the recurrence with true division; the integer recurrence below is
# the Java/C kernel (floor division), so the state stays integral.
# Checksum: the pi estimate, scaled by 1e6 and truncated toward zero.

SAMPLES = 5000

M1 = (1 << (32 - 2)) + ((1 << (32 - 2)) - 1)
M2 = 1 << (32 // 2)


def rng_init(seed):
    if seed < 0:
        seed = -seed
    if seed < M1:
        jseed = seed
    else:
        jseed = M1
    if jseed % 2 == 0:
        jseed = jseed - 1
    k0 = 9069 % M2
    k1 = 9069 // M2
    j0 = jseed % M2
    j1 = jseed // M2
    state = []
    i = 0
    while i < 17:
        jseed = j0 * k0
        j1 = (jseed // M2 + j0 * k1 + j1 * k0) % (M2 // 2)
        j0 = jseed % M2
        state.append(j0 + M2 * j1)
        i = i + 1
    return [state, 4, 16]


def rng_next(rng):
    state = rng[0]
    i = rng[1]
    j = rng[2]
    k = state[i] - state[j]
    if k < 0:
        k = k + M1
    state[j] = k
    if i == 0:
        i = 16
    else:
        i = i - 1
    if j == 0:
        j = 16
    else:
        j = j - 1
    rng[1] = i
    rng[2] = j
    return (1.0 / M1) * k


def monte_carlo(samples):
    rng = rng_init(113)
    under = 0
    i = 0
    while i < samples:
        x = rng_next(rng)
        y = rng_next(rng)
        if x * x + y * y <= 1.0:
            under = under + 1
        i = i + 1
    return under / samples * 4.0


if __name__ == "__main__":
    print(int(monte_carlo(SAMPLES) * 1000000.0))
