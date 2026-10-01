# Benchmarking plan

Goal: publishable, repeatable numbers for PyCore on **standard, published
Python benchmark suites**, compared with CPython 3.14 and MicroPython on
the same sources, plus a per-mechanism breakdown of where the cycles go.

We do not write our own benchmarks for the headline numbers. We run two
suites that other Python implementations already report:

| Suite | Pin | Why |
| --- | --- | --- |
| **pyperformance** (`python/pyperformance`) | 1.14.0, `ccc0aeb` (2026-09-01) | The official CPython benchmark suite. It is what the CPython, PyPy, Pyston and GraalPy projects publish against, so its names mean something to every reader. |
| **MicroPython `tests/perf_bench`** (`micropython/micropython`) | `19e685e` (2026-09-30) | Written for constrained Python machines. Every benchmark has built-in size parameters (`bm_params`, keyed by N ≈ CPU speed and M ≈ heap KB), and its runner checks output against CPython. It is the natural peer comparison for a Python CPU. |

This plan has three parts:

1. [Preparing for benchmarking](#1-preparing-for-benchmarking): what has
   to change in the RTL, builtins, memory system, runtime and tooling
   before the suites run and the numbers mean anything.
2. [Benchmarks](#2-benchmarks): which upstream benchmarks we run, why, and
   what each one still needs.
3. [How to run them](#3-how-to-run-the-benchmarks): harness, configs,
   methodology, and reporting.

Snapshot: `main` @ `29a43e9` plus PR
[#137](https://github.com/ColtonHarris999/Python-CPU/pull/137) (8-cycle L2
hit), which is merged into this branch but not yet into `main`. The
benchmark-feature tables in §2 come from an AST scan of the pinned
upstream sources. Opcode, type and builtin tables are not copied here;
follow the links to `pycore/docs/` and `pycore_firmware/builtins/builtins.md`.

---

## 0. Ground rules and starting point

### 0.1 Rules for a standard result

1. **Benchmark bodies are upstream, byte for byte**, at the pinned
   commit. Only the driver changes: pyperformance's `pyperf.Runner` and
   MicroPython's `benchrun.py` timer are provided by PyCore shims (§1.6),
   so even the upstream `__main__` block and `bm_run(N, M)` call run
   unchanged.
2. **Size is set through the benchmark's own knobs**: MicroPython's
   `(N, M)` parameters, pyperformance's command-line arguments
   (`--iterations`, `--width`, `--level`, …). Where pyperformance has no
   knob (a module constant such as `fannkuch`'s `DEFAULT_ARG = 9`), a
   one-line **size-only patch** is allowed. It is stored in
   `pycore/benchmarks/patches/` and the result is labeled with the size
   used.
3. **No algorithm patches in headline numbers.** If a benchmark only runs
   after rewriting its code (for example, replacing a generator), it goes
   in a separate "patched" table, never into the headline geometric mean.
4. **Same source, same size, three machines**: PyCore, CPython 3.14 and
   MicroPython (unix port) run the identical driver and size. Output must
   match CPython before a PyCore cycle count counts (§3.5).

### 0.2 What already exists

| Piece | Where | Use |
| --- | --- | --- |
| On-device compile + run | `pycore_cli.py run`, `make run-file` (`pycore/docs/exec_runner.md`) | Secondary path; the compile-cost diagnostic |
| Host-compile path | `pycore_cli.py run --host-compile` | Primary path: the hart runs exactly CPython's bytecode, and module-level classes work |
| Phase marks | `tb_container.sv` `+PHASE_MARKS=1`, console bytes `0x01..0x07` | Cycle, bytecode, excore and cache counts at chosen points |
| Perf counters | end of every `tb_container` run | L1I/L1D/CODC/GIC hit/miss, RF spills, fetch buffer |
| CPython reference | `host_reference.py` | Cold and warm CPython time; `perf_event_open` cycles if available |
| Runtime knobs | `+MEM_LATENCY`, `+CACHE_EN`, `+MAX_CYCLES` | Memory sweeps without a rebuild |
| Memory model | `pycore/tools/memsim/` | Cache what-ifs without Verilator |

### 0.3 Constraints that shape the plan

- **Simulation speed.** Verilator runs about 85–90k cycles/s: about 5 M
  cycles a minute, 300 M an hour. A benchmark that takes CPython 1 ms
  (about 3 M host cycles) at a 3× PyCore/CPython cycle ratio is 9 M
  PyCore cycles, about 2 minutes. Upstream default sizes are 100–1000×
  that, so simulation runs **scaled sizes** (§3.2), and full sizes wait
  for an FPGA build (M9).
- **Language subset.** The standard suites use `import`, class
  inheritance, generators, list slicing, negative indices and `%`
  formatting, none of which work on PyCore today (§2.3 has the per-benchmark list).
- **Numbers.** `int` is 64-bit and wraps. `print` takes only
  INT/BOOL/None/SHORT_STR and formats ints as 32-bit
  (`cleanup_report.md` J2).
- **Heap.** About 15 MB of bump-allocated heap, no free, no GC.
- **Errors.** Missing keys, bad indices and unbound names halt with a
  hardware trap instead of raising.

---

## 1. Preparing for benchmarking

Priorities:

- **P0**: without it the numbers are wrong, or the first wave of standard
  benchmarks cannot run.
- **P1**: needed for the bulk of both suites (§2.4 wave 2).
- **P2**: needed for the remaining benchmarks (wave 3) or full-size runs.

### 1.1 Measurement infrastructure

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| M1 | **Cycle-counter builtin and timing marks.** Add `_bi_cycles()` (native, returns the cycle counter as INT) and have it also emit a timing mark (a free mark byte; the exec harness uses `0x01..0x04`). The `time` and `pyperf` shims (§1.6) call it. | P0 | Both upstream drivers time the run themselves: `benchrun.py` calls `ticks_us()` before and after `run()`, and pyperformance's `bench_time_func` benchmarks call `pyperf.perf_counter()` inside the benchmark. If those calls read the real cycle counter, the upstream timing code works unchanged, and setup stays outside the timed region. |
| M2 | **Perf-counter port** (`cleanup_report.md` D6). Replace the 19 hierarchical-path probes in `tb_container.sv` with a `perf_o` struct on `pycore_core`. | P0 | The counters are the headline diagnostic data. Today, renumbering an FSM state silently changes what they count. |
| M3 | **Cycle attribution by FSM state and opcode**: cycles in `S_FETCH`, `S_DECODE..S_WB`, `S_CONTAINER`, `S_CALL`, `S_RETURN`, `S_STRACC`, `S_TRAP_MARSHAL`/`S_TRAP_WAIT`, `S_RF_SPILL`/`S_RF_FILL`, plus an issued-opcode histogram and cycles inside ROM builtins (by code address range). | P0 | "richards is 3× CPython" is not actionable; "40% of richards is `S_CALL`" is. This is what picks the RTL work after the first baseline. |
| M4 | **Benchmark runner** `pycore/tools/bench.py` and manifest `pycore/benchmarks/benchmarks.toml`: suite, upstream path, size for `smoke`/`sim`/`full`, tolerance, cycle budget. Same shape as `hw_tests.py` + `hw_tests.toml`. | P0 | Two suites × ~30 benchmarks × several configs × three machines is hundreds of runs. They need to be one command: parallel, resumable, reproducible. |
| M5 | **Results in the suites' own formats.** Write pyperformance results as **pyperf JSON**, so `python -m pyperf compare_to cpython.json pycore.json` works. Write MicroPython results in `run-perfbench.py`'s output format, so its `-s` comparison mode works. Store under `build/bench/<sha>/<config>/`. | P0 | Standard suites come with standard comparison tools. Using them removes our own tooling from the trust path. |
| M6 | **Faster simulator for benchmarking.** Dedicated Verilator build: `-O3`, `--x-assign fast`, `--x-initial fast`, no trace, `--threads N` if it helps; heartbeat off. Measure cycles/s. | P1 | 2× simulator speed is 2× benchmark size, and size is what makes scaled runs representative. |
| M7 | **Reference machines.** CPython 3.14: real `pyperformance run` with the same arguments, CPU pinned, turbo off where possible. MicroPython: unix port at the pinned commit running `run-perfbench.py` with the same N/M. Record host CPU model and `perf` cycles. | P1 | Gives the two standard comparisons: against CPython (the reference implementation) and against MicroPython (the embedded peer). |
| M8 | **Bench smoke in CI.** A `bench-smoke` job that runs every enabled benchmark at `smoke` size and checks output against CPython. It does not gate on cycles. | P1 | Benchmarks stop running when the subset changes. CI catches that. |
| M9 | **FPGA build for full-size runs.** The RTL has a Vivado flow for the excore single-core (`excore/rtl/singlecore/vivado.sv`). Extend it to the two-core system with synthesizable arithmetic (R3). | P2 | Upstream default sizes (nbody 20 000 iterations, fannkuch 9, go 200 games) are hours to days of simulation. An FPGA runs them at upstream size, which is the only fully standard result. |

### 1.2 RTL updates

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| R1 | **Realistic functional-unit latency.** `pycore_exec.sv` instantiates `pycore_mul`, `pycore_div` and `pycore_fpu` with `LATENCY = 0`: 64-bit multiply, 64-bit divide and every float operation, including `**` through SystemVerilog `real`, finish in one combinational cycle. Choose latencies from a real target (for example MUL 3, DIV 34, FP add/mul 4, FP div 20, FP sqrt 20; `**` to firmware or a multi-cycle unit) and benchmark with them. | P0 | Single-cycle divide and float ops flatter nbody, spectral_norm, float, chaos, raytrace and mandel by an amount nobody can quantify. |
| R2 | **Realistic L2 hit latency.** **Done on this branch** via PR #137: `PYCORE_L2_HIT_CYCLES` 1 → 8, which raised total hardware-test cycles by 58% with identical results. Publish nothing until #137 is on `main`. | P0 | A 128 KB L2 with a 1-cycle hit is not buildable. |
| R3 | **Clock-rate estimate.** Synthesize `pycore_core` (Vivado or an ASIC flow) for Fmax. Needs synthesizable replacements for the behavioral `real` FPU and the `/` `%` in `pycore_div.sv`. | P1 | Cycle ratios are fair; wall-clock claims need a measured clock. Until then, label wall time "at an assumed 100 MHz". |
| R4 | **Static `import`** (`IMPORT_NAME`, `IMPORT_FROM`, a module object kind). Resolve modules from a boot-image module table (`sys.modules`), built by the image builder from the PyCore library in §1.6. Run each module body once on first import, with the module dict as globals (`_bi_exec_globals` already swaps globals). No file loader is needed. | P0 | Every pyperformance benchmark starts with `import pyperf`; most MicroPython ones import `math`, `random` or `io`, and `benchrun.py` imports `time`. Without `import`, no standard benchmark runs unmodified. The full loader (`code_loading.md` §4) is not required. |
| R5 | **Class bases**: first `class C(object):` (most upstream classes use it), then real single inheritance with method override (`class B(A):`), `isinstance` on user classes, and **`super()`** (`LOAD_SUPER_ATTR`). Host images fold module-level classes today, but only without bases. | P0 for `object`, P1 for inheritance, P2 for `super` | `(object)` bases are in chaos, float, hexiom, raytrace, richards, scimark and deltablue. richards, raytrace and scimark subclass; richards_super and deltablue call `super()`. deltablue also subclasses `list`. |
| R6 | **List/tuple slicing**: `BINARY_SLICE` on lists/tuples (parked PR #94), then **slice step** and **`STORE_SLICE`**. | P1 | misc_pystone copies arrays with `x[:]`; nbody, float, go and hexiom slice lists; fannkuch, nqueens, meteor_contest and scimark use a step or slice assignment. |
| R7 | **Negative indices** (`bytecode_support.md` deviation 3). | P1 | chaos, nqueens, meteor_contest, fft and btree use `x[-1]`. |
| R8 | **Generators** (`YIELD_VALUE`, `SEND`, `RETURN_GENERATOR`; exceptions T12) and **generator expressions**. | P2 | nqueens (both suites), generators, scimark, meteor_contest, hexiom, fft, pidigits and core_yield_from. This is the largest remaining hole in the suites. |
| R9 | **Hardware trap → catchable exception** (`master_plan.md` Exceptions T6) and seeding `ImportError`. | P1 | richards checks types with `assert isinstance(...)`; pidigits uses `try`; `benchrun.py` has `except ImportError`. Code that does not raise only needs the type to exist, but a benchmark that does raise must not halt the hart. |
| R10 | **`bytes`, `bytearray`, `memoryview`** to working level (the `BYTES` tag is reserved today). | P2 | misc_aes, misc_mandel and bm_chaos (its image buffer). |
| R11 | **Arbitrary-precision int.** | P2 | Only pidigits in both suites. |
| R12 | **`TO_BOOL` on `OBJECT`**, **`STR * INT`**, tuple ordering comparison (`benchrun.py` compares `(N, M)` tuples). | P1 | Small, but they appear in driver and benchmark code. |

### 1.3 Builtins and methods

Inventory: `pycore_firmware/builtins/builtins.md`. Add only what a §2
benchmark needs, and run the compiler-subset gate on each new ROM body.

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| B1 | **`print` phase 2**: full 64-bit ints (`cleanup_report.md` J2), LONG_STR, `float` (CPython `repr` rounding), tuples/lists/`None` in one call. | P0 | `benchrun.py` ends with `print(ticks_diff(t1, t0), norm, out)`, and `out` is often a float or tuple. Today `print(2**32)` prints `0`, so a correct result can fail the check, or a wrong one can pass. |
| B2 | **`%` and `str.format` formatting** (`BINARY_OP` `%` on `str`; format specs, `FORMAT_WITH_SPEC`). | P1 | 13 of the in-scope pyperformance sources and 4 of the MicroPython ones use `%`, mostly in output and descriptions that still run. |
| B3 | **String methods**: `split`, `replace`, `strip`/`rstrip`, `splitlines`. | P1 | bm_wordcount and core_str need `split`/`replace`; hexiom parses its puzzle with `splitlines`/`strip`. |
| B4 | **List methods**: `sort` (`key=`, `reverse=`), `insert`, `index`, `remove`, `reverse`; **`max(iterable)`** (J1). | P1 | hexiom, deltablue, go and scimark. Today only `append/pop/extend/clear` exist. |
| B5 | **`@staticmethod`, `@property`, `@classmethod`** (descriptor protocol, `master_plan.md` §4). | P1 | misc_raytrace uses `@staticmethod`; deltablue uses decorators. |
| B6 | **`min`/`max` of empty raise**, **`getattr` without default raises**. | P2 | Correctness parity, rarely on a hot path. |

### 1.4 Memory system

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| H1 | **Headline memory configuration**: cache on, `MEM_LATENCY=30`, `RAM_T_BEAT=2`, L2 hit 8 (R2), R1 latencies. Use it for every published number; CI's latency 4 is never published. | P0 | A test setting is not a machine. |
| H2 | **Memory sweep**: cache off at latency 1 (ideal memory); cache on at latency 4, 30 and 100. | P1 | Separates core-bound from memory-bound benchmarks and shows what the hierarchy buys. `make test-caching` already shows results do not depend on latency. |
| H3 | **Heap watermark per run.** Record `_bi_heap_mark()` before and after the timed region; flag runs with less than 1 MB headroom. Map MicroPython's M (target heap KB) to a checked limit. | P0 | With a 15 MB bump heap, allocation limits benchmark size before cycles do. Running out shows up as `MEM_FAULT`, not a clear error. |
| H4 | **memsim before RTL cache changes.** Point `memsim/experiments.py` at the §2 benchmarks; change RTL cache sizes only when the model predicts ≥ 5% fewer cycles. | P2 | Seconds instead of hours per what-if. |
| H5 | **Recursion and frame limits**: 1024 call frames, 8192 RF spill entries. Record `RF spill_count` with every result. | P1 | go, hexiom and nqueens recurse. Exceeding the tested depth measures a fault, not the machine. |

### 1.5 Garbage collection

Today: bump allocation, no reclamation; `_bi_heap_mark` /
`_bi_heap_release` is the manual stopgap (`compile_limitations.md` §1.4).

**Why it matters:**

1. **Capacity.** The standard benchmarks allocate on every iteration:
   float creates 100 000 `Point` objects at default size, raytrace a
   vector per operation, go a board per game. CPython frees them. PyCore
   runs out of heap at an iteration count unrelated to the benchmark.
2. **Fairness.** Bump allocation with no free is the cheapest possible
   allocator, while CPython pays for refcounting and `free`. Results
   without a collector are optimistic, and the report has to say so.

We cannot add heap resets inside upstream benchmark bodies (rule 0.1.1),
so the stopgap is smaller here than in a hand-written suite.

| Stage | What | When |
| --- | --- | --- |
| GC-0 | **One run per reset.** Each benchmark process makes one timed call (pyperformance `loops=1`, MicroPython runs once anyway), and sizes are chosen so the live heap fits in 15 MB (H3). Label results "no GC". | Now; enough for wave 1–2 at `sim` size. |
| GC-1 | **Heap-full recoverable trap**: when the bump pointer would pass `PYCORE_HEAP_LIMIT`, trap to excore (like list grow) instead of `MEM_FAULT`. | Before GC-2; also gives a clear error. |
| GC-2 | **Stop-the-world, non-moving mark-sweep in excore firmware.** Roots: the live RF window, spilled RF entries (`0xF40000..`), frame descriptors, the globals, builtins and module dicts, the exception arena. Tags make every word self-describing, so the scan is precise. The sweep builds size-class free lists, and the hart allocates from them before bumping. Needs a size header on every heap object (check `object_model.md` for which kinds have one). | P1 at `full` size; required for float, raytrace and go at upstream size, and for pyperformance `gc_collect` / `gc_traversal`. |
| GC-3 | **Report GC cost separately**: cycles in the GC trap, bytes reclaimed, longest pause. | With GC-2. |

Reference counting is not recommended: it adds work to every load and
store path in the RTL and doubles memory traffic, which is exactly what
the benchmarks measure. O-2 (split compiler arenas, master plan track 1)
helps repeated `compile()`, not program heaps.

### 1.6 Imports and the PyCore library

Upstream sources import a small set of modules. Each becomes a
PyCore-subset Python module in `pycore/benchmarks/lib/`, baked into the
boot image and served by static import (R4). These are drop-in
replacements for the parts the pinned benchmarks call, not general
library ports.

| Module | Needed by | What it must provide | Pri |
| --- | --- | --- | --- |
| `pyperf` | all pyperformance | `Runner` with `.argparser` (`add_argument`; `parse_args` returning the defaults overridden by the manifest size), `.bench_func`, `.bench_time_func` (call once with `loops=1`), `.metadata`; module-level `perf_counter()` over `_bi_cycles()` (M1). The upstream `__main__` blocks then run unmodified. | P0 |
| `time` | MicroPython `benchrun.py` | `ticks_us()`, `ticks_diff()`, `perf_counter()` over `_bi_cycles()`. `benchrun.py` tries `ticks_us` first, so it runs unmodified. | P0 |
| `math` | float, chaos, raytrace, go, nbody (via `**`), scimark, barnes_hut, fft | `sqrt` (make it an exact FPU op: IEEE sqrt is correctly rounded, so it can match CPython bit for bit), `sin`, `cos`, `atan2`, `exp`, `log`, `floor`, `pi`, `e`. Port the fdlibm algorithms for the transcendental functions; they can still differ from host libm in the last bit, hence tolerances (§3.5). | P0 |
| `random` | chaos, go (both); btree | A port of CPython's MT19937 (`_randommodule.c`) and the `random.py` methods the benchmarks call (`seed(int)`, `random`, `randrange`, `randint`, `choice`, `shuffle` via `_randbelow`/`getrandbits`). The generator is 32-bit, so 64-bit ints are enough. With the same seed it gives **the same sequence as CPython**, which is what makes chaos/go outputs comparable. | P1 |
| `io` | hexiom (both) | `StringIO` with `write` / `getvalue`. | P1 |
| `array` | raytrace, scimark (pyperformance) | `array('d', …)` as a list-backed class. | P2 |
| `bisect`, `itertools`, `collections` | meteor_contest, pidigits, generators | The few functions used (`bisect_right`, `islice`/`count`, `deque`). | P2 |
| `cmath` | fft (MicroPython) | `exp`, `pi` on the complex ALU. | P2 |

General `import` of source files and the full module loader (master plan
track 1) are **not** needed for this plan.

### 1.7 Compiler and execution path

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| C1 | **Host-compile is the primary path.** The hart executes exactly CPython's bytecode, so the comparison is "same instructions, different machine". The on-device compiler cannot compile `class` or `import` and emits different code (no inlined comprehensions, no `CACHE`). The device path is only used for the compile-cost diagnostic (§2.5). | P0 | Mixing compile paths across benchmarks makes numbers incomparable. |
| C2 | **Host-compile "run as `__main__`" mode with stdout compare.** Today host-compile runs `managed_entry()` and checks an int/bool. The standard drivers are scripts that print. Add a mode that runs the module as `__main__`, streams stdout and compares it with CPython (as the device path already does). | P0 | Neither upstream driver has a `managed_entry()`. |
| C3 | **Image builder accepts opcodes on paths that never run.** chaos and raytrace contain `with open(...)` that only runs with `--filename`; several modules have `__future__` imports. The builder must accept these (trap only if executed) instead of rejecting the image. | P0 | Otherwise "unmodified" fails on code that never runs. |
| C4 | **Inline comprehensions** (`cleanup_report.md` I1), **`class` and `import` in the on-device compiler**. | P2 | Only for the device-compile column. |

---

## 2. Benchmarks

### 2.1 Why these two suites

- **pyperformance** is how CPython measures itself. Reporting its
  benchmark names at stated sizes, as pyperf JSON, lets a reader put
  PyCore next to any published CPython/PyPy/GraalPy result.
- **MicroPython perf_bench** was built for exactly this problem: run a
  standard set on a slow, small-memory Python machine and compare with
  CPython. Its `(N, M)` sizing makes simulation-scale runs part of the
  standard, not a deviation from it. Published MicroPython numbers for
  real MCUs give a direct "PyCore vs MicroPython on a microcontroller"
  comparison at the same N/M.

### 2.2 Out of scope

Benchmarks that measure C extensions, third-party packages, I/O or
interpreter start-up, none of which exercise a bytecode CPU:

- **pyperformance:** 2to3, argparse, async_tree, asyncio_*, base64,
  bpe_tokeniser, chameleon, concurrent_imap, coverage, crypto_pyaes
  (third-party package), dask, decimal_*, deepcopy, django_template,
  docutils, dulwich_log, fastapi, genshi, hg_startup, html5lib, json_*,
  logging, mako, networkx, pathlib, pickle, pprint, pyflate (hashlib,
  struct), python_startup, regex_*, sphinx, sqlalchemy_*, sqlglot_v2,
  sqlite_synth, stdlib_startup, sympy, telco, tomli_loads, tornado_http,
  typing_runtime_protocols, xdsl, xml_etree, yaml.
- **MicroPython:** `viper_*` (MicroPython's native code emitter),
  `core_import_mpy_*` (`.mpy` loader), `core_qstr` (MicroPython string
  interning internals).

### 2.3 The benchmark set and what each needs

Codes in the **Needs** column are §1 IDs. Every benchmark also needs the
P0 harness items (M1, M4, R4, B1, C1–C3, the `pyperf`/`time` shims).
**LOC** is the number of non-comment source lines.

#### MicroPython `tests/perf_bench`

| Benchmark | LOC | What it measures | Imports | Needs |
| --- | ---: | --- | --- | --- |
| `misc_pystone` | 189 | Pystone (Dhrystone port): globals, record objects, calls, small ints. The classic embedded-Python score. | — | R6 (`x[:]` copy) |
| `core_locals` | 173 | Instance-attribute dict through `getattr(o, name, 0)` / `setattr` with string names | — | — (wave 1 candidate) |
| `bm_wordcount` | 30 | Dict counting with string keys | — | B3 (`split`) |
| `core_str` | 51 | String slicing, `split`, `replace`, `join` | — | B3 |
| `misc_raytrace` | 184 | Float + OO ray tracer (no inheritance) | — | B2, B5 (`@staticmethod`), C3 |
| `bm_float` | 49 | Float objects, method calls, `math` | math | R5 (`object`), R6, math |
| `bm_fannkuch` | 50 | List permutation/reversal | — | R6 (step, slice store) |
| `bm_chaos` | 231 | Chaos-game fractal: float, splines, RNG | math, random | R5, R6, R7, R10, B2, random |
| `bm_hexiom` | 525 | Hexagonal puzzle solver: search, dicts, strings | io | R5, R6, R8 (genexp), B2, B3, B4, io |
| `bm_nqueens` | 46 | Permutations through generators, set comprehensions | — | R6, R7, R8 |
| `bm_fft` | 52 | Complex FFT | math, cmath | R7, R8, cmath |
| `misc_aes` | 163 | AES-CTR on `bytearray` | — | R10 |
| `misc_mandel` | 24 | Mandelbrot into a `bytearray` through `memoryview` | — | R10 |
| `core_yield_from` | 19 | Generator delegation | — | R8 |
| `bm_pidigits` | 44 | Big-int arithmetic | — | R8, R11 |

#### pyperformance 1.14.0 (pure-Python subset)

| Benchmark | LOC | What it measures | Imports (beyond `pyperf`) | Needs |
| --- | ---: | --- | --- | --- |
| `spectral_norm` | 50 | Float math through small function calls, `enumerate`/`zip` | — | — (wave 1 candidate) |
| `unpack_sequence` | 436 | Tuple/list unpacking, 400× per loop | — | — (wave 1 candidate; check frame size) |
| `nbody` | 123 | Float physics on lists of lists; the Benchmarks Game kernel | — | R1, R6 |
| `float` | 44 | Allocating float-field objects, `math` | math | R5, R6, math, GC at full size |
| `fannkuch` | 42 | List permutation | — | R6 (step, slice store); size patch (no CLI knob) |
| `richards` | 301 | OO task scheduler: dispatch, attributes, linked lists | — | R5 (inheritance), R9 (`assert isinstance`) |
| `chaos` | 261 | As MicroPython's, upstream original | math, random | R5, R6, R7, B2, C3, random |
| `go` | 364 | Monte-Carlo Go: OO, RNG, recursion | math, random | R6, B2, B4, random, GC at full size |
| `hexiom` | 532 | As MicroPython's | io | R5, R6, R8, B2, B3, io |
| `raytrace` | 305 | OO ray tracer with an inheritance hierarchy | array, math | R5, R9, B2, C3, array, GC |
| `barnes_hut` | 251 | N-body tree code, plain classes | math | B2, math |
| `richards_super` | 307 | richards using `super()` | — | R5 (`super`), R9 |
| `deltablue` | 446 | Constraint solver: inheritance, `super()`, `list` subclass | — | R5, B4, B5 |
| `nqueens` | 47 | As MicroPython's | — | R6, R7, R8 |
| `meteor_contest` | 182 | Puzzle solver over bitmasks | bisect | R6, R7, R8, bisect |
| `scimark` | 323 | SOR, Monte Carlo, sparse matmul, LU, FFT | array, math | R5, R6, R8, R9, array |
| `generators` | 38 | Generator-based tree walk | collections | R8, collections |
| `coroutines` | 24 | `async def`/`await` call chain | — | async (`compile_limitations.md` §2) |
| `pidigits` | 47 | Big-int arithmetic | itertools | R8, R11, itertools |
| `comprehensions` | 74 | List/dict/set comprehensions over dataclasses | dataclasses, enum, typing | R8, dataclass/enum support — last |
| `gc_collect`, `gc_traversal` | 44 / 25 | Collector throughput | gc | GC-2 + a `gc` module |

### 2.4 Bring-up waves

| Wave | Unblocked by | Benchmarks |
| --- | --- | --- |
| **1** | P0 items (harness, static import, `pyperf`/`time` shims, print phase 2, R1) | MP: `core_locals`. pyperformance: `spectral_norm`, `unpack_sequence`. With B3: `bm_wordcount`, `core_str`. With R6: `misc_pystone`, `nbody`. Small, but it covers the classic Pystone score and two pyperformance numbers, and it proves the harness end to end. |
| **2** | R5 (`object` + inheritance), R6, R7, R9, B2–B5, `math`/`random`/`io` | MP: `bm_float`, `bm_fannkuch`, `bm_chaos`, `misc_raytrace`. pyperformance: `float`, `fannkuch`, `richards`, `chaos`, `go`, `raytrace` (with `array`), `barnes_hut`. **This is the first set worth publishing**: it includes the most-quoted pyperformance OO benchmarks. |
| **3** | R8 generators, `super()`, R10, R11, GC-2 | MP: `bm_hexiom`, `bm_nqueens`, `bm_fft`, `misc_aes`, `misc_mandel`, `core_yield_from`, `bm_pidigits`. pyperformance: `hexiom`, `richards_super`, `deltablue`, `nqueens`, `meteor_contest`, `scimark`, `generators`, `pidigits`, `gc_*`. Last: `coroutines`, `comprehensions`. |

### 2.5 Diagnostics (not reported as benchmark scores)

These explain the standard results; they are never put in the headline
tables.

- **Mechanism microbenchmarks** in `pycore/benchmarks/diag/`: one PyCore
  mechanism each (CODC call path, GIC global lookup, STRACC strings,
  excore container growth, RF spill/fill, exception unwind). The six
  existing `pycore/tools/memsim/bench/bench_*.py` programs start this set.
- **On-device compile cost**: cycles per source line for
  `compile_suite/*.py`, through the device path (`pycore_cli.py run`).
  PyCore is the only machine in the comparison that compiles on the CPU.

---

## 3. How to run the benchmarks

### 3.1 Layout

```text
vendor/pyperformance/            git submodule, pinned at ccc0aeb
vendor/micropython/              git submodule, sparse: tests/perf_bench, pinned at 19e685e
pycore/benchmarks/
  benchmarks.toml                manifest (§3.2)
  lib/                           PyCore library: pyperf, time, math, random, io, ... (§1.6)
  patches/                       size-only patches, one file per benchmark
  diag/                          diagnostic microbenchmarks (§2.5)
pycore/tools/bench.py            runner (M4) and reports (M5)
build/bench/<sha>/<config>/      results: pyperf JSON + perfbench text + PyCore counters
```

Add both submodules next to `vendor/pycpython` and record them in
`vendor/README.md` and `pycore_firmware/THIRD_PARTY.md`.

### 3.2 Manifest and sizes

```toml
[mp.misc_pystone]
suite  = "micropython"
source = "tests/perf_bench/misc_pystone.py"
nm     = { smoke = [32, 10], sim = [100, 100], full = [1000, 1000] }

[pyperf.nbody]
suite  = "pyperformance"
source = "pyperformance/data-files/benchmarks/bm_nbody/run_benchmark.py"
args   = { smoke = "--iterations 5", sim = "--iterations 200", full = "" }
tolerance = { rel = 1e-12 }

[pyperf.fannkuch]
suite  = "pyperformance"
source = "pyperformance/data-files/benchmarks/bm_fannkuch/run_benchmark.py"
patch  = { sim = "patches/fannkuch_arg7.patch" }   # DEFAULT_ARG 9 -> 7, size only
```

Size levels:

| Level | Target | Use |
| --- | --- | --- |
| `smoke` | ≤ 2 M cycles | CI (M8): output check only |
| `sim` | 10–100 M cycles (2–20 min) | Every published simulation number. MicroPython: N/M = (100, 100), its "pyboard / ESP32" class, so published MCU numbers are directly comparable. |
| `full` | upstream defaults | FPGA (M9) only |

Pick each `sim` size so CPython takes 1–10 ms for the timed region, and
record the size next to every result.

### 3.3 How a run works

**MicroPython benchmark:** do what `run-perfbench.py` does. Concatenate
the upstream benchmark file and the upstream `benchrun.py`, then append
`bm_run(N, M)`. Host-compile the result with `pycore/benchmarks/lib/`
on the import path (R4) and run it as `__main__` (C2). `benchrun.py`
imports `ticks_us` from our `time`, which reads `_bi_cycles()`, so its
printed time is PyCore cycles / assumed MHz. The timing marks give the
exact cycle count of the same region. The printed `norm, out` is
compared with CPython running the identical script.

**pyperformance benchmark:** host-compile the upstream `run_benchmark.py`
with our `pyperf` on the import path and run it as `__main__` with the
manifest's arguments. `Runner.bench_func(name, f, *args)` emits a mark,
calls `f(*args)` once, emits a mark. `bench_time_func(name, f, *args)`
calls `f(1, *args)`, whose own `pyperf.perf_counter()` calls mark the
region. The shim prints the benchmark's return value (if any) for the
CPython comparison, and writes the timing as pyperf JSON.

### 3.4 Commands

Today (before M4), only the existing tooling, on a non-standard program:

```bash
git submodule update --init --recursive
make pycore-sim-img-twocore
B=pycore/tools/memsim/bench/bench_fib.py
python3.14 pycore/tools/pycore_cli.py run $B --host-compile \
    --cache-en 1 --mem-latency 30 --max-cycles 400000000
```

After M4:

```bash
python3.14 pycore/tools/bench.py list [--suite micropython] [--wave 1]
python3.14 pycore/tools/bench.py run --size smoke                    # every enabled benchmark
python3.14 pycore/tools/bench.py run --size sim --config headline -j 8
python3.14 pycore/tools/bench.py run --size sim --config sweep 'pyperf.*'
python3.14 pycore/tools/bench.py reference --size sim               # CPython + MicroPython (M7)
python3.14 pycore/tools/bench.py report build/bench/<sha>

# Standard tools on the standard outputs (M5):
python3.14 -m pyperf compare_to build/bench/<sha>/cpython.json build/bench/<sha>/headline/pycore.json
python3.14 vendor/micropython/tests/run-perfbench.py -s build/bench/<sha>/micropython.txt build/bench/<sha>/headline/pycore.txt  # -s: diff two result files
```

Named configs:

| Config | Settings | Use |
| --- | --- | --- |
| `ideal` | cache off, `MEM_LATENCY=1`, FU latency 0 | Upper bound of the core alone |
| `headline` | cache on, `MEM_LATENCY=30`, L2 hit 8, R1 latencies | Every published number |
| `sweep` | cache on at latency 4, 30, 100; cache off at 30 | Memory sensitivity (H2) |
| `ci` | cache on, `MEM_LATENCY=4` | Smoke only, never published |

### 3.5 Methodology

1. **Correctness gate.** PyCore stdout must match CPython 3.14 running
   the identical script. Integer and string outputs must match exactly.
   Float outputs from transcendental functions (chaos, raytrace, fft,
   float) use a relative tolerance stated in the manifest (§1.6 `math`).
   A `MISMATCH`, `TRAP` or `TIMEOUT` is reported and excluded from
   averages.
2. **Same region on all three machines**: the region the upstream driver
   times, with setup excluded.
3. **Determinism.** The simulator is deterministic, so one PyCore run per
   config is enough. CPython uses pyperformance's own repetitions;
   MicroPython uses `run-perfbench.py -a 8`.
4. **Cycles first.** The primary metric is PyCore cycles against host
   cycles for the same region. Wall time is given only at a measured Fmax
   (R3), or labeled "assumed 100 MHz".
5. **Attribution.** Each result carries bytecodes issued, cycles per
   bytecode, the FSM-state breakdown (M3), excore handoffs and wait
   cycles, cache/CODC/GIC hit rates, RF spills and heap used.
6. **Summary.** Geometric mean of PyCore/CPython and PyCore/MicroPython
   cycle ratios, per suite and config, over **unpatched** benchmarks only.
7. **Provenance.** Every result records the PyCore git SHA, both upstream
   pins, size, config, FU latencies, Verilator version and host CPU model.

### 3.6 Reporting

`bench.py report` produces, per SHA:

- **Headline tables**, one per suite: benchmark, size, PyCore cycles,
  CPython cycles, MicroPython cycles, both ratios, cycles per bytecode,
  status (`PASS`, `PASS (size patch)`, or the failure).
- **Coverage line**: N of M in-scope benchmarks running, by wave.
- **Mechanism table**: FSM-state percentages, cache/CODC/GIC hit rates.
- **Memory sweep**: cycles against `MEM_LATENCY` per benchmark.
- **Caveats block**, generated from the config: FU latencies, L2 hit
  cycles, "no GC", assumed clock, size patches.

Archive each milestone report under `docs/benchmarks/<date>.md` (results
describe the machine as built, so they do not go in `planning/`).

---

## 4. Order of work

Each step unblocks the next.

1. **Harness and honesty (P0).** M1–M5, R1, R4, R5 (`object` bases),
   B1, C1–C3, H1, H3, the `pyperf`/`time`/`math` library modules,
   submodules. Land #137 on `main`. Run wave 1 and publish nothing yet;
   this is the internal baseline.
2. **Wave 2 (P1).** R5 inheritance, R6, R7, R9, R12, B2–B5, `random`/`io`,
   M6–M8, H2, H5. Bring benchmarks up one at a time, each with its
   manifest entry and a CI smoke run. **First published report.**
3. **Optimize from the data.** Use the M3 breakdown on wave 2 to choose
   RTL work. Every change gets a `compare` against the wave-2 baseline.
4. **Wave 3 and full size (P2).** R8, `super()`, R10, R11, GC-1–3, R3,
   M9, and the remaining library modules. Full upstream sizes on FPGA.
