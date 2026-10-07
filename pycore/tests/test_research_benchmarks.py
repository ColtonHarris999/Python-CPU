"""The research benchmarks match the published algorithms and checksums.

These run on CPython directly. Callgrind is the baseline tool's job and is
not repeated here.
"""

from __future__ import annotations

import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1] / "tools" / "cpython_baseline" / "benchmarks" / "research"

# stdout of each program at the scale checked into the file.
_STDOUT = {
    "binary_trees.py": "25774\n",
    "fannkuch.py": "16\n",
    "fasta.py": "516277\n",
    "knucleotide.py": "73307453\n",
    "mandelbrot.py": "414\n",
    "monte_carlo.py": "3132800\n",
    "nbody.py": "-169075163\n-169026908\n",
    "nqueens.py": "40\n",
    "sor.py": "1047090603\n",
    "spectral_norm.py": "1273839840\n",
}


def _load(name: str):
    path = _ROOT / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _fannkuch_published(n: int) -> int:
    """pyperformance's fannkuch, including the slice-step reverse."""
    count = list(range(1, n + 1))
    max_flips = 0
    m = n - 1
    r = n
    perm1 = list(range(n))
    while True:
        while r != 1:
            count[r - 1] = r
            r -= 1
        if perm1[0] != 0 and perm1[m] != m:
            perm = perm1[:]
            flips = 0
            k = perm[0]
            while k:
                perm[: k + 1] = perm[k::-1]
                flips += 1
                k = perm[0]
            if flips > max_flips:
                max_flips = flips
        while r != n:
            perm1.insert(r, perm1.pop(0))
            count[r] -= 1
            if count[r] > 0:
                break
            r += 1
        else:
            return max_flips


class ResearchBenchmarkTest(unittest.TestCase):
    def test_programs_print_the_locked_checksums(self):
        for name, expected in _STDOUT.items():
            source = (_ROOT / name).read_text(encoding="utf-8")
            buf = io.StringIO()
            with redirect_stdout(buf):
                exec(compile(source, name, "exec"), {"__name__": "__main__"})
            self.assertEqual(buf.getvalue(), expected, name)

    def test_fannkuch_matches_the_published_slice_version(self):
        fn = _load("fannkuch").fannkuch
        for n in range(1, 8):
            self.assertEqual(fn(n), _fannkuch_published(n), n)

    def test_nqueens_matches_the_published_counts(self):
        fn = _load("nqueens").nqueens
        # n=1..8, the sequence pyperformance's permutation search produces.
        self.assertEqual([fn(n) for n in range(1, 9)], [1, 0, 0, 2, 10, 4, 40, 92])

    def test_binary_trees_matches_the_closed_form_check(self):
        fn = _load("binary_trees").binary_trees

        def closed(n, min_depth=4):
            max_depth = n if n > min_depth + 2 else min_depth + 2
            total = (1 << (max_depth + 2)) - 1
            depth = min_depth
            while depth <= max_depth:
                iterations = 1 << (max_depth - depth + min_depth)
                total += iterations * ((1 << (depth + 1)) - 1)
                depth += 2
            return total + (1 << (max_depth + 1)) - 1

        for n in (4, 6, 8):
            self.assertEqual(fn(n), closed(n), n)

    def test_nbody_matches_the_published_tuples(self):
        ours = _load("nbody").energies(20)
        ref = _nbody_ref(20)
        self.assertAlmostEqual(ours[0], ref[0], places=9)
        self.assertAlmostEqual(ours[1], ref[1], places=9)
        # The CLBG energy before any step, to 9 digits.
        self.assertEqual(int(ours[0] * 1e9), -169075163)

    def test_spectral_norm_matches_the_published_eval_a(self):
        ours = _load("spectral_norm").spectral_norm(8, 4)
        self.assertAlmostEqual(ours, _spectral_ref(8, 4), places=9)

    def test_monte_carlo_is_near_pi(self):
        est = _load("monte_carlo").monte_carlo(2000)
        self.assertGreater(est, 3.0)
        self.assertLess(est, 3.3)


def _nbody_ref(iterations: int):
    pi = 3.14159265358979323
    solar = 4 * pi * pi
    year = 365.24
    bodies = [
        ([0.0, 0.0, 0.0], [0.0, 0.0, 0.0], solar),
        (
            [4.84143144246472090e00, -1.16032004402742839e00, -1.03622044471123109e-01],
            [1.66007664274403694e-03 * year, 7.69901118419740425e-03 * year, -6.90460016972063023e-05 * year],
            9.54791938424326609e-04 * solar,
        ),
        (
            [8.34336671824457987e00, 4.12479856412430479e00, -4.03523417114321381e-01],
            [-2.76742510726862411e-03 * year, 4.99852801234917238e-03 * year, 2.30417297573763929e-05 * year],
            2.85885980666130812e-04 * solar,
        ),
        (
            [1.28943695621391310e01, -1.51111514016986312e01, -2.23307578892655734e-01],
            [2.96460137564761618e-03 * year, 2.37847173959480950e-03 * year, -2.96589568540237556e-05 * year],
            4.36624404335156298e-05 * solar,
        ),
        (
            [1.53796971148509165e01, -2.59193146099879641e01, 1.79258772950371181e-01],
            [2.68067772490389322e-03 * year, 1.62824170038242295e-03 * year, -9.51592254519715870e-05 * year],
            5.15138902046611451e-05 * solar,
        ),
    ]
    pairs = [(bodies[i], bodies[j]) for i in range(len(bodies) - 1) for j in range(i + 1, len(bodies))]
    px = py = pz = 0.0
    for _r, v, m in bodies:
        px -= v[0] * m
        py -= v[1] * m
        pz -= v[2] * m
    sun = bodies[0]
    sun[1][0] = px / sun[2]
    sun[1][1] = py / sun[2]
    sun[1][2] = pz / sun[2]

    def energy():
        e = 0.0
        for (r1, _v1, m1), (r2, _v2, m2) in pairs:
            dx = r1[0] - r2[0]
            dy = r1[1] - r2[1]
            dz = r1[2] - r2[2]
            e -= (m1 * m2) / ((dx * dx + dy * dy + dz * dz) ** 0.5)
        for _r, v, m in bodies:
            e += m * (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) / 2.0
        return e

    def advance(dt, n):
        for _ in range(n):
            for (r1, v1, m1), (r2, v2, m2) in pairs:
                dx = r1[0] - r2[0]
                dy = r1[1] - r2[1]
                dz = r1[2] - r2[2]
                mag = dt * ((dx * dx + dy * dy + dz * dz) ** (-1.5))
                b1m = m1 * mag
                b2m = m2 * mag
                v1[0] -= dx * b2m
                v1[1] -= dy * b2m
                v1[2] -= dz * b2m
                v2[0] += dx * b1m
                v2[1] += dy * b1m
                v2[2] += dz * b1m
            for r, v, _m in bodies:
                r[0] += dt * v[0]
                r[1] += dt * v[1]
                r[2] += dt * v[2]

    before = energy()
    advance(0.01, iterations)
    return before, energy()


def _spectral_ref(n: int, iters: int) -> float:
    def eval_a(i, j):
        return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)

    def times(at, u):
        out = []
        for i in range(len(u)):
            partial = 0.0
            for j, uj in enumerate(u):
                partial += (eval_a(j, i) if at else eval_a(i, j)) * uj
            out.append(partial)
        return out

    u = [1.0] * n
    for _ in range(iters):
        v = times(True, times(False, u))
        u = times(True, times(False, v))
    vbv = sum(ue * ve for ue, ve in zip(u, v))
    vv = sum(ve * ve for ve in v)
    return (vbv / vv) ** 0.5


if __name__ == "__main__":
    unittest.main()
