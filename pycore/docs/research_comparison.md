# Research benchmark comparison

PyCore versus the CPython 3.14 baseline on the research set
(`pycore/tools/cpython_baseline/benchmarks/research/`).
Regenerate with `make research-compare`.

Recorded 2026-10-13 20:24 UTC.

## How to read the numbers

Cycles are the result. The hart's simulated time uses
**1000 MHz**. CPython's simulated time uses the baseline
machine clock (100.0 MHz, preset
`pycore`). A second time column puts both
cores at 1 GHz, so that ratio is the cycle ratio and the clock
assumption drops out.

The fair exec column is CPython `run_cold` (dispatch edge plus
opcode bodies plus C helpers, first execution) against PyCore's
run phase (on-device `exec` of the code object the hart just
compiled). PyCore does not specialize, so there is no warm exec.
CPython's `interpret` and `run` columns stay CPython-only: they
split an x86 instruction stream the hart does not have.

CPython leaves the garbage collector on. This hart run leaves it
off, which is the default `make run-file` configuration
(two-core, `CACHE_EN=1`, `CA_EN=1`, `MEM_LATENCY=4`).
List append, extend, mid-list delete, and dict/set growth run on the
container accelerator. Console output still crosses to the companion.
L1 hit rates on PyCore count the hart's own accesses during that
phase. LLC hit rate and branch MPKI are Callgrind results; the
phase mark does not count L2 misses or mispredicted branches.

`spectral_norm.py` had a non-ASCII character in a comment. The
on-device compiler raises `SyntaxError` on that, so the comment is
ASCII and the kernel is unchanged. `mandelbrot.py` iterates
`z = z*z + c` and bails out on `abs(z) > 2`. `binary_trees.py`
tested a leaf with `node == 0`. A list compared
with an int TYPE-traps, and a node is a non-empty list, so the test
is `not node`. The printed checksums are the ones in
`cpython_benchmarks.md`.

## Suite

| program | result | cpy compile | pyc compile | compile × | cpy exec | pyc exec | exec × | cpy L1D | pyc L1D | cpy L1I | pyc L1I | cpy LLC | disp% | c/bc cpy | c/bc pyc | pyc @1GHz | cpy @1GHz |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| binary_trees.py | PASS | 18,487,854 | 8,789,700 | 0.48x | 214,427,886 | 57,602,026 | 0.27x | 99.1% | 91.6% | 100.0% | 100.0% | 95.9% | 11.5% | 68.4 | 18.4 | 57.60 ms | 214.43 ms |
| fannkuch.py | PASS | 19,604,612 | 15,791,200 | 0.81x | 731,894,890 | 426,496,378 | 0.58x | 100.0% | 100.0% | 100.0% | 100.0% | 67.0% | 19.9% | 36.5 | 21.3 | 426.50 ms | 731.89 ms |
| fasta.py | PASS | 21,495,898 | 19,280,680 | 0.90x | 49,231,992 | 9,760,590 | 0.20x | 97.6% | 99.9% | 97.9% | 100.0% | 99.8% | 12.1% | 72.7 | 14.4 | 9.76 ms | 49.23 ms |
| knucleotide.py | PASS | 19,300,395 | 12,507,320 | 0.65x | 666,544,217 | 207,840,854 | 0.31x | 98.8% | 97.7% | 98.3% | 100.0% | 99.4% | 8.7% | 85.4 | 26.6 | 207.84 ms | 666.54 ms |
| mandelbrot.py | PASS | 17,778,611 | 6,718,180 | 0.38x | 2,521,745,519 | 438,200,030 | 0.17x | 95.1% | 100.0% | 96.9% | 100.0% | 100.0% | 8.0% | 115.7 | 20.1 | 438.20 ms | 2.522 s |
| monte_carlo.py | PASS | 20,204,437 | 16,328,220 | 0.81x | 1,221,867,850 | 190,494,990 | 0.16x | 96.0% | 100.0% | 96.7% | 100.0% | 100.0% | 11.0% | 87.3 | 13.6 | 190.49 ms | 1.222 s |
| nbody.py | PASS | 26,526,194 | 42,690,420 | 1.61x | 2,127,091,959 | 430,185,572 | 0.20x | 97.9% | 100.0% | 99.4% | 100.0% | 100.0% | 12.3% | 65.9 | 13.3 | 430.19 ms | 2.127 s |
| nqueens.py | PASS | 18,954,273 | 12,938,580 | 0.68x | 404,337,645 | 176,053,066 | 0.44x | 99.5% | 100.0% | 99.8% | 100.0% | 99.9% | 17.3% | 41.6 | 18.1 | 176.05 ms | 404.34 ms |
| sor.py | PASS | 19,462,198 | 15,209,000 | 0.78x | 296,375,829 | 115,473,570 | 0.39x | 98.3% | 97.4% | 99.6% | 100.0% | 96.9% | 11.1% | 70.7 | 27.5 | 115.47 ms | 296.38 ms |
| spectral_norm.py | PASS | 19,383,324 | 13,113,020 | 0.68x | 2,346,912,682 | 332,645,506 | 0.14x | 98.2% | 99.7% | 98.6% | 100.0% | 100.0% | 9.6% | 88.6 | 12.6 | 332.65 ms | 2.347 s |
| geomean | | | | | 627,682,760 | 161,542,937 | 0.26x | | | | | | | | | 161.54 ms | 627.68 ms |

`c/bc` divides cold-exec cycles by CPython's `sys.monitoring` count
of the same source. `exec ×` is PyCore run cycles divided by CPython
`run_cold` cycles. `disp%` is the dispatch edge's share of CPython's
cold-exec instructions. The geometric mean uses programs that
finished (PASS or MISMATCH) with a positive exec cycle count.

| program | cpy warm exec | cpy branch MPKI | pyc excore handoffs | pyc excore wait | excore share of exec |
| --- | ---: | ---: | ---: | ---: | ---: |
| binary_trees.py | 212,646,134 | 12.7 | 3 | 4,490 | 0.0% |
| fannkuch.py | 731,855,668 | 21.1 | 3 | 6,261 | 0.0% |
| fasta.py | 49,610,069 | 18.1 | 3 | 6,953 | 0.1% |
| knucleotide.py | 664,700,028 | 11.9 | 3 | 5,918 | 0.0% |
| mandelbrot.py | 2,503,282,955 | 11.3 | 3 | 5,855 | 0.0% |
| monte_carlo.py | 1,206,331,263 | 18.0 | 3 | 7,030 | 0.0% |
| nbody.py | 2,126,215,257 | 16.1 | 5 | 11,517 | 0.0% |
| nqueens.py | 403,655,237 | 20.6 | 3 | 6,365 | 0.0% |
| sor.py | 291,957,676 | 15.4 | 3 | 4,648 | 0.0% |
| spectral_norm.py | 2,365,211,790 | 13.3 | 3 | 4,521 | 0.0% |

Warm exec is CPython's second execution after PEP 659. Branch MPKI
is mispredicted conditional and indirect branches per thousand
retired x86 instructions on the cold exec. Excore wait is hart
cycles spent handing container and console work to the companion.

## Each measured result

### binary_trees.py

PyCore result: PASS. stdout matches.
PyCore stdout: `135854↵`
CPython stdout: `135854↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 18,487,854 | 8,789,700 | 0.48x |  |
| compile (cold) | time at 1 GHz | 18.49 ms | 8.79 ms | 0.48x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 184.88 ms | 8.79 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 12,918,630 | 290,690 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 30.24 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 68.4% | -30.2 pp |  |
| compile (cold) | L1I MPKI | 13.93 | 123.9 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.1% | 88.8% | -6.3 pp |  |
| compile (cold) | L1D MPKI | 20.44 | 221.4 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.1% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.68 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.49 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 2,764,105 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 2.76 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 27.64 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 1,798,485 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.54 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.0% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.51 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.54 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.64 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.75 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 43,996,690 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 44.00 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 439.97 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 19,958,219 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.20 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.07 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 99.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 3.02 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 73.92 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 170,431,196 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 170.43 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 1.704 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 153,976,329 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.11 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 0.23 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 99.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 4.11 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 95.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.19 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.74 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 214,427,886 | 57,602,026 | 0.27x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 214.43 ms | 57.60 ms | 0.27x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.144 s | 57.60 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 173,934,548 | 3,949,536 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.23 | 14.58 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 100.0% | 100.0% | +0.0 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 0.21 | 0.01 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 99.1% | 91.6% | -7.4 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 3.98 | 55.82 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 95.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.17 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 12.67 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 212,646,134 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 212.65 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.126 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 173,392,553 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.23 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 0.22 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.3% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 3.22 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 97.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.07 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 12.63 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.5% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 43,996,690 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 99,848,991 | - | - | no matching split on the hart |
| exec split | C helper cycles | 70,582,205 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,595 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 4,490 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 3,134,320 | 3,134,320 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 3,949,536 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 68.41 | 18.38 | 0.27x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.04 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 149 | 167 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 342 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (109544668); libpython3.14.so.1.0+0x1c77f0 (10190793); _PyEval_FrameClearAndPop (8151450); __tls_get_addr (6869214); libpython3.14.so.1.0+0x18f780 (5255834) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### fannkuch.py

PyCore result: PASS. stdout matches.
PyCore stdout: `22↵`
CPython stdout: `22↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,604,612 | 15,791,200 | 0.81x |  |
| compile (cold) | time at 1 GHz | 19.60 ms | 15.79 ms | 0.81x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 196.05 ms | 15.79 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,653,997 | 568,142 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.44 | 27.79 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 70.3% | -28.2 pp |  |
| compile (cold) | L1I MPKI | 14.46 | 114.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.1% | 89.4% | -5.7 pp |  |
| compile (cold) | L1D MPKI | 20.73 | 194.7 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.75 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.41 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,836,927 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.84 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 38.37 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,543,115 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.86 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.3% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.91 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 88.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.64 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.80 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 286,289,789 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 286.29 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.863 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 109,112,258 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.62 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.00 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 0.00 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 74.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 101.5 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 445,605,101 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 445.61 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 4.456 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 438,015,371 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.02 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 0.01 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 0.00 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 66.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 1.08 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 731,894,890 | 426,496,378 | 0.58x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 731.89 ms | 426.50 ms | 0.58x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 7.319 s | 426.50 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 547,127,629 | 53,754,568 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.34 | 7.93 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 100.0% | 100.0% | -0.0 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 0.00 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 100.0% | 100.0% | -0.0 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 0.00 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 67.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 21.10 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 731,855,668 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 731.86 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 7.319 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 547,111,248 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.34 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 0.00 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 0.00 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 86.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 21.10 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 19.9% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 286,289,789 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 400,623,440 | - | - | no matching split on the hart |
| exec split | C helper cycles | 44,981,661 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,390 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 6,261 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 20,068,392 | 20,068,392 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 53,754,568 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 36.47 | 21.25 | 0.58x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.27 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 222 | 496 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 433 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (502189586); libpython3.14.so.1.0+0x200330 (30405210); libpython3.14.so.1.0+0x1ff000 (14493580); _PyObject_MakeTpCall'2 (2767); __tls_get_addr (2387) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### fasta.py

PyCore result: PASS. stdout matches.
PyCore stdout: `961628↵`
CPython stdout: `961628↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 21,495,898 | 19,280,680 | 0.90x |  |
| compile (cold) | time at 1 GHz | 21.50 ms | 19.28 ms | 0.90x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 214.96 ms | 19.28 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 14,960,136 | 693,561 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.44 | 27.80 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.4% | 69.8% | -28.6 pp |  |
| compile (cold) | L1I MPKI | 16.22 | 116.6 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.6% | 89.2% | -6.5 pp |  |
| compile (cold) | L1D MPKI | 18.60 | 196.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 2.08 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.55 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 5,832,399 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 5.83 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 58.32 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 3,834,128 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.0% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.99 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.34 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 88.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.86 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.84 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 10,546,730 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 10.55 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 105.47 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,951,385 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.67 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 2.46 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 97.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 12.61 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 97.73 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 38,685,262 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 38.69 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 386.85 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 28,590,686 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.35 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 97.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 24.02 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 97.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 10.13 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.06 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 7.11 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 49,231,992 | 9,760,590 | 0.20x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 49.23 ms | 9.76 ms | 0.20x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 492.32 ms | 9.76 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 32,542,071 | 1,182,302 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.51 | 8.26 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 97.9% | 100.0% | +2.1 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 21.40 | 0.06 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.6% | 99.9% | +2.3 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 10.43 | 0.41 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.8% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.05 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 18.12 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 49,610,069 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 49.61 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 496.10 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 32,627,504 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 97.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 21.44 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.4% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 11.65 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 18.05 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.1% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 10,546,730 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 21,913,688 | - | - | no matching split on the hart |
| exec split | C helper cycles | 16,771,574 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,080 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 6,953 | 0.1% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 677,387 | 677,387 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 1,182,302 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 72.68 | 14.41 | 0.20x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 15.57 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 275 | 410 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 546 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (20077707); libpython3.14.so.1.0+0x197c90 (3330465); _Py_Dealloc (1815660); __tls_get_addr (1611214); libpython3.14.so.1.0+0x1dd5d0 (1056570) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### knucleotide.py

PyCore result: PASS. stdout matches.
PyCore stdout: `916380849↵`
CPython stdout: `916380849↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,300,395 | 12,507,320 | 0.65x |  |
| compile (cold) | time at 1 GHz | 19.30 ms | 12.51 ms | 0.65x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 193.00 ms | 12.51 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,466,776 | 449,012 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 27.86 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 71.5% | -27.1 pp |  |
| compile (cold) | L1I MPKI | 14.47 | 109.7 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.3% | 89.3% | -6.0 pp |  |
| compile (cold) | L1D MPKI | 19.90 | 194.2 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.91 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.56 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,574,324 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.57 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 35.74 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,340,545 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.98 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.85 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.67 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.67 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 109,415,349 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 109.42 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 1.094 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 43,201,448 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.63 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 97.2% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 13.26 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 87.96 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 557,128,868 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 557.13 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 5.571 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 452,041,690 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.23 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.2% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 18.05 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 99.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 4.47 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.4% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.14 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.64 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 666,544,217 | 207,840,854 | 0.31x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 666.54 ms | 207.84 ms | 0.31x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 6.665 s | 207.84 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 495,243,138 | 17,900,616 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.35 | 11.61 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.3% | 100.0% | +1.7 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 16.88 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.8% | 97.7% | -1.0 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 5.24 | 21.41 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.13 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 11.91 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 664,700,028 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 664.70 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 6.647 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 495,018,010 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.34 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.3% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 16.90 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 98.8% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 5.17 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.5% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.11 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 11.74 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 8.7% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 109,415,349 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 194,628,893 | - | - | no matching split on the hart |
| exec split | C helper cycles | 362,499,975 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,808 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 5,918 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 7,800,521 | 7,800,521 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 17,900,616 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 85.45 | 26.64 | 0.31x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.03 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 181 | 350 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 400 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (202039954); libpython3.14.so.1.0+0x197c90 (40384746); libpython3.14.so.1.0+0x190740 (39581359); libpython3.14.so.1.0+0x18fcd0 (29402280); _Py_Dealloc (29142582) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### mandelbrot.py

PyCore result: PASS. stdout matches.
PyCore stdout: `15899↵`
CPython stdout: `15899↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 17,778,611 | 6,718,180 | 0.38x |  |
| compile (cold) | time at 1 GHz | 17.78 ms | 6.72 ms | 0.38x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 177.79 ms | 6.72 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 12,465,566 | 216,472 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 31.03 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.7% | 66.0% | -32.7 pp |  |
| compile (cold) | L1I MPKI | 13.19 | 132.9 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.0% | 88.6% | -6.4 pp |  |
| compile (cold) | L1D MPKI | 20.63 | 230.5 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.1% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.65 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.43 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 2,058,890 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 2.06 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 20.59 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 1,346,512 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.00 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.7% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.39 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 84.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 6.20 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 14.28 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 353,452,685 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 353.45 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 3.535 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 130,013,672 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.72 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 98.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 15.46 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 88.4% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 52.77 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 77.56 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 2,168,292,834 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 2.168 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 21.683 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 1,488,014,119 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.46 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 96.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 32.07 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 95.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 20.73 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 5.48 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 2,521,745,519 | 438,200,030 | 0.17x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 2.522 s | 438.20 ms | 0.17x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 25.217 s | 438.20 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 1,618,027,791 | 36,640,810 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.56 | 11.96 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 96.9% | 100.0% | +3.1 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 30.73 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 95.1% | 100.0% | +4.9 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 23.30 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 100.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 11.27 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 2,503,282,955 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 2.503 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 25.033 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 1,618,063,533 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.55 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 96.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 30.73 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 95.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 20.40 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 11.82 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 8.0% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 353,452,685 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 806,245,498 | - | - | no matching split on the hart |
| exec split | C helper cycles | 1,362,047,336 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,450 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 5,855 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 21,799,712 | 21,799,712 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 36,640,810 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 115.7 | 20.10 | 0.17x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 16.21 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 112 | 121 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 216 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (651303197); libpython3.14.so.1.0+0x18ed50 (115603022); __tls_get_addr (95009200); _Py_Dealloc (90208944); PyObject_Malloc (76172850) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### monte_carlo.py

PyCore result: PASS. stdout matches.
PyCore stdout: `3135320↵`
CPython stdout: `3135320↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 20,204,437 | 16,328,220 | 0.81x |  |
| compile (cold) | time at 1 GHz | 20.20 ms | 16.33 ms | 0.81x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 202.04 ms | 16.33 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 14,073,561 | 541,709 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.44 | 30.14 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.5% | 67.8% | -30.7 pp |  |
| compile (cold) | L1I MPKI | 15.20 | 126.5 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.4% | 88.9% | -6.5 pp |  |
| compile (cold) | L1D MPKI | 19.49 | 221.9 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.93 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.57 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 4,485,264 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 4.49 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 44.85 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,949,467 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.39 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.85 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 87.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.12 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.22 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 220,727,226 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 220.73 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.207 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 81,750,922 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.70 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.1% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 9.49 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 95.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 21.51 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 92.69 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 1,001,140,624 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 1.001 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 10.011 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 660,860,067 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 96.4% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 36.40 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 96.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 17.03 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 8.81 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 1,221,867,850 | 190,494,990 | 0.16x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 1.222 s | 190.49 ms | 0.16x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 12.219 s | 190.49 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 742,610,989 | 22,391,393 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.65 | 8.51 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 96.7% | 100.0% | +3.3 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 33.43 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 96.0% | 100.0% | +4.0 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 17.53 | 0.01 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 100.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 18.04 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 1,206,331,263 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 1.206 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 12.063 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 742,655,001 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.62 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 96.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 33.43 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 96.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 14.53 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 18.04 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.0% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 220,727,226 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 467,673,621 | - | - | no matching split on the hart |
| exec split | C helper cycles | 533,467,003 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,800 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 7,030 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 13,993,169 | 13,993,169 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 22,391,393 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 87.32 | 13.61 | 0.16x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 15.77 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 244 | 321 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 544 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (398788910); libpython3.14.so.1.0+0x197c90 (53027238); __tls_get_addr (34488025); _PyLong_Frexp (33305328); _Py_Dealloc (28478688) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### nbody.py

PyCore result: PASS. stdout matches.
PyCore stdout: `-169075163↵-169089262↵`
CPython stdout: `-169075163↵-169089262↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 26,526,194 | 42,690,420 | 1.61x |  |
| compile (cold) | time at 1 GHz | 26.53 ms | 42.69 ms | 1.61x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 265.26 ms | 42.69 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 18,325,851 | 1,560,138 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.45 | 27.36 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.1% | 71.3% | -26.8 pp |  |
| compile (cold) | L1I MPKI | 18.58 | 108.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 96.0% | 88.8% | -7.2 pp |  |
| compile (cold) | L1D MPKI | 17.65 | 196.3 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 93.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 2.41 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.51 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 10,833,187 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 10.83 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 108.33 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 7,190,203 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.46 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.62 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 89.3% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.50 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.13 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 452,768,150 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 452.77 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 4.528 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 190,436,296 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.38 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 3.57 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 95.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 20.12 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 75.73 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 1,674,323,809 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 1.674 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 16.743 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 1,355,338,749 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.24 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 6.58 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.2% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 9.26 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 7.78 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 2,127,091,959 | 430,185,572 | 0.20x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 2.127 s | 430.19 ms | 0.20x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 21.271 s | 430.19 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 1,545,775,045 | 43,104,109 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.38 | 9.98 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.4% | 100.0% | +0.6 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 6.21 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.9% | 100.0% | +2.1 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 10.60 | 0.01 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 100.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 16.15 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 2,126,215,257 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 2.126 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 21.262 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 1,545,769,938 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.38 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.4% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 6.21 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 10.52 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 16.15 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.3% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 452,768,150 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 791,638,313 | - | - | no matching split on the hart |
| exec split | C helper cycles | 882,685,496 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,225 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 5 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 11,517 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 32,262,622 | 32,262,622 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 43,104,109 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 65.93 | 13.33 | 0.20x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.03 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 625 | 865 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 1,590 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (842876965); libpython3.14.so.1.0+0x227190 (187009667); PyFloat_FromDouble (172811936); __tls_get_addr (134866853); libpython3.14.so.1.0+0x2018f0 (72505575) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### nqueens.py

PyCore result: PASS. stdout matches.
PyCore stdout: `92↵`
CPython stdout: `92↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 18,954,273 | 12,938,580 | 0.68x |  |
| compile (cold) | time at 1 GHz | 18.95 ms | 12.94 ms | 0.68x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 189.54 ms | 12.94 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,247,301 | 450,276 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 28.73 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 69.8% | -28.8 pp |  |
| compile (cold) | L1I MPKI | 13.99 | 116.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.2% | 89.1% | -6.1 pp |  |
| compile (cold) | L1D MPKI | 20.32 | 204.2 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.7% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.80 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.46 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,203,888 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.20 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 32.04 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,123,579 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.52 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.50 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.39 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.38 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 142,458,488 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 142.46 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 1.425 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 51,793,908 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.75 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.78 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 1.06 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 108.6 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 261,879,157 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 261.88 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.619 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 246,833,270 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.06 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 2.05 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 99.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 1.90 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 2.08 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 404,337,645 | 176,053,066 | 0.44x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 404.34 ms | 176.05 ms | 0.44x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 4.043 s | 176.05 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 298,627,178 | 22,728,680 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.35 | 7.75 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.8% | 100.0% | +0.2 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 1.83 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 99.5% | 100.0% | +0.5 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 1.76 | 0.01 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 20.55 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 403,655,237 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 403.66 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 4.037 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 298,623,190 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.35 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.8% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 1.83 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 1.44 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 20.55 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 17.3% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 142,458,488 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 217,698,177 | - | - | no matching split on the hart |
| exec split | C helper cycles | 44,180,980 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,443 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 6,365 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 9,714,283 | 9,714,283 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 22,728,680 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 41.62 | 18.12 | 0.44x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.66 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 177 | 398 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 346 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (257695125); libpython3.14.so.1.0+0x197c90 (14611272); libpython3.14.so.1.0+0x200330 (11665290); PyNumber_Negative (4349165); libpython3.14.so.1.0+0x1c77f0 (2500217) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### sor.py

PyCore result: PASS. stdout matches.
PyCore stdout: `475119604↵`
CPython stdout: `475119604↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,462,198 | 15,209,000 | 0.78x |  |
| compile (cold) | time at 1 GHz | 19.46 ms | 15.21 ms | 0.78x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 194.62 ms | 15.21 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,638,692 | 531,388 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 28.62 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 70.1% | -28.4 pp |  |
| compile (cold) | L1I MPKI | 14.47 | 115.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.5% | 89.1% | -6.3 pp |  |
| compile (cold) | L1D MPKI | 19.15 | 203.5 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.93 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.50 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,784,846 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.78 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 37.85 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,511,842 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.94 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.7% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.30 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.30 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.18 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 68,441,755 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 68.44 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 684.42 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 24,583,722 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.78 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.39 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 96.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 17.23 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 102.0 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 227,934,074 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 227.93 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.279 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 197,136,343 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.16 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 4.17 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 7.34 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 96.2% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.43 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.62 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 296,375,829 | 115,473,570 | 0.39x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 296.38 ms | 115.47 ms | 0.39x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.964 s | 115.47 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 221,720,065 | 12,150,394 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.34 | 9.50 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.6% | 100.0% | +0.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 4.19 | 0.01 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.3% | 97.4% | -0.9 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 8.44 | 13.24 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 96.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.39 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 15.42 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 291,957,676 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 291.96 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 2.920 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 221,612,414 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.32 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 4.05 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 98.8% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 5.91 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 96.1% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.38 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 15.38 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.1% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 68,441,755 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 108,514,184 | - | - | no matching split on the hart |
| exec split | C helper cycles | 119,419,890 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,810 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 4,648 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 4,192,922 | 4,192,922 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 12,150,394 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 70.68 | 27.54 | 0.39x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 16.32 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 219 | 437 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 505 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (119193025); libpython3.14.so.1.0+0x227190 (35303913); PyFloat_FromDouble (25303501); __tls_get_addr (18442424); libpython3.14.so.1.0+0x197c90 (8459844) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### spectral_norm.py

PyCore result: PASS. stdout matches.
PyCore stdout: `1274222209↵`
CPython stdout: `1274222209↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,383,324 | 13,113,020 | 0.68x |  |
| compile (cold) | time at 1 GHz | 19.38 ms | 13.11 ms | 0.68x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 193.83 ms | 13.11 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,526,660 | 449,273 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 29.19 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 69.9% | -28.7 pp |  |
| compile (cold) | L1I MPKI | 14.34 | 117.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.3% | 89.0% | -6.2 pp |  |
| compile (cold) | L1D MPKI | 20.01 | 210.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.92 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.55 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,648,808 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.65 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 36.49 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,403,153 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.87 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.97 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 85.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.82 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.51 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 447,301,859 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 447.30 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 4.473 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 163,863,189 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.73 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 98.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 12.37 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 94.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 26.34 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 91.17 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 1,899,610,823 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 1.900 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 18.996 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 1,547,023,360 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.23 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 14.45 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 6.66 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 5.01 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 2,346,912,682 | 332,645,506 | 0.14x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 2.347 s | 332.65 ms | 0.14x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 23.469 s | 332.65 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 1,710,886,549 | 38,369,454 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.37 | 8.67 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.6% | 100.0% | +1.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 14.25 | 0.00 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.2% | 99.7% | +1.4 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 8.55 | 1.04 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 100.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 13.26 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 2,365,211,790 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 2.365 s | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 23.652 s | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 1,710,897,755 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.38 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 14.25 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 98.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 9.70 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 13.42 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 9.6% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 447,301,859 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 827,056,713 | - | - | no matching split on the hart |
| exec split | C helper cycles | 1,072,554,110 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,702 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 4,521 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 26,479,324 | 26,479,324 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 38,369,454 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 88.63 | 12.56 | 0.14x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 16.89 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 198 | 313 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 436 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (795933407); libpython3.14.so.1.0+0x197c90 (283396877); __tls_get_addr (132976866); _Py_Dealloc (112704228); libpython3.14.so.1.0+0x18ed50 (74084046) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |
