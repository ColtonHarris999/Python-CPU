# CPython research benchmarks

The programs in `pycore/tools/cpython_baseline/benchmarks/research/` are the
algorithmic benchmarks interpreter and CPU papers actually time. The same
files are what PyCore should run later: no `import`, no `class`, no
`yield`, no slice step, and a one-integer checksum so the print sink can
emit it. `compiler_subset.check_source` accepts every file.

`make cpython-baseline` stays the short smoke test (a dispatch loop, integer
fib, a dict, a list sum). It is not this set.

## Where the set comes from

CPython's own numbers, and most interpreter papers since Unladen Swallow,
use **pyperformance**. That suite absorbed the PyPy / Unladen Swallow
kernels and the programs from the **Computer Language Benchmarks Game**.
The numeric group inside pyperformance is **SciMark 2.0** (Roldan Pozo,
NIST). A paper that says "we ran the Python benchmark suite" means
pyperformance's geometric mean. One that says "n-body, spectral-norm,
fannkuch, mandelbrot" means the Benchmarks Game.

The whole of pyperformance does not fit this machine yet. The programs
below are the kernels from that suite that are a loop, a recursion, or a
dict, rather than an imported application.

| Program | Origin | What it stresses | Official size | Size here |
| --- | --- | --- | --- | --- |
| `nbody.py` | pyperformance `bm_nbody`, Benchmarks Game | float pairs, the solar-system advance | 20,000 steps | 200 steps |
| `spectral_norm.py` | pyperformance `bm_spectral_norm`, Benchmarks Game | nested float matvec, `eval_A` | n=130, 10 iterations | n=20, 10 iterations |
| `fannkuch.py` | pyperformance `bm_fannkuch`, Benchmarks Game | integer permutation walk | n=9 (30 flips) | n=7 (16 flips) |
| `nqueens.py` | pyperformance `bm_nqueens` | every permutation, diagonal sets | 8 queens (92) | 7 queens (40) |
| `mandelbrot.py` | Benchmarks Game | float inner loop, early exit | 200–16,000 on a side, 50 iters | 32 on a side, 50 iters |
| `binary_trees.py` | Benchmarks Game | recursive allocation and a tree walk | argument up to 21 | argument 8 |
| `fasta.py` | Benchmarks Game | the benchmark's own LCG and a cumulative-probability pick | ALU 2n, IUB 3n, n≥1000 | ALU once, 5,000 IUB bases |
| `knucleotide.py` | Benchmarks Game | dict updates on 1- and 2-mers | a multi-megabyte FASTA record | ALU repeated to 8,000 bases |
| `monte_carlo.py` | pyperformance `scimark_monte_carlo` | SciMark's lagged-Fibonacci RNG, a circle test | 100,000 samples | 5,000 samples |
| `sor.py` | pyperformance `scimark_sor` | successive over-relaxation on a grid | n=100, 10 cycles, zero grid | n=48, 6 cycles, a fixed pattern |

The formulas are the published ones. The cuts are the iteration count or
the grid size, so a Callgrind run finishes. A later PyCore run should use
these files at these sizes. A larger size is a different measurement.

Adaptations, so the file stays in the grammar. Each one is checked against
the published behavior:

- `fannkuch` reverses a prefix with index swaps. The published line is
  `perm[:k+1] = perm[k::-1]`, and a slice step is not in the grammar.
  The rotate is the same move as `list.insert` / `list.pop`. Max-flips
  for n=1..7 matches the slice version (0, 1, 2, 4, 7, 10, 16).
- `nqueens` counts with Heap's algorithm instead of
  `itertools.permutations`. Both visit every permutation once. Counts for
  n=1..8 are 1, 0, 0, 2, 10, 4, 40, 92.
- `monte_carlo` uses floor division in SciMark's 17-word generator.
  pyperformance writes `/`, which is true division in Python 3. The
  Java/C kernel is integral. The estimate at 2,000 samples is 3.106.
- `sor` fills the grid with `(13x + 7y) mod 100 / 100` instead of zeros.
  pyperformance's zero grid makes the reduction 0. The stencil is the
  published `SOR_execute` with omega 1.25.
- `binary_trees` uses a two-element list as a node and `0` as a leaf.
  The published program is a `Tree` class. The check value is the same
  closed form, `2^(d+1) - 1`.
- `nbody` keeps the five published bodies and `advance(0.01, n)`. Pairs
  are index pairs. Energy before any step, scaled by 1e9, is
  `-169075163`, which is the Benchmarks Game's `-0.169075164`.

## Not in this set

These are the other names a paper will mention. They are not here because
the current grammar or the int64 ALU cannot run them. Add them when the
missing piece lands; do not rewrite them into something else and keep the
name.

| Benchmark | Why it waits |
| --- | --- |
| richards, deltablue, raytrace, chaos, float, go | `class`. Richards is the one to add first: it is the interpreter benchmark papers quote beside the Benchmarks Game. |
| pidigits | arbitrary-precision integers. PyCore's int is int64. The spigot's intermediates do not fit. |
| scimark_fft, scimark_lu | `math.sin` / `math.sqrt`, or `array`. The SOR and Monte Carlo kernels do not need them. |
| django_template, sqlalchemy, pickle, regex, html5lib, xml_etree, logging, pathlib, 2to3, sympy, nbody's neighbors in the application group | an `import` of the standard library or a third-party application |

## Checksums

Each program prints integers only. `nbody` prints two lines: energy before
the advance, then energy after, each scaled by 1e9 and truncated toward
zero. The others print one line.

| Program | stdout |
| --- | --- |
| `binary_trees.py` | `25774` |
| `fannkuch.py` | `16` |
| `fasta.py` | `516277` |
| `knucleotide.py` | `73307453` |
| `mandelbrot.py` | `414` |
| `monte_carlo.py` | `3132800` |
| `nbody.py` | `-169075163` then `-169026908` |
| `nqueens.py` | `40` |
| `sor.py` | `1047090603` |
| `spectral_norm.py` | `1273839840` |

`monte_carlo`'s line is `int(pi_estimate * 1e6)`, so `3132800` is 3.1328.
`spectral_norm`'s line is `int(norm * 1e9)`. `fasta` and `knucleotide` are
order-independent sums (`ord` of each base, and count weighted by the
key's character codes). A PyCore run that prints a different integer is a
failed run, not a faster one. Float kernels can disagree in the last bits
of the scaled integer if the FPU rounding differs; that difference should
be reported, not folded into the cycle count.

## How to run

```bash
make cpython-baseline-research
make cpython-baseline-research CPYTHON_BASELINE_MACHINE=skylake
PYTHONPATH=pycore/tools python3.14 -m cpython_baseline.baseline \
    --research --machine pycore --json build/cpython_research.json
```

Needs Python 3.14, valgrind, gcc, and binutils, same as the micro suite.
`PYTHONHASHSEED=0` and `PYTHON_JIT=0` are pinned. The garbage collector
stays on. One Callgrind run of fannkuch(7) is the long one; the set is
minutes, not the multi-hour official pyperformance job.

The cycle model, the cache penalties, and the meaning of `interpret` are
in `pycore/tools/cpython_baseline/README.md`. Compare a PyCore run with
**compile_cold** and with **run_cold** (the cold exec, which is
`interpret` + `run`). The warm exec is the steady state after PEP 659 has
rewritten the code object. PyCore does not specialize, so the cold exec is
the fair column.

`make research-compare` runs this set on the hart and under this tool,
then writes `pycore/docs/research_comparison.md`. The hart's time column
uses `PYCORE_RESEARCH_MHZ` (default 1000). A finished program is kept;
`FORCE=1` measures it again.

## Results on the `pycore` preset

Machine: 8KB 4-way L1I, 8KB 4-way L1D, 128KB 8-way L2, 64B lines,
`P_L1=7`, `P_LLC=4`, `P_br=16`, 100 MHz. CPython 3.14.8, JIT off, hash
seed 0. Cycles are the simple-core model on Callgrind's events, not host
wall time.

All ten programs printed the checksums above. Dispatch is the jump-table
edge (263 sites in `_PyEval_EvalFrameDefault`), not the whole eval
function. The instrumentation arm was 5,337 instructions, under the
100,000-instruction leak ceiling.

| program | compile | interpret | run | exec | L1D | LLC | disp% |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| binary_trees.py | 18,419,698 | 8,367,361 | 36,101,283 | 44,468,644 | 99.2% | 98.4% | 10.7% |
| fannkuch.py | 19,290,462 | 30,364,966 | 51,218,732 | 81,583,698 | 99.5% | 99.3% | 19.2% |
| fasta.py | 20,346,906 | 7,128,583 | 24,825,574 | 31,954,157 | 97.8% | 99.7% | 12.9% |
| knucleotide.py | 19,263,262 | 8,708,179 | 43,900,378 | 52,608,557 | 98.6% | 99.5% | 8.9% |
| mandelbrot.py | 17,986,546 | 12,652,474 | 50,141,063 | 62,793,537 | 98.9% | 99.7% | 11.3% |
| monte_carlo.py | 20,164,135 | 10,966,728 | 50,134,995 | 61,101,723 | 96.1% | 99.9% | 11.0% |
| nbody.py | 26,606,505 | 4,527,787 | 17,116,031 | 21,643,818 | 97.8% | 99.2% | 12.3% |
| nqueens.py | 18,947,634 | 18,224,929 | 67,364,732 | 85,589,661 | 97.3% | 99.9% | 12.6% |
| sor.py | 19,529,132 | 9,406,351 | 32,451,109 | 41,857,460 | 98.4% | 98.7% | 11.1% |
| spectral_norm.py | 19,331,086 | 10,570,905 | 39,744,098 | 50,315,003 | 98.1% | 99.8% | 10.8% |
| geomean | | | | 49,664,206 | | | 11.8% |

`compile` is the cold `compile()`. `interpret` is the dispatch edge of the
cold exec. `run` is inline opcode bodies plus C helpers. `exec` is their
sum (`run_cold`). L1D and LLC are hit rates on the cold exec. `disp%` is
the dispatch edge's share of cold-exec instructions. The geometric mean is
over the ten cold execs.

| program | warm exec | cycles / bytecode | branch MPKI |
| --- | ---: | ---: | ---: |
| binary_trees.py | 44,500,672 | 71.6 | 11.92 |
| fannkuch.py | 81,604,669 | 38.2 | 20.86 |
| fasta.py | 32,284,010 | 65.6 | 17.87 |
| knucleotide.py | 52,579,223 | 84.2 | 11.87 |
| mandelbrot.py | 62,219,504 | 70.6 | 13.66 |
| monte_carlo.py | 60,906,361 | 87.2 | 17.94 |
| nbody.py | 21,613,750 | 66.6 | 16.17 |
| nqueens.py | 85,841,221 | 63.3 | 15.33 |
| sor.py | 41,363,932 | 69.9 | 15.19 |
| spectral_norm.py | 50,849,291 | 78.3 | 13.14 |

`warm exec` is the second exec of the same code object, after PEP 659 has
had one run to specialize it. On this set it stays within about 1.2% of
the cold exec: these kernels are already tight arithmetic, and the second
pass does not remove the C helpers. `cycles / bytecode` divides the cold
exec by a native `sys.monitoring` count of the same source. Branch MPKI is
mispredicted conditional and indirect branches per thousand retired
instructions on the cold exec.

fannkuch is the branch-heavy end (19.2% dispatch, 20.9 branch MPKI).
knucleotide is the dict end (8.9% dispatch, most of the exec in C helpers).
nqueens is the largest cold exec, because every permutation builds two
sets. monte_carlo has the lowest L1 hit rates (L1I 96.6%, L1D 96.1%): the
17-word generator plus the accept test does not stay as hot as the
straight-line float kernels. nbody's compile is the expensive one
(26.6M cycles) because the source carries the five published initial
conditions.
