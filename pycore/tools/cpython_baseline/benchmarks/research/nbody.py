# pyperformance bm_nbody, from the Computer Language Benchmarks Game.
# Kevin Carson; modified by Tupteq, Fredrik Johansson, and Daniel Nanz.
#
# Official timed work is advance(0.01, 20000) on the five-body solar system.
# ITERATIONS is lower so Callgrind finishes. The masses, the initial state,
# and the advance/energy formulas are the published ones.
#
# No import and no class: pairs are index pairs, not slices. The checksum is
# the two energies (before and after the advance) scaled by 1e9 and truncated
# toward zero, one integer per line. PyCore print takes an int.

ITERATIONS = 200

PI = 3.14159265358979323
SOLAR_MASS = 4 * PI * PI
DAYS_PER_YEAR = 365.24


def make_bodies():
    return [
        [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS],
        [
            4.84143144246472090e00,
            -1.16032004402742839e00,
            -1.03622044471123109e-01,
            1.66007664274403694e-03 * DAYS_PER_YEAR,
            7.69901118419740425e-03 * DAYS_PER_YEAR,
            -6.90460016972063023e-05 * DAYS_PER_YEAR,
            9.54791938424326609e-04 * SOLAR_MASS,
        ],
        [
            8.34336671824457987e00,
            4.12479856412430479e00,
            -4.03523417114321381e-01,
            -2.76742510726862411e-03 * DAYS_PER_YEAR,
            4.99852801234917238e-03 * DAYS_PER_YEAR,
            2.30417297573763929e-05 * DAYS_PER_YEAR,
            2.85885980666130812e-04 * SOLAR_MASS,
        ],
        [
            1.28943695621391310e01,
            -1.51111514016986312e01,
            -2.23307578892655734e-01,
            2.96460137564761618e-03 * DAYS_PER_YEAR,
            2.37847173959480950e-03 * DAYS_PER_YEAR,
            -2.96589568540237556e-05 * DAYS_PER_YEAR,
            4.36624404335156298e-05 * SOLAR_MASS,
        ],
        [
            1.53796971148509165e01,
            -2.59193146099879641e01,
            1.79258772950371181e-01,
            2.68067772490389322e-03 * DAYS_PER_YEAR,
            1.62824170038242295e-03 * DAYS_PER_YEAR,
            -9.51592254519715870e-05 * DAYS_PER_YEAR,
            5.15138902046611451e-05 * SOLAR_MASS,
        ],
    ]


def pair_indexes(n):
    pairs = []
    i = 0
    while i < n - 1:
        j = i + 1
        while j < n:
            pairs.append([i, j])
            j = j + 1
        i = i + 1
    return pairs


def offset_momentum(bodies):
    px = 0.0
    py = 0.0
    pz = 0.0
    i = 0
    while i < len(bodies):
        b = bodies[i]
        px = px - b[3] * b[6]
        py = py - b[4] * b[6]
        pz = pz - b[5] * b[6]
        i = i + 1
    sun = bodies[0]
    sun[3] = px / sun[6]
    sun[4] = py / sun[6]
    sun[5] = pz / sun[6]


def advance(bodies, pairs, dt, n):
    step = 0
    while step < n:
        p = 0
        while p < len(pairs):
            i = pairs[p][0]
            j = pairs[p][1]
            b1 = bodies[i]
            b2 = bodies[j]
            dx = b1[0] - b2[0]
            dy = b1[1] - b2[1]
            dz = b1[2] - b2[2]
            mag = dt * ((dx * dx + dy * dy + dz * dz) ** (-1.5))
            b1m = b1[6] * mag
            b2m = b2[6] * mag
            b1[3] = b1[3] - dx * b2m
            b1[4] = b1[4] - dy * b2m
            b1[5] = b1[5] - dz * b2m
            b2[3] = b2[3] + dx * b1m
            b2[4] = b2[4] + dy * b1m
            b2[5] = b2[5] + dz * b1m
            p = p + 1
        i = 0
        while i < len(bodies):
            b = bodies[i]
            b[0] = b[0] + dt * b[3]
            b[1] = b[1] + dt * b[4]
            b[2] = b[2] + dt * b[5]
            i = i + 1
        step = step + 1


def energy(bodies, pairs):
    e = 0.0
    p = 0
    while p < len(pairs):
        b1 = bodies[pairs[p][0]]
        b2 = bodies[pairs[p][1]]
        dx = b1[0] - b2[0]
        dy = b1[1] - b2[1]
        dz = b1[2] - b2[2]
        dist = (dx * dx + dy * dy + dz * dz) ** 0.5
        e = e - (b1[6] * b2[6]) / dist
        p = p + 1
    i = 0
    while i < len(bodies):
        b = bodies[i]
        e = e + b[6] * (b[3] * b[3] + b[4] * b[4] + b[5] * b[5]) / 2.0
        i = i + 1
    return e


def energies(iterations):
    bodies = make_bodies()
    pairs = pair_indexes(len(bodies))
    offset_momentum(bodies)
    before = energy(bodies, pairs)
    advance(bodies, pairs, 0.01, iterations)
    after = energy(bodies, pairs)
    return before, after


def scaled(value):
    return int(value * 1000000000.0)


if __name__ == "__main__":
    before, after = energies(ITERATIONS)
    print(scaled(before))
    print(scaled(after))
