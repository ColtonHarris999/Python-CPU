# Research benchmark comparison

PyCore versus the CPython 3.14 baseline on the research set
(`pycore/tools/cpython_baseline/benchmarks/research/`).
Regenerate with `make research-compare`.

Recorded 2026-10-12 21:15 UTC.

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
| binary_trees.py | PASS | 18,485,324 | 8,744,320 | 0.47x | 40,146,092 | 10,747,022 | 0.27x | 99.1% | 92.3% | 100.0% | 100.0% | 98.4% | 11.7% | 67.4 | 18.1 | 10.75 ms | 40.15 ms |
| fannkuch.py | PASS | 19,308,514 | 14,800,840 | 0.77x | 81,050,672 | 50,604,450 | 0.62x | 99.8% | 98.3% | 99.9% | 100.0% | 98.9% | 19.2% | 38.0 | 23.7 | 50.60 ms | 81.05 ms |
| fasta.py | PASS | 20,263,096 | 15,575,140 | 0.77x | 32,138,262 | 7,182,614 | 0.22x | 97.5% | 99.9% | 98.0% | 100.0% | 99.7% | 12.9% | 65.9 | 14.7 | 7.18 ms | 32.14 ms |
| knucleotide.py | PASS | 19,301,437 | 12,495,060 | 0.65x | 52,448,196 | 16,434,590 | 0.31x | 98.7% | 97.9% | 98.3% | 100.0% | 99.4% | 8.9% | 84.0 | 26.3 | 16.43 ms | 52.45 ms |
| mandelbrot.py | PASS | 17,779,988 | 6,720,900 | 0.38x | 64,712,633 | 11,176,958 | 0.17x | 95.1% | 100.0% | 96.9% | 100.0% | 99.9% | 8.0% | 115.4 | 19.9 | 11.18 ms | 64.71 ms |
| monte_carlo.py | PASS | 20,209,341 | 16,336,020 | 0.81x | 61,214,933 | 9,554,830 | 0.16x | 96.0% | 100.0% | 96.6% | 100.0% | 99.9% | 11.0% | 87.4 | 13.6 | 9.55 ms | 61.21 ms |
| nbody.py | PASS | 26,512,822 | 42,888,520 | 1.62x | 21,672,984 | 4,386,404 | 0.20x | 97.7% | 99.9% | 99.4% | 99.8% | 99.2% | 12.3% | 66.6 | 13.5 | 4.39 ms | 21.67 ms |
| nqueens.py | PASS | 18,978,883 | 12,721,120 | 0.67x | 85,067,765 | 55,074,898 | 0.65x | 97.6% | 95.3% | 98.4% | 100.0% | 99.9% | 12.6% | 62.9 | 40.7 | 55.07 ms | 85.07 ms |
| sor.py | PASS | 19,462,995 | 15,301,840 | 0.79x | 41,595,489 | 15,698,642 | 0.38x | 98.7% | 98.3% | 99.5% | 100.0% | 98.6% | 11.1% | 69.4 | 26.2 | 15.70 ms | 41.60 ms |
| spectral_norm.py | PASS | 19,381,976 | 13,118,920 | 0.68x | 50,468,495 | 8,232,062 | 0.16x | 98.0% | 99.2% | 98.7% | 100.0% | 99.8% | 10.8% | 78.5 | 12.8 | 8.23 ms | 50.47 ms |
| geomean | | | | | 49,257,794 | 13,584,692 | 0.28x | | | | | | | | | 13.58 ms | 49.26 ms |

`c/bc` divides cold-exec cycles by CPython's `sys.monitoring` count
of the same source. `exec ×` is PyCore run cycles divided by CPython
`run_cold` cycles. `disp%` is the dispatch edge's share of CPython's
cold-exec instructions. The geometric mean uses programs that
finished (PASS or MISMATCH) with a positive exec cycle count.

| program | cpy warm exec | cpy branch MPKI | pyc excore handoffs | pyc excore wait | excore share of exec |
| --- | ---: | ---: | ---: | ---: | ---: |
| binary_trees.py | 40,139,093 | 12.8 | 3 | 4,464 | 0.0% |
| fannkuch.py | 81,071,441 | 20.9 | 3 | 8,789 | 0.0% |
| fasta.py | 32,363,257 | 17.9 | 3 | 7,861 | 0.1% |
| knucleotide.py | 52,535,211 | 11.9 | 3 | 5,458 | 0.0% |
| mandelbrot.py | 64,301,578 | 11.3 | 3 | 5,154 | 0.0% |
| monte_carlo.py | 60,505,652 | 17.9 | 3 | 7,301 | 0.1% |
| nbody.py | 21,657,112 | 16.2 | 5 | 11,535 | 0.3% |
| nqueens.py | 84,829,965 | 15.3 | 3 | 8,547 | 0.0% |
| sor.py | 41,083,847 | 15.2 | 3 | 4,494 | 0.0% |
| spectral_norm.py | 50,778,111 | 13.1 | 3 | 8,971 | 0.1% |

Warm exec is CPython's second execution after PEP 659. Branch MPKI
is mispredicted conditional and indirect branches per thousand
retired x86 instructions on the cold exec. Excore wait is hart
cycles spent handing container and console work to the companion.

## Each measured result

### binary_trees.py

PyCore result: PASS. stdout matches.
PyCore stdout: `25774↵`
CPython stdout: `25774↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 18,485,324 | 8,744,320 | 0.47x |  |
| compile (cold) | time at 1 GHz | 18.49 ms | 8.74 ms | 0.47x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 184.85 ms | 8.74 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 12,915,232 | 289,079 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 30.25 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 68.2% | -30.4 pp |  |
| compile (cold) | L1I MPKI | 13.93 | 124.6 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.1% | 88.9% | -6.2 pp |  |
| compile (cold) | L1D MPKI | 20.46 | 220.8 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.1% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.68 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.49 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 2,760,338 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 2.76 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 27.60 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 1,795,234 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.54 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.0% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.59 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.43 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.65 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.80 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 8,364,130 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 8.36 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 83.64 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,789,168 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.21 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.09 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 99.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 3.14 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 74.05 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 31,781,962 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 31.78 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 317.82 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 28,655,603 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.11 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 0.39 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 99.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 4.28 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 98.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.08 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.76 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 40,146,092 | 10,747,022 | 0.27x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 40.15 ms | 10.75 ms | 0.27x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 401.46 ms | 10.75 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 32,444,771 | 750,017 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.24 | 14.33 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 100.0% | 100.0% | +0.0 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 0.35 | 0.05 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 99.1% | 92.3% | -6.8 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 4.14 | 51.43 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 98.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.07 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 12.85 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 40,139,093 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 40.14 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 401.39 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 32,474,248 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.24 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 0.40 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.1% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 3.94 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.04 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 12.84 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.7% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 8,364,130 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 18,992,337 | - | - | no matching split on the hart |
| exec split | C helper cycles | 12,789,625 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,591 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 4,464 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 595,286 | 595,286 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 750,017 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 67.44 | 18.05 | 0.27x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.05 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 149 | 167 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 342 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (20793400); libpython3.14.so.1.0+0x1c77f0 (1933769); _PyEval_FrameClearAndPop (1546650); __tls_get_addr (1186218); libpython3.14.so.1.0+0x18f780 (1001882) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### fannkuch.py

PyCore result: PASS. stdout matches.
PyCore stdout: `16↵`
CPython stdout: `16↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,308,514 | 14,800,840 | 0.77x |  |
| compile (cold) | time at 1 GHz | 19.31 ms | 14.80 ms | 0.77x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 193.09 ms | 14.80 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,502,248 | 528,464 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 28.01 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 70.4% | -28.2 pp |  |
| compile (cold) | L1I MPKI | 14.34 | 113.8 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.2% | 89.2% | -6.0 pp |  |
| compile (cold) | L1D MPKI | 20.04 | 197.9 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.0% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.72 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.41 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,588,180 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.59 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 35.88 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,388,917 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.50 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.95 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.84 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 88.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.57 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.82 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 30,258,773 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 30.26 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 302.59 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 11,551,938 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.62 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.65 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 0.65 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 100.6 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 50,791,899 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 50.79 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 507.92 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 48,648,172 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.04 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 1.20 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 99.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 0.71 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 98.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 1.92 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 81,050,672 | 50,604,450 | 0.62x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 81.05 ms | 50.60 ms | 0.62x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 810.51 ms | 50.60 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 60,200,110 | 5,386,106 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.35 | 9.40 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.9% | 100.0% | +0.1 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 1.09 | 0.01 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 99.8% | 98.3% | -1.5 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 0.70 | 9.39 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 98.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 20.86 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 81,071,441 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 81.07 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 810.71 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 60,184,275 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.35 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 1.08 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.8% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 0.69 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 20.92 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 19.2% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 30,258,773 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 42,709,914 | - | - | no matching split on the hart |
| exec split | C helper cycles | 8,081,985 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,499 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 8,789 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 2,135,521 | 2,135,521 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 5,386,106 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 37.95 | 23.70 | 0.62x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.17 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 208 | 462 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 410 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (52821755); libpython3.14.so.1.0+0x200330 (3161190); libpython3.14.so.1.0+0x1ff000 (1434940); libpython3.14.so.1.0+0x18b5b0 (629574); libpython3.14.so.1.0+0x18f780 (465330) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### fasta.py

PyCore result: PASS. stdout matches.
PyCore stdout: `516277↵`
CPython stdout: `516277↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 20,263,096 | 15,575,140 | 0.77x |  |
| compile (cold) | time at 1 GHz | 20.26 ms | 15.58 ms | 0.77x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 202.63 ms | 15.58 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 14,158,738 | 556,334 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 28.00 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.5% | 69.4% | -29.1 pp |  |
| compile (cold) | L1I MPKI | 15.38 | 118.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.6% | 89.3% | -6.3 pp |  |
| compile (cold) | L1D MPKI | 18.87 | 197.2 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.92 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.48 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 4,609,905 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 4.61 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 46.10 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 3,039,828 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.0% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.86 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.73 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 88.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.91 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.86 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 7,226,191 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 7.23 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 72.26 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 2,766,150 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.61 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 1.86 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 96.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 17.07 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 92.49 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 24,912,071 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 24.91 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 249.12 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 18,654,292 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.34 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 97.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 22.57 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 97.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 9.74 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.09 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 6.81 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 32,138,262 | 7,182,614 | 0.22x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 32.14 ms | 7.18 ms | 0.22x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 321.38 ms | 7.18 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 21,420,442 | 878,641 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.50 | 8.17 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.0% | 100.0% | +2.0 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 19.89 | 0.08 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.5% | 99.9% | +2.4 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 10.69 | 0.37 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.7% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.08 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 17.87 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 32,363,257 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 32.36 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 323.63 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 21,504,578 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.50 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 19.95 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.3% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 11.48 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.03 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 17.80 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.9% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 7,226,191 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 14,767,821 | - | - | no matching split on the hart |
| exec split | C helper cycles | 10,144,250 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,069 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 7,861 | 0.1% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 487,405 | 487,405 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 878,641 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 65.94 | 14.74 | 0.22x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.83 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 225 | 353 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 449 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (13996945); libpython3.14.so.1.0+0x197c90 (2107432); _Py_Dealloc (1052688); __tls_get_addr (940632); libpython3.14.so.1.0+0x1dd5d0 (601680) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### knucleotide.py

PyCore result: PASS. stdout matches.
PyCore stdout: `73307453↵`
CPython stdout: `73307453↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,301,437 | 12,495,060 | 0.65x |  |
| compile (cold) | time at 1 GHz | 19.30 ms | 12.50 ms | 0.65x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 193.01 ms | 12.50 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,466,726 | 448,685 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 27.85 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 71.5% | -27.1 pp |  |
| compile (cold) | L1I MPKI | 14.48 | 109.8 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.3% | 89.3% | -6.0 pp |  |
| compile (cold) | L1D MPKI | 19.90 | 194.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.92 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.56 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,574,488 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.57 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 35.74 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,340,317 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.99 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.88 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.66 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.66 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 8,751,223 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 8.75 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 87.51 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,457,287 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.66 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 97.2% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 12.99 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 87.97 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 43,696,973 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 43.70 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 436.97 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 35,450,302 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.23 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.2% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 18.29 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 4.68 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.4% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.14 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.45 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 52,448,196 | 16,434,590 | 0.31x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 52.45 ms | 16.43 ms | 0.31x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 524.48 ms | 16.43 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 38,907,589 | 1,432,616 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.35 | 11.47 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.3% | 100.0% | +1.7 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 17.08 | 0.05 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.7% | 97.9% | -0.9 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 5.42 | 20.01 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.13 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 11.87 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 52,535,211 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 52.54 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 525.35 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 38,921,143 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.35 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.3% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 17.10 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 98.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 6.11 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.5% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.11 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 11.68 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 8.9% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 8,751,223 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 15,507,828 | - | - | no matching split on the hart |
| exec split | C helper cycles | 28,189,145 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,813 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 5,458 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 624,521 | 624,521 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 1,432,616 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 83.98 | 26.32 | 0.31x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.01 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 181 | 350 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 400 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (16183862); libpython3.14.so.1.0+0x190740 (3168619); libpython3.14.so.1.0+0x197c90 (3031836); libpython3.14.so.1.0+0x18fcd0 (2354280); _Py_Dealloc (2102268) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### mandelbrot.py

PyCore result: PASS. stdout matches.
PyCore stdout: `414↵`
CPython stdout: `414↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 17,779,988 | 6,720,900 | 0.38x |  |
| compile (cold) | time at 1 GHz | 17.78 ms | 6.72 ms | 0.38x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 177.80 ms | 6.72 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 12,468,560 | 217,732 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 30.87 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.7% | 66.1% | -32.6 pp |  |
| compile (cold) | L1I MPKI | 13.18 | 132.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.0% | 88.7% | -6.4 pp |  |
| compile (cold) | L1D MPKI | 20.61 | 228.8 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.1% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.65 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.43 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 2,062,868 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 2.06 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 20.63 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 1,349,425 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.95 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.48 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 84.3% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 6.18 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 14.25 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 9,090,568 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 9.09 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 90.91 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,342,797 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.72 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 98.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 15.47 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 88.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 52.58 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 77.69 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 55,622,065 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 55.62 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 556.22 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 38,193,217 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.46 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 96.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 31.98 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 95.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 20.64 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.04 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 5.49 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 64,712,633 | 11,176,958 | 0.17x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 64.71 ms | 11.18 ms | 0.17x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 647.13 ms | 11.18 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 41,536,014 | 942,200 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.56 | 11.86 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 96.9% | 100.0% | +3.0 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 30.65 | 0.04 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 95.1% | 100.0% | +4.9 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 23.21 | 0.17 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.04 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 11.30 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 64,301,578 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 64.30 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 643.02 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 41,571,756 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.55 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 96.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 30.68 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 95.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 20.38 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 11.83 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 8.0% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 9,090,568 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 20,710,919 | - | - | no matching split on the hart |
| exec split | C helper cycles | 34,911,146 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,554 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 5,154 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 560,710 | 560,710 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 942,200 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 115.4 | 19.93 | 0.17x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 16.21 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 112 | 121 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 216 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (16748698); libpython3.14.so.1.0+0x18ed50 (2970502); __tls_get_addr (2430098); _Py_Dealloc (2301180); PyObject_Malloc (1957254) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### monte_carlo.py

PyCore result: PASS. stdout matches.
PyCore stdout: `3132800↵`
CPython stdout: `3132800↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 20,209,341 | 16,336,020 | 0.81x |  |
| compile (cold) | time at 1 GHz | 20.21 ms | 16.34 ms | 0.81x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 202.09 ms | 16.34 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 14,076,641 | 542,916 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.44 | 30.09 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.5% | 67.9% | -30.6 pp |  |
| compile (cold) | L1I MPKI | 15.19 | 126.2 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.4% | 88.9% | -6.5 pp |  |
| compile (cold) | L1D MPKI | 19.52 | 221.5 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.93 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.56 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 4,491,294 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 4.49 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 44.91 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,952,982 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.37 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.95 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 87.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.11 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.20 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 11,049,010 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 11.05 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 110.49 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 4,090,937 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.70 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 9.58 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 95.4% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 21.35 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 92.77 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 50,165,923 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 50.17 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 501.66 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 33,083,904 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 96.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 36.89 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 96.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 16.98 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.06 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 8.69 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 61,214,933 | 9,554,830 | 0.16x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 61.21 ms | 9.55 ms | 0.16x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 612.15 ms | 9.55 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 37,174,841 | 1,120,638 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.65 | 8.53 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 96.6% | 100.0% | +3.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 33.88 | 0.06 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 96.0% | 100.0% | +3.9 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 17.47 | 0.19 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.05 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 17.94 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 60,505,652 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 60.51 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 605.06 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 37,214,396 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.63 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 96.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 33.78 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 96.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 14.62 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 17.94 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.0% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 11,049,010 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 23,458,026 | - | - | no matching split on the hart |
| exec split | C helper cycles | 26,707,897 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,854 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 7,301 | 0.1% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 700,534 | 700,534 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 1,120,638 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 87.38 | 13.64 | 0.16x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 15.77 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 244 | 321 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 544 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (19976798); libpython3.14.so.1.0+0x197c90 (2651277); __tls_get_addr (1716385); _PyLong_Frexp (1667775); _Py_Dealloc (1408554) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### nbody.py

PyCore result: PASS. stdout matches.
PyCore stdout: `-169075163↵-169026908↵`
CPython stdout: `-169075163↵-169026908↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 26,512,822 | 42,888,520 | 1.62x |  |
| compile (cold) | time at 1 GHz | 26.51 ms | 42.89 ms | 1.62x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 265.13 ms | 42.89 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 18,323,817 | 1,560,053 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.45 | 27.49 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.1% | 71.3% | -26.8 pp |  |
| compile (cold) | L1I MPKI | 18.58 | 108.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 96.0% | 88.7% | -7.3 pp |  |
| compile (cold) | L1D MPKI | 17.58 | 198.5 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 93.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 2.41 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.51 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 10,825,099 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 10.83 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 108.25 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 7,183,891 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.46 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.71 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 89.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.42 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.12 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 4,564,908 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 4.56 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 45.65 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 1,920,319 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.38 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 3.52 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 95.7% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 19.50 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.04 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 75.99 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 17,108,076 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 17.11 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 171.08 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 13,733,839 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.25 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 6.81 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 10.38 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.15 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 7.80 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 21,672,984 | 4,386,404 | 0.20x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 21.67 ms | 4.39 ms | 0.20x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 216.73 ms | 4.39 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 15,654,158 | 435,109 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.38 | 10.08 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.4% | 99.8% | +0.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 6.40 | 0.30 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.7% | 99.9% | +2.1 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 11.50 | 0.99 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.2% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.13 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 16.17 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 21,657,112 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 21.66 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 216.57 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 15,649,189 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.38 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.4% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 6.49 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 11.53 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.06 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 16.10 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.3% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 4,564,908 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 8,011,732 | - | - | no matching split on the hart |
| exec split | C helper cycles | 9,096,344 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,494 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 5 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 11,535 | 0.3% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 325,222 | 325,222 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 435,109 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 66.64 | 13.49 | 0.20x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.04 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 625 | 865 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 1,590 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (8504122); libpython3.14.so.1.0+0x227190 (1879667); PyFloat_FromDouble (1739936); __tls_get_addr (1357301); libpython3.14.so.1.0+0x2018f0 (730575) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### nqueens.py

PyCore result: PASS. stdout matches.
PyCore stdout: `40↵`
CPython stdout: `40↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 18,978,883 | 12,721,120 | 0.67x |  |
| compile (cold) | time at 1 GHz | 18.98 ms | 12.72 ms | 0.67x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 189.79 ms | 12.72 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,257,591 | 443,002 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 28.72 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 70.6% | -28.0 pp |  |
| compile (cold) | L1I MPKI | 14.16 | 113.8 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.2% | 89.1% | -6.1 pp |  |
| compile (cold) | L1D MPKI | 20.24 | 204.6 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.8% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.78 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.48 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,254,752 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.25 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 32.55 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,142,766 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.57 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.72 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.56 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.42 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 18,347,443 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 18.35 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 183.47 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 7,485,877 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.45 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.15 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 96.4% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 16.67 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 81.58 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 66,720,322 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 66.72 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 667.20 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 52,147,473 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.28 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 17.34 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 97.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 9.26 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.03 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 5.82 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 85,067,765 | 55,074,898 | 0.65x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 85.07 ms | 55.07 ms | 0.65x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 850.68 ms | 55.07 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 59,633,350 | 3,600,670 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.43 | 15.30 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.4% | 100.0% | +1.6 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 15.68 | 0.02 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.6% | 95.3% | -2.2 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 10.19 | 46.10 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 15.33 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 84,829,965 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 84.83 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 848.30 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 59,696,414 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.42 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.4% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 15.75 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.8% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 9.39 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 15.32 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.6% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 18,347,443 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 33,091,054 | - | - | no matching split on the hart |
| exec split | C helper cycles | 33,629,268 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,440 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 8,547 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 1,352,586 | 1,352,586 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 3,600,670 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 62.89 | 40.72 | 0.65x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 13.56 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 180 | 403 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 390 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (35774444); libpython3.14.so.1.0+0x19ae40 (3295358); libpython3.14.so.1.0+0x200330 (2529000); libpython3.14.so.1.0+0x18b5b0 (2049543); __tls_get_addr (1964776) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### sor.py

PyCore result: PASS. stdout matches.
PyCore stdout: `1047090603↵`
CPython stdout: `1047090603↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,462,995 | 15,301,840 | 0.79x |  |
| compile (cold) | time at 1 GHz | 19.46 ms | 15.30 ms | 0.79x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 194.63 ms | 15.30 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,629,367 | 529,189 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 28.92 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 70.0% | -28.5 pp |  |
| compile (cold) | L1I MPKI | 14.47 | 115.5 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.4% | 88.9% | -6.5 pp |  |
| compile (cold) | L1D MPKI | 19.29 | 208.5 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.94 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.50 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,786,573 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.79 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 37.87 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,507,676 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.06 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.53 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.36 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.21 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 9,403,320 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 9.40 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 94.03 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,490,556 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.69 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.35 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 98.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 7.14 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 100.8 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 32,192,169 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 32.19 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 321.92 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 28,008,812 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.15 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 4.61 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 6.32 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 98.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.17 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.51 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 41,595,489 | 15,698,642 | 0.38x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 41.60 ms | 15.70 ms | 0.38x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 415.95 ms | 15.70 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 31,499,368 | 1,687,294 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.32 | 9.30 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.5% | 100.0% | +0.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 4.58 | 0.05 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.7% | 98.3% | -0.3 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 6.41 | 8.46 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 98.6% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.15 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 15.19 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 41,083,847 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 41.08 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 410.84 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 31,469,645 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.31 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 4.40 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 4.65 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 98.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.11 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 15.11 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.1% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 9,403,320 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 15,176,109 | - | - | no matching split on the hart |
| exec split | C helper cycles | 17,016,060 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,548 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 4,494 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 599,102 | 599,102 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 1,687,294 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 69.43 | 26.20 | 0.38x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 15.70 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 219 | 437 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 505 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (16895586); libpython3.14.so.1.0+0x227190 (4688665); PyFloat_FromDouble (3412285); __tls_get_addr (2550724); libpython3.14.so.1.0+0x197c90 (1320880) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### spectral_norm.py

PyCore result: PASS. stdout matches.
PyCore stdout: `1273839840↵`
CPython stdout: `1273839840↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,381,976 | 13,118,920 | 0.68x |  |
| compile (cold) | time at 1 GHz | 19.38 ms | 13.12 ms | 0.68x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 193.82 ms | 13.12 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,528,283 | 450,431 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 29.13 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 69.9% | -28.6 pp |  |
| compile (cold) | L1I MPKI | 14.33 | 116.7 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.3% | 89.0% | -6.2 pp |  |
| compile (cold) | L1D MPKI | 20.00 | 210.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.92 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.55 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,649,569 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.65 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 36.50 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,405,860 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.82 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.87 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 85.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.78 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.50 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 10,675,231 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 10.68 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 106.75 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,963,195 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.69 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.1% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 8.76 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 95.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 23.89 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 91.57 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 39,793,264 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 39.79 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 397.93 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 32,857,946 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.21 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 13.82 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 7.89 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.05 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 3.68 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 50,468,495 | 8,232,062 | 0.16x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 50.47 ms | 8.23 ms | 0.16x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 504.68 ms | 8.23 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 36,821,141 | 932,054 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.37 | 8.83 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.7% | 100.0% | +1.3 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 13.27 | 0.07 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.0% | 99.2% | +1.3 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 9.61 | 2.44 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.8% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.05 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 13.14 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 50,778,111 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 50.78 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 507.78 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 36,840,818 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.38 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 13.35 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 10.71 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 13.11 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 10.8% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 10,675,231 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 18,499,433 | - | - | no matching split on the hart |
| exec split | C helper cycles | 21,293,831 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,654 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 3 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 8,971 | 0.1% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 642,524 | 642,524 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 932,054 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 78.55 | 12.81 | 0.16x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 16.61 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 198 | 313 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 436 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (18881968); libpython3.14.so.1.0+0x197c90 (5425397); __tls_get_addr (2224519); _Py_Dealloc (2014908); PyFloat_FromDouble (1539241) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |
