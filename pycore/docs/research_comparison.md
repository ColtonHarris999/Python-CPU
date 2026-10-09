# Research benchmark comparison

PyCore versus the CPython 3.14 baseline on the research set
(`pycore/tools/cpython_baseline/benchmarks/research/`).
Regenerate with `make research-compare`.

Recorded 2026-10-08 11:10 UTC.

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
(two-core, `CACHE_EN=1`, `MEM_LATENCY=4`).
L1 hit rates on PyCore count the hart's own accesses during that
phase. LLC hit rate and branch MPKI are Callgrind results; the
phase mark does not count L2 misses or mispredicted branches.

Two files needed a source change before the hart could finish them.
`mandelbrot.py` and `spectral_norm.py` had a non-ASCII character in
a comment. The on-device compiler raises `SyntaxError` on that, so
the comments are ASCII and the kernels are unchanged.
`binary_trees.py` tested a leaf with `node == 0`. A list compared
with an int TYPE-traps, and a node is a non-empty list, so the test
is `not node`. The printed checksums are the ones in
`cpython_benchmarks.md`.

## Suite

| program | result | cpy compile | pyc compile | compile × | cpy exec | pyc exec | exec × | cpy L1D | pyc L1D | cpy L1I | pyc L1I | cpy LLC | disp% | c/bc cpy | c/bc pyc | pyc @1GHz | cpy @1GHz |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| binary_trees.py | PASS | 18,514,433 | 12,052,100 | 0.65x | 40,068,816 | 10,774,318 | 0.27x | 99.1% | 96.1% | 100.0% | 100.0% | 98.2% | 11.7% | 67.3 | 18.1 | 10.77 ms | 40.07 ms |
| fannkuch.py | PASS | 19,309,849 | 20,316,420 | 1.05x | 81,446,404 | 120,567,458 | 1.48x | 99.6% | 91.1% | 99.9% | 100.0% | 99.3% | 19.2% | 38.1 | 56.5 | 120.57 ms | 81.45 ms |
| fasta.py | PASS | 20,293,522 | 21,457,620 | 1.06x | 32,177,348 | 7,279,622 | 0.23x | 97.5% | 99.9% | 98.0% | 100.0% | 99.7% | 12.9% | 66.0 | 14.9 | 7.28 ms | 32.18 ms |
| knucleotide.py | PASS | 19,359,249 | 17,015,800 | 0.88x | 52,632,216 | 39,663,444 | 0.75x | 98.6% | 93.3% | 98.3% | 100.0% | 99.4% | 8.9% | 84.3 | 63.5 | 39.66 ms | 52.63 ms |
| mandelbrot.py | PASS | 18,058,626 | 10,862,480 | 0.60x | 62,809,316 | 7,163,734 | 0.11x | 98.9% | 99.9% | 99.7% | 100.0% | 99.7% | 11.3% | 70.7 | 8.1 | 7.16 ms | 62.81 ms |
| monte_carlo.py | PASS | 20,271,120 | 22,471,940 | 1.11x | 61,543,467 | 9,668,276 | 0.16x | 95.8% | 100.0% | 96.6% | 100.0% | 99.9% | 11.0% | 87.9 | 13.8 | 9.67 ms | 61.54 ms |
| nbody.py | PASS | 26,545,567 | 57,666,200 | 2.17x | 21,788,839 | 4,462,276 | 0.20x | 97.5% | 99.9% | 99.4% | 99.8% | 99.3% | 12.3% | 67.0 | 13.7 | 4.46 ms | 21.79 ms |
| nqueens.py | PASS | 18,947,782 | 17,281,800 | 0.91x | 85,037,010 | 236,701,258 | 2.78x | 97.6% | 82.5% | 98.4% | 100.0% | 99.9% | 12.6% | 62.9 | 175.0 | 236.70 ms | 85.04 ms |
| sor.py | PASS | 19,485,943 | 20,802,960 | 1.07x | 41,675,067 | 21,153,468 | 0.51x | 98.6% | 97.7% | 99.5% | 100.0% | 98.7% | 11.1% | 69.6 | 35.3 | 21.15 ms | 41.68 ms |
| spectral_norm.py | PASS | 19,407,916 | 17,960,400 | 0.93x | 50,305,707 | 11,456,302 | 0.23x | 98.1% | 95.5% | 98.7% | 100.0% | 99.8% | 10.8% | 78.3 | 17.8 | 11.46 ms | 50.31 ms |
| geomean | | | | | 49,192,874 | 19,154,864 | 0.39x | | | | | | | | | 19.15 ms | 49.19 ms |

`c/bc` divides cold-exec cycles by CPython's `sys.monitoring` count
of the same source. `exec ×` is PyCore run cycles divided by CPython
`run_cold` cycles. `disp%` is the dispatch edge's share of CPython's
cold-exec instructions. The geometric mean uses programs that
finished (PASS or MISMATCH) with a positive exec cycle count.

| program | cpy warm exec | cpy branch MPKI | pyc excore handoffs | pyc excore wait | excore share of exec |
| --- | ---: | ---: | ---: | ---: | ---: |
| binary_trees.py | 40,214,595 | 12.8 | 4 | 16,900 | 0.2% |
| fannkuch.py | 81,362,275 | 20.9 | 26,057 | 45,475,904 | 37.7% |
| fasta.py | 32,526,604 | 17.9 | 34 | 73,928 | 1.0% |
| knucleotide.py | 52,645,466 | 11.9 | 8,007 | 14,794,443 | 37.3% |
| mandelbrot.py | 62,609,379 | 13.7 | 4 | 16,357 | 0.2% |
| monte_carlo.py | 61,099,463 | 17.9 | 21 | 53,487 | 0.6% |
| nbody.py | 21,903,365 | 16.2 | 17 | 80,926 | 1.8% |
| nqueens.py | 85,060,173 | 15.3 | 70,578 | 119,805,793 | 50.6% |
| sor.py | 41,452,550 | 15.2 | 2,356 | 4,513,862 | 21.3% |
| spectral_norm.py | 50,694,130 | 13.1 | 824 | 1,642,741 | 14.3% |

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
| compile (cold) | cycles | 18,514,433 | 12,052,100 | 0.65x |  |
| compile (cold) | time at 1 GHz | 18.51 ms | 12.05 ms | 0.65x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 185.14 ms | 12.05 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 12,916,237 | 288,827 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 41.73 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 69.1% | -29.5 pp |  |
| compile (cold) | L1I MPKI | 13.94 | 121.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.0% | 94.2% | -0.8 pp |  |
| compile (cold) | L1D MPKI | 20.73 | 229.4 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.1% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.71 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.50 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 2,759,059 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 2.76 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 27.59 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 1,795,195 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.54 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.0% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.58 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.36 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.9% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.49 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.84 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 8,361,380 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 8.36 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 83.61 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,789,168 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.21 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.09 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 99.3% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 3.03 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.7% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 74.05 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 31,707,436 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 31.71 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 317.07 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 28,655,808 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.11 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 100.0% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 0.39 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 99.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 3.90 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 98.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.08 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.76 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 40,068,816 | 10,774,318 | 0.27x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 40.07 ms | 10.77 ms | 0.27x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 400.69 ms | 10.77 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 32,444,976 | 750,017 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.23 | 14.37 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 100.0% | 100.0% | +0.0 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 0.36 | 0.06 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 99.1% | 96.1% | -3.0 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 3.80 | 51.43 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 98.2% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.07 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 12.85 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 40,214,595 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 40.21 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 402.15 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 32,474,237 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.24 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 0.40 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 4.28 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.05 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 12.84 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.7% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 8,361,380 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 18,975,177 | - | - | no matching split on the hart |
| exec split | C helper cycles | 12,732,259 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,851 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 4 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 16,900 | 0.2% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 595,286 | 595,286 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 750,017 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 67.31 | 18.10 | 0.27x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.05 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 149 | 167 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 342 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (20794543); libpython3.14.so.1.0+0x1c77f0 (1933769); _PyEval_FrameClearAndPop (1546650); __tls_get_addr (1186229); libpython3.14.so.1.0+0x18f780 (1001882) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### fannkuch.py

PyCore result: PASS. stdout matches.
PyCore stdout: `16↵`
CPython stdout: `16↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,309,849 | 20,316,420 | 1.05x |  |
| compile (cold) | time at 1 GHz | 19.31 ms | 20.32 ms | 1.05x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 193.10 ms | 20.32 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,504,337 | 528,072 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 38.47 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 71.3% | -27.3 pp |  |
| compile (cold) | L1I MPKI | 14.34 | 110.4 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.3% | 94.4% | -0.8 pp |  |
| compile (cold) | L1D MPKI | 19.98 | 205.4 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.75 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.42 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,595,385 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.60 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 35.95 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,388,780 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.93 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.26 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 88.7% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.54 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.85 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 30,358,989 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 30.36 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 303.59 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 11,551,938 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.63 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.65 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 1.89 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 100.6 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 51,087,415 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 51.09 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 510.87 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 48,648,377 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.05 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 1.20 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 99.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 1.57 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 1.92 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 81,446,404 | 120,567,458 | 1.48x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 81.45 ms | 120.57 ms | 1.48x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 814.46 ms | 120.57 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 60,200,315 | 5,386,106 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.35 | 22.38 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.9% | 100.0% | +0.1 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 1.09 | 0.02 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 99.6% | 91.1% | -8.5 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 1.63 | 104.3 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 20.86 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 81,362,275 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 81.36 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 813.62 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 60,184,264 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.35 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 1.08 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 1.38 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.8% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 20.92 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 19.2% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 30,358,989 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 42,865,052 | - | - | no matching split on the hart |
| exec split | C helper cycles | 8,222,363 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,598 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 26,057 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 45,475,904 | 37.7% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 2,135,521 | 2,135,521 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 5,386,106 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 38.14 | 56.46 | 1.48x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.22 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 208 | 462 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 410 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (52821755); libpython3.14.so.1.0+0x200330 (3161190); libpython3.14.so.1.0+0x1ff000 (1434940); libpython3.14.so.1.0+0x18b5b0 (629574); libpython3.14.so.1.0+0x18f780 (465330) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### fasta.py

PyCore result: PASS. stdout matches.
PyCore stdout: `516277↵`
CPython stdout: `516277↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 20,293,522 | 21,457,620 | 1.06x |  |
| compile (cold) | time at 1 GHz | 20.29 ms | 21.46 ms | 1.06x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 202.94 ms | 21.46 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 14,159,301 | 555,872 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 38.60 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.5% | 70.3% | -28.2 pp |  |
| compile (cold) | L1I MPKI | 15.38 | 114.4 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.5% | 94.5% | -1.0 pp |  |
| compile (cold) | L1D MPKI | 19.16 | 201.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.92 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.49 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 4,624,535 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 4.62 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 46.25 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 3,039,576 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.0% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.88 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.28 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 88.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.96 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.90 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 7,146,052 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 7.15 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 71.46 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 2,766,150 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.58 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.8% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 1.86 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 97.2% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 12.94 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 92.49 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 25,031,296 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 25.03 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 250.31 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 18,654,285 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.34 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 97.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 22.57 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 97.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 10.65 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.09 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 6.81 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 32,177,348 | 7,279,622 | 0.23x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 32.18 ms | 7.28 ms | 0.23x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 321.77 ms | 7.28 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 21,420,435 | 878,641 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.50 | 8.29 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.0% | 100.0% | +2.0 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 19.89 | 0.08 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.5% | 99.9% | +2.4 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 10.95 | 1.10 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.7% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.08 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 17.87 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 32,526,604 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 32.53 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 325.27 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 21,504,564 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 19.95 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.1% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 12.57 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.03 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 17.80 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.9% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 7,146,052 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 14,837,702 | - | - | no matching split on the hart |
| exec split | C helper cycles | 10,193,594 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,185 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 34 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 73,928 | 1.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 487,405 | 487,405 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 878,641 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 66.02 | 14.94 | 0.23x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.66 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 225 | 353 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 449 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (13998088); libpython3.14.so.1.0+0x197c90 (2107432); _Py_Dealloc (1052688); __tls_get_addr (940632); libpython3.14.so.1.0+0x1dd5d0 (601680) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### knucleotide.py

PyCore result: PASS. stdout matches.
PyCore stdout: `73307453↵`
CPython stdout: `73307453↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,359,249 | 17,015,800 | 0.88x |  |
| compile (cold) | time at 1 GHz | 19.36 ms | 17.02 ms | 0.88x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 193.59 ms | 17.02 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,469,369 | 448,419 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.44 | 37.95 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 72.3% | -26.3 pp |  |
| compile (cold) | L1I MPKI | 14.48 | 106.7 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.1% | 94.4% | -0.7 pp |  |
| compile (cold) | L1D MPKI | 20.46 | 201.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.5% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.91 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.57 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,583,792 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.58 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 35.84 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,340,044 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.95 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.54 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.59 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.67 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 8,793,570 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 8.79 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 87.94 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,457,287 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.54 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.66 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 96.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 14.74 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 87.97 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 43,838,646 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 43.84 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 438.39 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 35,467,317 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.24 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.2% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 18.33 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 4.96 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.4% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.14 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.53 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 52,632,216 | 39,663,444 | 0.75x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 52.63 ms | 39.66 ms | 0.75x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 526.32 ms | 39.66 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 38,924,604 | 1,432,616 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.35 | 27.69 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.3% | 100.0% | +1.7 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 17.11 | 0.05 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.6% | 93.3% | -5.3 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 5.83 | 139.8 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.4% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.13 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 11.94 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 52,645,466 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 52.65 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 526.45 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 38,919,258 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.35 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.3% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 17.11 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 98.5% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 6.56 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.5% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.11 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 11.66 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 8.9% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 8,793,570 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 15,534,239 | - | - | no matching split on the hart |
| exec split | C helper cycles | 28,304,407 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,958 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 8,007 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 14,794,443 | 37.3% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 624,521 | 624,521 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 1,432,616 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 84.28 | 63.51 | 0.75x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.08 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 181 | 350 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 400 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (16183862); libpython3.14.so.1.0+0x190740 (3168661); libpython3.14.so.1.0+0x197c90 (3031836); libpython3.14.so.1.0+0x18fcd0 (2354329); _Py_Dealloc (2102268) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### mandelbrot.py

PyCore result: PASS. stdout matches.
PyCore stdout: `414↵`
CPython stdout: `414↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 18,058,626 | 10,862,480 | 0.60x |  |
| compile (cold) | time at 1 GHz | 18.06 ms | 10.86 ms | 0.60x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 180.59 ms | 10.86 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 12,621,777 | 251,472 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 43.20 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.7% | 66.6% | -32.0 pp |  |
| compile (cold) | L1I MPKI | 13.47 | 130.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.0% | 94.1% | -0.8 pp |  |
| compile (cold) | L1D MPKI | 21.02 | 238.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 95.1% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.68 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.41 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 2,301,813 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 2.30 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 23.02 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 1,504,271 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.83 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.88 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 85.7% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.81 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.87 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 12,658,718 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 12.66 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 126.59 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 5,522,650 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.29 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 0.30 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 98.7% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 5.98 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 78.01 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 50,150,598 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 50.15 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 501.51 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 43,446,707 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.15 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 3.50 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 6.00 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.04 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 5.48 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 62,809,316 | 7,163,734 | 0.11x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 62.81 ms | 7.16 ms | 0.11x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 628.09 ms | 7.16 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 48,969,357 | 943,224 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.28 | 7.59 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.7% | 100.0% | +0.3 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 3.14 | 0.04 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.9% | 99.9% | +1.1 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 6.00 | 0.15 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.7% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.03 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 13.66 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 62,609,379 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 62.61 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 626.09 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 48,978,126 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.28 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 3.17 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 99.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 5.44 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 13.62 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.3% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 12,658,718 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 20,083,220 | - | - | no matching split on the hart |
| exec split | C helper cycles | 30,067,378 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,647 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 4 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 16,357 | 0.2% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 888,967 | 888,967 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 943,224 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 70.65 | 8.06 | 0.11x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.24 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 127 | 134 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 247 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (21587867); libpython3.14.so.1.0+0x227190 (6599604); PyFloat_FromDouble (6525184); __tls_get_addr (5629701); _Py_Dealloc (4323102) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### monte_carlo.py

PyCore result: PASS. stdout matches.
PyCore stdout: `3132800↵`
CPython stdout: `3132800↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 20,271,120 | 22,471,940 | 1.11x |  |
| compile (cold) | time at 1 GHz | 20.27 ms | 22.47 ms | 1.11x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 202.71 ms | 22.47 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 14,077,875 | 542,300 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.44 | 41.44 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.5% | 69.0% | -29.5 pp |  |
| compile (cold) | L1I MPKI | 15.19 | 121.8 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.2% | 94.3% | -0.9 pp |  |
| compile (cold) | L1D MPKI | 20.12 | 226.3 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.6% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.92 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.57 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 4,493,859 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 4.49 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 44.94 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,953,098 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.35 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.06 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 87.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.12 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.21 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 11,011,073 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 11.01 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 110.11 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 4,090,937 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.69 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 9.58 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 95.7% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 20.03 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 92.77 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 50,532,394 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 50.53 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 505.32 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 33,084,109 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.53 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 96.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 36.89 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 95.8% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 18.56 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.06 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 8.69 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 61,543,467 | 9,668,276 | 0.16x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 61.54 ms | 9.67 ms | 0.16x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 615.43 ms | 9.67 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 37,175,046 | 1,120,638 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.66 | 8.63 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 96.6% | 100.0% | +3.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 33.88 | 0.06 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 95.8% | 100.0% | +4.2 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 18.73 | 0.40 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.05 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 17.94 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 61,099,463 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 61.10 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 610.99 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 37,214,385 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.64 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 96.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 33.78 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 96.2% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 16.90 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 17.94 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.0% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 11,011,073 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 23,357,277 | - | - | no matching split on the hart |
| exec split | C helper cycles | 27,175,117 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,652 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 21 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 53,487 | 0.6% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 700,534 | 700,534 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 1,120,638 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 87.85 | 13.80 | 0.16x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 15.72 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 244 | 321 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 544 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (19976798); libpython3.14.so.1.0+0x197c90 (2651277); __tls_get_addr (1716396); _PyLong_Frexp (1667775); _Py_Dealloc (1408554) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### nbody.py

PyCore result: PASS. stdout matches.
PyCore stdout: `-169075163↵-169026908↵`
CPython stdout: `-169075163↵-169026908↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 26,545,567 | 57,666,200 | 2.17x |  |
| compile (cold) | time at 1 GHz | 26.55 ms | 57.67 ms | 2.17x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 265.46 ms | 57.67 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 18,326,646 | 1,558,237 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.45 | 37.01 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.1% | 72.3% | -25.8 pp |  |
| compile (cold) | L1I MPKI | 18.58 | 104.0 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 96.0% | 94.3% | -1.7 pp |  |
| compile (cold) | L1D MPKI | 17.76 | 200.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 93.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 2.43 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.52 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 10,802,863 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 10.80 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 108.03 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 7,184,119 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.50 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 29.46 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.25 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 89.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 4.41 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 12.13 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 4,641,920 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 4.64 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 46.42 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 1,920,319 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.42 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 3.52 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 94.4% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 25.23 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.04 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 75.99 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 17,146,919 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 17.15 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 171.47 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 13,733,832 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.25 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 6.81 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 97.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 10.78 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.1% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.15 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 7.80 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 21,788,839 | 4,462,276 | 0.20x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 21.79 ms | 4.46 ms | 0.20x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 217.89 ms | 4.46 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 15,654,151 | 435,109 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.39 | 10.26 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.4% | 99.8% | +0.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 6.40 | 0.31 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.5% | 99.9% | +2.4 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 12.55 | 1.15 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.14 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 16.17 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 21,903,365 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 21.90 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 219.03 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 15,649,175 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.40 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.4% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 6.49 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.3% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 13.78 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.07 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 16.10 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.3% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 4,641,920 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 8,028,086 | - | - | no matching split on the hart |
| exec split | C helper cycles | 9,118,833 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,135 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 17 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 80,926 | 1.8% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 325,222 | 325,222 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 435,109 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 67.00 | 13.72 | 0.20x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 14.27 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 625 | 865 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 1,590 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (8506042); libpython3.14.so.1.0+0x227190 (1879667); PyFloat_FromDouble (1739936); __tls_get_addr (1357301); libpython3.14.so.1.0+0x2018f0 (730575) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### nqueens.py

PyCore result: PASS. stdout matches.
PyCore stdout: `40↵`
CPython stdout: `40↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 18,947,782 | 17,281,800 | 0.91x |  |
| compile (cold) | time at 1 GHz | 18.95 ms | 17.28 ms | 0.91x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 189.48 ms | 17.28 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,259,579 | 442,764 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 39.03 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 71.3% | -27.2 pp |  |
| compile (cold) | L1I MPKI | 14.17 | 110.7 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.3% | 94.4% | -0.9 pp |  |
| compile (cold) | L1D MPKI | 19.82 | 209.3 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.7% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.80 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.49 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,260,415 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.26 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 32.60 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,141,534 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.1% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.55 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.5% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 12.20 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 86.3% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.60 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.42 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 18,277,272 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 18.28 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 182.77 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 7,485,877 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.44 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.15 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 96.7% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 15.33 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.00 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 81.58 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 66,759,738 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 66.76 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 667.60 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 52,147,466 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.28 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.3% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 17.34 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 97.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 9.37 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.9% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.03 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 5.82 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 85,037,010 | 236,701,258 | 2.78x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 85.04 ms | 236.70 ms | 2.78x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 850.37 ms | 236.70 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 59,633,343 | 3,600,670 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.43 | 65.74 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.4% | 100.0% | +1.6 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 15.68 | 0.02 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 97.6% | 82.5% | -15.1 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 10.12 | 413.7 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.9% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 15.33 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 85,060,173 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 85.06 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 850.60 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 59,696,400 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.42 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.4% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 15.75 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 9.94 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 100.0% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 15.32 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 12.6% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 18,277,272 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 33,118,952 | - | - | no matching split on the hart |
| exec split | C helper cycles | 33,640,786 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 2,643 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 70,578 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 119,805,793 | 50.6% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 1,352,586 | 1,352,586 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 3,600,670 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 62.87 | 175.0 | 2.78x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 13.51 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 180 | 403 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 390 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (35775587); libpython3.14.so.1.0+0x19ae40 (3295358); libpython3.14.so.1.0+0x200330 (2529000); libpython3.14.so.1.0+0x18b5b0 (2049543); __tls_get_addr (1964776) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### sor.py

PyCore result: PASS. stdout matches.
PyCore stdout: `1047090603↵`
CPython stdout: `1047090603↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,485,943 | 20,802,960 | 1.07x |  |
| compile (cold) | time at 1 GHz | 19.49 ms | 20.80 ms | 1.07x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 194.86 ms | 20.80 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,630,259 | 528,727 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 39.35 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 71.0% | -27.5 pp |  |
| compile (cold) | L1I MPKI | 14.48 | 111.6 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.4% | 94.3% | -1.0 pp |  |
| compile (cold) | L1D MPKI | 19.52 | 212.7 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.3% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.92 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.50 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,784,699 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.78 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 37.85 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,505,672 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.51 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 28.04 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.71 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 87.0% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.18 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.22 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 9,400,388 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 9.40 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 94.00 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,490,556 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.69 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.6% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 4.35 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 98.5% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 7.03 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 99.9% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 100.8 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 32,274,679 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 32.27 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 322.75 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 28,008,435 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.15 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 99.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 4.61 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 6.75 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 98.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.17 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 4.51 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 41,675,067 | 21,153,468 | 0.51x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 41.68 ms | 21.15 ms | 0.51x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 416.75 ms | 21.15 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 31,498,991 | 1,687,294 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.32 | 12.54 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 99.5% | 100.0% | +0.4 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 4.58 | 0.05 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.6% | 97.7% | -0.9 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 6.78 | 22.79 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 98.7% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.15 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 15.19 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 41,452,550 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 41.45 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 414.53 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 31,469,623 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.32 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 99.6% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 4.40 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 98.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 6.32 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 98.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.12 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 15.11 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 11.1% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 9,400,388 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 15,245,306 | - | - | no matching split on the hart |
| exec split | C helper cycles | 17,029,373 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 3,116 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 2,356 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 4,513,862 | 21.3% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 599,102 | 599,102 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 1,687,294 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 69.56 | 35.31 | 0.51x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 15.69 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 219 | 437 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 505 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (16895586); libpython3.14.so.1.0+0x227190 (4688665); PyFloat_FromDouble (3412285); __tls_get_addr (2550724); libpython3.14.so.1.0+0x197c90 (1320880) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |

### spectral_norm.py

PyCore result: PASS. stdout matches.
PyCore stdout: `1273839840↵`
CPython stdout: `1273839840↵`

| group | result | CPython | PyCore | compare | note |
| --- | --- | ---: | ---: | ---: | --- |
| compile (cold) | cycles | 19,407,916 | 17,960,400 | 0.93x |  |
| compile (cold) | time at 1 GHz | 19.41 ms | 17.96 ms | 0.93x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (cold) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 194.08 ms | 17.96 ms | - | clocks differ, so this time ratio is not a performance ratio |
| compile (cold) | instructions | 13,528,382 | 450,123 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (cold) | cycles per instruction | 1.43 | 39.90 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (cold) | L1I hit rate | 98.6% | 70.8% | -27.7 pp |  |
| compile (cold) | L1I MPKI | 14.33 | 113.1 | - | misses per thousand of that core's own instructions |
| compile (cold) | L1D hit rate | 95.2% | 94.3% | -0.9 pp |  |
| compile (cold) | L1D MPKI | 20.28 | 218.9 | - | misses per thousand of that core's own instructions |
| compile (cold) | LLC hit rate | 94.5% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| compile (cold) | LLC MPKI | 1.91 | - | - | no L2 miss counter on the phase mark |
| compile (cold) | branch MPKI | 11.54 | - | - | the hart does not count mispredicted branches |
| compile (warm) | cycles | 3,644,053 | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | time at 1 GHz | 3.64 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| compile (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 36.44 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| compile (warm) | instructions | 2,403,978 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| compile (warm) | cycles per instruction | 1.52 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| compile (warm) | L1I hit rate | 97.2% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1I MPKI | 27.80 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D hit rate | 97.6% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | L1D MPKI | 11.77 | - | - | misses per thousand of that core's own instructions; PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC hit rate | 85.4% | - | - | PyCore compiles once per reset; there is no second compile |
| compile (warm) | LLC MPKI | 5.78 | - | - | no L2 miss counter on the phase mark |
| compile (warm) | branch MPKI | 13.48 | - | - | the hart does not count mispredicted branches |
| interpret (dispatch edge) | cycles | 10,670,095 | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | time at 1 GHz | 10.67 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| interpret (dispatch edge) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 106.70 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| interpret (dispatch edge) | instructions | 3,963,195 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| interpret (dispatch edge) | cycles per instruction | 2.69 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| interpret (dispatch edge) | L1I hit rate | 99.1% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1I MPKI | 8.76 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D hit rate | 95.1% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | L1D MPKI | 23.70 | - | - | misses per thousand of that core's own instructions; CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC hit rate | 100.0% | - | - | CPython's fetch/decode/indirect-jump edge. On the hart that work is inside each bytecode's cycle, not a separate instruction stream |
| interpret (dispatch edge) | LLC MPKI | 0.01 | - | - | no L2 miss counter on the phase mark |
| interpret (dispatch edge) | branch MPKI | 91.57 | - | - | the hart does not count mispredicted branches |
| run (opcode bodies and helpers) | cycles | 39,635,612 | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | time at 1 GHz | 39.64 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| run (opcode bodies and helpers) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 396.36 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| run (opcode bodies and helpers) | instructions | 32,858,151 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| run (opcode bodies and helpers) | cycles per instruction | 1.21 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| run (opcode bodies and helpers) | L1I hit rate | 98.6% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1I MPKI | 13.82 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D hit rate | 98.5% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | L1D MPKI | 7.20 | - | - | misses per thousand of that core's own instructions; CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC hit rate | 99.7% | - | - | CPython exec minus the dispatch edge. The hart does not split fetch from the opcode |
| run (opcode bodies and helpers) | LLC MPKI | 0.06 | - | - | no L2 miss counter on the phase mark |
| run (opcode bodies and helpers) | branch MPKI | 3.68 | - | - | the hart does not count mispredicted branches |
| exec (cold, interpret + run) | cycles | 50,305,707 | 11,456,302 | 0.23x | fair column: one execution of the code object, no specialization |
| exec (cold, interpret + run) | time at 1 GHz | 50.31 ms | 11.46 ms | 0.23x | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (cold, interpret + run) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 503.06 ms | 11.46 ms | - | clocks differ, so this time ratio is not a performance ratio |
| exec (cold, interpret + run) | instructions | 36,821,346 | 932,054 | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (cold, interpret + run) | cycles per instruction | 1.37 | 12.29 | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (cold, interpret + run) | L1I hit rate | 98.7% | 100.0% | +1.3 pp |  |
| exec (cold, interpret + run) | L1I MPKI | 13.27 | 0.07 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | L1D hit rate | 98.1% | 95.5% | -2.6 pp |  |
| exec (cold, interpret + run) | L1D MPKI | 8.98 | 34.47 | - | misses per thousand of that core's own instructions |
| exec (cold, interpret + run) | LLC hit rate | 99.8% | - | - | PyCore's phase marks count L1 only; the 128KB L2 is not in PHASE_MARK |
| exec (cold, interpret + run) | LLC MPKI | 0.05 | - | - | no L2 miss counter on the phase mark |
| exec (cold, interpret + run) | branch MPKI | 13.14 | - | - | the hart does not count mispredicted branches |
| exec (warm) | cycles | 50,694,130 | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | time at 1 GHz | 50.69 ms | - | - | both columns are cycles / 1e9; the ratio matches the cycle ratio |
| exec (warm) | time at stated clock (CPython 100 MHz, PyCore 1000 MHz) | 506.94 ms | - | - | clocks differ, so this time ratio is not a performance ratio |
| exec (warm) | instructions | 36,840,807 | - | - | CPython is retired x86 instructions; PyCore is bytecodes issued, including ROM builtins |
| exec (warm) | cycles per instruction | 1.38 | - | - | each core's own instruction; PyCore's is cycles per issued bytecode |
| exec (warm) | L1I hit rate | 98.7% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1I MPKI | 13.35 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D hit rate | 97.8% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | L1D MPKI | 10.39 | - | - | misses per thousand of that core's own instructions; CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC hit rate | 99.9% | - | - | CPython's second exec after PEP 659. The hart does not specialize, so its cold exec is the number to put beside this |
| exec (warm) | LLC MPKI | 0.02 | - | - | no L2 miss counter on the phase mark |
| exec (warm) | branch MPKI | 13.11 | - | - | the hart does not count mispredicted branches |
| exec split | dispatch share of exec instructions | 10.8% | - | - | share of x86 instructions on the jump-table edge |
| exec split | dispatch cycles | 10,670,095 | - | - | no matching split on the hart |
| exec split | inline opcode cycles | 18,362,666 | - | - | no matching split on the hart |
| exec split | C helper cycles | 21,272,946 | - | - | no matching split on the hart |
| compile (cold) | excore handoffs | - | 1 | - | PyCore only; recoverable traps to the companion core |
| compile (cold) | excore wait cycles | - | 3,022 | 0.0% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| exec (cold, interpret + run) | excore handoffs | - | 824 | - | PyCore only; recoverable traps to the companion core |
| exec (cold, interpret + run) | excore wait cycles | - | 1,642,741 | 14.3% | cycles the hart spent marshalling and waiting; compare cell is the share of that phase |
| bytecode | CPython bytecodes executed | 642,524 | 642,524 | - | sys.monitoring count of the source; the same denominator for both cores |
| bytecode | PyCore bytecodes issued | - | 932,054 | - | includes ROM bodies such as print(); larger than the monitoring count |
| bytecode | exec cycles per CPython bytecode | 78.29 | 17.83 | 0.23x | cold exec cycles divided by the monitoring count |
| bytecode | dispatch cycles per CPython bytecode | 16.61 | - | - | the hart has no separate dispatch-edge cycle count |
| code | instructions / code-RAM slots | 198 | 313 | - | CPython instruction count versus slots the on-device compiler allocated |
| code | CPython code units with CACHE | 436 | - | - | the on-device compiler emits no CACHE |
| profile | hottest exec functions | _PyEval_EvalFrameDefault (18883111); libpython3.14.so.1.0+0x197c90 (5425397); __tls_get_addr (2224530); _Py_Dealloc (2014908); PyFloat_FromDouble (1539241) | - | - | Callgrind attributes x86 instructions to symbols; the hart has no per-function profile |
