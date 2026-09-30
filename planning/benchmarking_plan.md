# Benchmarking plan

Goal: publishable, repeatable numbers for PyCore running real Python
workloads, compared with CPython 3.14 on the same source, plus the
per-mechanism breakdown that says where the cycles go.

This plan has three parts:

1. [Preparing for benchmarking](#1-preparing-for-benchmarking): what has
   to change in the RTL, builtins, memory system, runtime and tooling
   before the numbers mean anything.
2. [Benchmarks](#2-benchmarks): which programs to run, and why each one.
3. [How to run them](#3-how-to-run-the-benchmarks): harness, configs,
   methodology, and reporting.

Snapshot: `main` @ `29a43e9`, 2026-09-30. Opcode, type and builtin tables
are not copied here; follow the links to `pycore/docs/` and
`pycore_firmware/builtins/builtins.md`.

---

## 0. Starting point

What already exists and can be reused:

| Piece | Where | What it gives a benchmark |
| --- | --- | --- |
| On-device compile + run | `pycore_cli.py run`, `make run-file` (`pycore/docs/exec_runner.md`) | Source in, stdout out, CPython diff, cycles per phase |
| Host-compile path | `pycore_cli.py run --host-compile`, `HOST_COMPILE=1` | Runs CPython's own bytecode on the hart; accepts module-level `class` |
| Phase marks | `tb_container.sv` `+PHASE_MARKS=1`, console bytes `0x01..0x07` | Cycle, bytecode, excore, L1I/L1D counts at arbitrary points |
| Perf counters | end of every `tb_container` run | L1I/L1D/CODC/GIC hit/miss, RF spills, fetch buffer |
| CPython reference | `host_reference.py` | Cold and warm CPython time, `perf_event_open` cycles when available |
| JSON report | `--json`, `build/pycore_exec/report.json` | Every number, machine-readable |
| Memory-system model | `pycore/tools/memsim/` + six `bench_*.py` | Cache what-ifs without Verilator |
| Runtime knobs | `+MEM_LATENCY`, `+CACHE_EN`, `+MAX_CYCLES` | Memory sweeps without a rebuild |

Constraints that shape everything below:

- **Simulation speed.** Verilator runs about 85–90k cycles/s. One
  minute is about 5 M cycles; one hour is about 300 M. Every benchmark
  needs a scale parameter so a run fits in 5–100 M cycles.
- **Language subset.** No `import`, generators, `with`, `match`,
  class inheritance, list/tuple slicing, negative indices, `STR * INT`,
  or format specs (root `README.md`, `compile_limitations.md` §4).
- **Numbers.** `int` is 64-bit and wraps. `print` takes only
  INT/BOOL/None/SHORT_STR and formats ints as 32-bit (`cleanup_report.md` J2).
- **Heap.** About 15 MB of bump-allocated heap, no free, no GC.
- **Errors.** Missing keys, bad indices and unbound names halt with a
  hardware trap instead of raising.

---

## 1. Preparing for benchmarking

Items are tagged by priority:

- **P0**: without it the numbers are wrong or cannot be collected.
- **P1**: needed to run the standard benchmark set in §2.2.
- **P2**: needed for the extended set (§2.3) or unmodified upstream suites.

### 1.1 Measurement infrastructure

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| M1 | **Benchmark region marks.** Add two mark bytes (the exec harness uses `0x01..0x04`; `0x05`/`0x06` are free) meaning "timed region begin / end", and teach `pycore_exec.py` to report the region separately from setup. | P0 | Today the smallest unit is a whole phase, so data setup, list building and the checksum loop count as benchmark time. CPython is timed around the same region, so the two sides measure identical work. |
| M2 | **Perf-counter port** (`cleanup_report.md` D6). Move the 19 hierarchical-path probes in `tb_container.sv` into a `perf_o` struct on `pycore_core`. | P0 | The counters are the headline data. Today a renumbered FSM state silently changes what they count. |
| M3 | **Cycle attribution by FSM state and opcode.** Count cycles spent in `S_FETCH`, `S_DECODE..S_WB`, `S_CONTAINER`, `S_CALL`, `S_RETURN`, `S_STRACC`, `S_TRAP_MARSHAL`/`S_TRAP_WAIT`, `S_RF_SPILL`/`S_RF_FILL`; plus an issued-opcode histogram. Dump with the other counters. | P0 | "PyCore is 2.4x CPython" is not actionable. "38% of cycles are in `S_CALL` and 20% waiting on excore" is. This is the data that directs RTL optimization after the first round. |
| M4 | **Benchmark runner** `pycore/tools/bench.py` and manifest `pycore/benchmarks/benchmarks.toml` (name, path, scale params for `smoke`/`full`, expected checksum, cycle budget, compile path). Shape it like `hw_tests.py` + `hw_tests.toml`. | P0 | Dozens of benchmarks × several memory configs × two compile paths is hundreds of runs. They have to be one command, parallel, and resumable. |
| M5 | **Results store and report.** One JSON per run under `build/bench/<git-sha>/<config>/<bench>.json`, and a `bench.py report` that emits a Markdown/CSV table and a per-benchmark diff between two SHAs. | P0 | Regressions and wins are only visible against a baseline. |
| M6 | **Faster simulation.** A dedicated Verilator build for benchmarking: `-O3`, `--x-assign fast`, `--x-initial fast`, no trace, `--threads N` if it helps this design; heartbeat off. Measure cycles/s before and after. | P1 | A 2x faster simulator doubles the benchmark sizes that fit, and the sizes are what make results representative. |
| M7 | **CPython reference methodology.** Pin the host CPU, disable turbo if possible, run N ≥ 5 repeats, record cold and warm, record `perf` cycles or an honest `~` estimate. Add a second reference: **MicroPython** (unix port) on the same host, run with the same sources. | P1 | CPython is the correctness oracle, but it is a JIT-less, heavily cached desktop interpreter. MicroPython is the closer peer for an embedded Python machine; a reviewer will ask for it. |
| M8 | **Bench smoke in CI.** A `bench-smoke` job that runs every benchmark at the `smoke` scale, checks output against CPython, and fails on mismatch. It does not gate on cycles. | P1 | Benchmarks rot when the language subset changes. CI keeps them runnable. |

### 1.2 RTL updates

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| R1 | **Realistic functional-unit latency.** `pycore_exec.sv` instantiates `pycore_mul`, `pycore_div` and `pycore_fpu` with `LATENCY = 0`: a 64-bit multiply, a 64-bit divide, and every float op (including `**`, via SystemVerilog `real`) finish in one combinational cycle. Pick latencies from a real target (for example MUL 3, DIV 34, FP add/mul 4, FP div 20; `**` should be firmware or a multi-cycle unit), make them plusargs or a benchmark build parameter, and report numbers at those latencies. | P0 | Single-cycle divide and float ops flatter every arithmetic benchmark (nbody, spectral_norm, mandelbrot) by an amount nobody can quantify. This is the single biggest credibility issue. |
| R2 | **Realistic L2 hit latency.** `PYCORE_L2_HIT_CYCLES = 1` (`memory_hierarchy.md`). Benchmark at a realistic value (8–12) as well as 1. | P0 | A 128 KB L2 with a 1-cycle hit is not a buildable part. Same credibility issue as R1, for the memory system. |
| R3 | **Clock-rate estimate.** The report assumes 100 MHz. Get an FPGA (Vivado) or ASIC synthesis estimate of Fmax for `pycore_core`. This needs synthesizable replacements for the behavioral `real` FPU and the `/` `%` operators in `pycore_div.sv`. | P1 | Cycle ratios are fair; wall-clock claims are not until Fmax is measured. Until then, report cycles and label wall time "at an assumed 100 MHz". |
| R4 | **Hardware trap → catchable exception** (`master_plan.md` Exceptions T6): `KeyError`, `IndexError`, `ZeroDivisionError`, `TypeError`, `AttributeError`. | P1 | Several standard benchmarks use `try/except KeyError` for dict counting or `IndexError` to end a scan. Without it they have to be rewritten, and the rewrite changes the work being measured. |
| R5 | **Negative indices** (`bytecode_support.md` deviation 3). | P1 | `xs[-1]` is everywhere in benchmark code (stack tops in richards/deltablue, the last row in fannkuch). Rewriting with `len(xs)-1` adds work CPython does not do. |
| R6 | **List/tuple `BINARY_SLICE`** (parked PR #94), then **slice step** and **`STORE_SLICE`**. | P1 | fannkuch reverses with `perm[:k+1] = perm[k::-1]`; merge sort and several string benchmarks slice lists. |
| R7 | **Class inheritance** (`class B(A):`, method override, `super()` via `LOAD_SUPER_ATTR`). Host-compile images fold module-level classes today, but only with no bases. | P1 | richards, deltablue, raytrace and chaos are the standard OO benchmarks, and all subclass. OO dispatch is also a core claim for a Python CPU; it must be measured. |
| R8 | **`TO_BOOL` on `OBJECT`** (`__bool__`/`__len__`) and **`STR * INT`**. | P2 | Small, but they show up in benchmark sources (`if node:`, `"-" * 40`). |
| R9 | **Generators** (`YIELD_VALUE`, `SEND`; `master_plan.md` Exceptions T12). | P2 | pyperformance's nqueens, generators, and many idiomatic loops use them. Rewrite the §2.2 set without generators; revisit for §2.3. |
| R10 | **Arbitrary-precision int.** | P2 | Only pidigits needs it. Keep every other benchmark inside 63 bits (mask with `& 0x7FFF...`) so wraparound never changes a checksum. |

### 1.3 Builtins

Inventory: `pycore_firmware/builtins/builtins.md`. Add builtins only when a
benchmark in §2 needs them, and run the compiler-subset gate on each new
ROM body.

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| B1 | **`print` of full 64-bit ints** (`cleanup_report.md` J2) and of LONG_STR. | P0 | Checksums are printed. `print(2**32)` prints `0` today, so a correct result can show as a mismatch and a wrong one can pass. |
| B2 | **`max(iterable)`** (`cleanup_report.md` J1). | P1 | Common in benchmark result reduction; traps today. |
| B3 | **`list.sort()`** (with `key=`, `reverse=`), `sorted(key=)`, **`list.insert/index/remove/reverse`**. | P1 | Sorting and priority-queue code (richards, deltablue, sort benchmarks). Only `append/pop/extend/clear` exist. |
| B4 | **`str.split`, `str.replace`, `str.upper/lower`, `str.strip`**; `dict.setdefault`, `dict.items()` iteration speed. | P1 | Word-frequency and text benchmarks exercise STRACC; without `split` there is no tokenizing workload. |
| B5 | **Math helpers**: `sqrt`, `sin`, `cos`, `atan2`, `pi` as ROM builtins or a shim (§1.6). `float.__pow__(0.5)` works today but hides the cost behind R1. | P1 | nbody, spectral_norm, raytrace, chaos, float. |
| B6 | **`min`/`max` of empty raise `ValueError`**, **`getattr` without default raises** (`master_plan.md` §4). | P2 | Correctness parity; rarely on a hot path. |
| B7 | **Deterministic RNG.** An LCG (or xorshift64) `Random` with `random()`, `randint()`, `choice()`, `seed()`, identical on PyCore and CPython. Ship it as a shim, not a ROM builtin. | P1 | chaos, deltablue data sets, and any randomized input. CPython's Mersenne Twister cannot be matched without `import random`. |

Note for the report: ROM builtins (`print`, `sum`, `sorted`, `map`, …) are
bytecode on PyCore and C on CPython. Break out cycles spent inside ROM
builtins (M3 can tag them by code-object address range) so the comparison
is honest in both directions.

### 1.4 Memory system

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| H1 | **Headline memory configuration.** Choose one "realistic" config (cache on, `MEM_LATENCY=30`, `RAM_T_BEAT=2`, L2 hit 8+, R1 latencies) and report it everywhere; keep CI's latency-4 config out of results. | P0 | The CI default (`MEM_LATENCY=4`) is a test setting, not a machine. |
| H2 | **Memory sweep.** Every benchmark at: cache off lat 1 (ideal memory), cache on lat 4 / 30 / 100. | P1 | Separates core-bound from memory-bound benchmarks, and shows what the cache hierarchy buys. `make test-caching` already proves results are latency-independent. |
| H3 | **Heap watermark per benchmark.** Record `_bi_heap_mark()` at region start/end in every run; fail the run if headroom drops under 1 MB. | P0 | With a 15 MB bump heap, scale parameters are bounded by allocation, not cycles. Allocation-heavy runs fail with `MEM_FAULT`, not a clear error. |
| H4 | **Cache size sweep in memsim first.** Run `memsim/experiments.py` on the §2 set before any RTL cache change; only change RTL sizes when memsim predicts ≥ 5% cycles. | P2 | The existing tool answers "what would a bigger L1D buy" in seconds instead of hours. |
| H5 | **Recursion and frame limits.** 1024 call frames and 8192 RF spill entries. Keep recursion depth ≤ 500 in benchmarks (the tested depth) and record `RF spill_count` in results. | P1 | Recursive benchmarks (fib, hanoi, ackermann) are also the RF-spill benchmarks; exceeding the tested depth measures a fault, not the machine. |

### 1.5 Garbage collection

Today: bump allocation, no reclamation, `_bi_heap_mark` / `_bi_heap_release`
as the manual stopgap (`compile_limitations.md` §1.4).

**Why it matters for benchmarking:**

1. **Capacity.** Steady-state benchmarks run many iterations. Each
   iteration allocates lists, tuples, objects and long strings that
   CPython frees. PyCore runs out of heap at an iteration count that has
   nothing to do with the benchmark.
2. **Fairness.** Bump allocation with no free is the cheapest possible
   allocator. CPython pays for refcounting and `free`. Results without a
   collector are optimistic, and the report has to say by how much.

**Plan, in stages:**

| Stage | What | When |
| --- | --- | --- |
| GC-0 | **Per-iteration mark/release** in the benchmark harness: `m = _bi_heap_mark()` before each iteration, `_bi_heap_release(m)` after, with only an int checksum surviving. Label results "no GC (arena reset per iteration)". Caveat: `_bi_heap_release` flushes CODC and GIC (`memory_hierarchy.md` invalidation matrix), so the first calls and global loads of every iteration miss. Count those flushes and report them. | Now. Unblocks §2.2. |
| GC-1 | **Heap-full recoverable trap.** When the bump pointer would cross `PYCORE_HEAP_LIMIT`, raise a new recoverable trap to excore instead of `MEM_FAULT`, like list grow. | Before GC-2; also gives a clean error. |
| GC-2 | **Stop-the-world, non-moving mark-sweep in excore firmware.** Roots: the live RF window, spilled RF entries (`0xF40000..`), frame descriptors, the globals and builtins dicts, the exception arena. Tags make every word self-describing, so the scan is precise. Sweep builds size-class free lists; the hart allocates from a free list before bumping. Needs an object-size header on every heap object (check `object_model.md` for which kinds already carry one). | P2. Required for binary_trees and any benchmark whose live set turns over. |
| GC-3 | **Report GC cost separately** (cycles in the GC trap, bytes reclaimed, pause length). | With GC-2. |

Reference counting is not recommended: it touches every `LOAD`/`STORE`
path in the RTL and doubles memory traffic, which is exactly what the
benchmarks are measuring. O-2 (split compiler arenas, `master_plan.md`
track 1) is separate: it helps repeated `compile()`, not program heaps.

### 1.6 Imports and the standard library

There is no `import` (`IMPORT_NAME` needs the module loader, master plan
track 1). Every upstream benchmark starts with `import time`, often
`import random, math`.

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| I1 | **Import-free benchmark sources.** Each benchmark in `pycore/benchmarks/` is self-contained. No `time` (the harness times it, §3), no `random` (B7 shim), no `math` (B5 shim). | P0 | Required to run anything upstream-derived today. |
| I2 | **Shim amalgamation.** `pycore/benchmarks/_shims.py` holds the RNG and math helpers. `bench.py` textually prepends only the shims a benchmark names (a `# shims: rng, math` header), so the file runs unchanged under CPython and on PyCore. | P1 | One source of truth for shims; avoids hand-copying an LCG into ten files where one of them drifts. |
| I3 | **Real `import`** of in-image modules (`IMPORT_NAME`/`IMPORT_FROM`, a module registry, the loader format in `code_loading.md` §4). | P2 | Only needed to run unmodified pyperformance / MicroPython `perf_bench` files. |

### 1.7 Compiler and language path

| ID | Item | Pri | Why it is needed |
| --- | --- | --- | --- |
| C1 | **Choose the compile path per benchmark.** Use **host-compile** as the primary path for run-phase numbers: the hart executes the exact bytecode CPython executes, so "same instructions, different machine" holds. Use **device-compile** (`run`) as a secondary column and for the compile benchmark. | P0 | The on-device compiler emits different code (no inlined comprehensions, no `CACHE`, different peephole). Mixing paths across benchmarks makes the numbers incomparable. |
| C2 | **Host-compile harness support for printing and region marks.** Host-compile runs `managed_entry()` and checks an int/bool return. Make sure the M1 marks and stdout capture work on that path too. | P0 | Otherwise the primary path has only whole-program cycles. |
| C3 | **Inline comprehensions** (`cleanup_report.md` I1). | P2 | Device-compiled comprehension-heavy code pays a call and frame per comprehension that CPython 3.12+ does not. Matters only for the device-compile column. |
| C4 | **`class` in the on-device compiler** (`LOAD_BUILD_CLASS`). | P2 | Needed before OO benchmarks can run on the device-compile path. |

### 1.8 Correctness gate

A cycle count is recorded only if the run's output (checksum line) matches
CPython 3.14 on the same source. `bench.py` enforces this; a `MISMATCH`,
`TRAP` or `TIMEOUT` run is reported as such and excluded from averages.

---

## 2. Benchmarks

Selection rules:

- Well known, so results mean something to readers (pyperformance,
  MicroPython `tests/perf_bench`, classic interpreter kernels).
- Each has a **scale parameter** and a **checksum** result, so the same
  file is a 1 M-cycle smoke test and a 50 M-cycle measurement.
- Together they cover every hardware mechanism PyCore adds: tagged ALU,
  CODC (call metadata), GIC (global lookup), STRACC (strings), excore
  (container growth), RF spill/fill, and the cache hierarchy.

MicroPython's `perf_bench` is the best single source: it was written for
small interpreters, is parameterized (`bm_params`), and avoids most
CPython-only features. pyperformance is the reference CPython users know.

### 2.1 Microbenchmarks (runs today)

One mechanism each. They are how a change to the RTL is attributed.

| Benchmark | Measures | Mechanism |
| --- | --- | --- |
| `int_loop` | `while i < n: i += 1; acc ^= i * 3` | Scalar pipe, fetch, branch |
| `float_loop` | Fused multiply-add chain on floats | FPU (meaningful only after R1) |
| `call_overhead` | Calls to a 0/1/3/6-argument function | CODC, `S_CALL`/`S_RETURN` |
| `method_call` | `obj.m(x)` on a module-level class | `LOAD_ATTR` method path, object layout |
| `attr_rw` | `self.x = self.x + 1` | Object attribute store/load |
| `global_lookup` | Loop reading 8 module globals and builtins | GIC hit rate |
| `list_ops` | Append to growth, index read/write, `pop` | Excore grow handoffs vs fast path |
| `dict_ops` | Insert to growth, hit lookup, `get` miss | Hash/probe, excore dict grow |
| `set_ops` | `add`, membership | Set probe, excore set grow |
| `str_ops` | Concat, compare, `find`, index, iterate ≥16-char strings | STRACC |
| `exceptions` | Raise/catch in a loop, one and three frames deep | Exception-table walk, unwind |
| `comprehension` | List/dict/set comprehensions | Nested-function call per comprehension |
| `recursion_depth` | Recurse to depth 400 and back, repeatedly | RF spill/fill |
| `unpack_sequence` | Tuple pack/unpack (pyperformance) | `UNPACK_SEQUENCE`, `BUILD_TUPLE` |

The six `pycore/tools/memsim/bench/bench_*.py` programs already fit this
tier; move them into `pycore/benchmarks/` so memsim and the RTL runs share
one copy.

### 2.2 Standard set (after the P0/P1 items in §1)

| Benchmark | Origin | Why | Needs |
| --- | --- | --- | --- |
| **fib** (recursive) | classic | Pure call/return cost, the most-quoted interpreter number | nothing |
| **sieve** | classic | List store/index in a tight loop | nothing |
| **matmul** | memsim bench, pyperformance-like | Nested list indexing, int multiply | R1 for fair MUL |
| **pystone** | MicroPython `misc_pystone` | Dhrystone port: globals, records (plain classes), calls, strings. The standard embedded-Python score. | module-level classes, H3 |
| **nqueens** | pyperformance / `bm_nqueens` | Recursion, list/set membership | rewrite without generators (R9) |
| **fannkuch** | pyperformance / `bm_fannkuch` | List permutation and reversal | R5, R6 (or index-loop rewrite) |
| **nbody** | pyperformance | Float arithmetic, tuple unpacking | R1, B5 |
| **spectral_norm** | pyperformance | Float arithmetic, function calls in inner loops | R1 |
| **mandelbrot** | MicroPython `misc_mandel` | Float or `complex` (the complex ALU exists) | R1 |
| **quicksort / mergesort** | classic | In-place list swaps; merge sort allocates | R6 for merge sort; GC-0 |
| **sorted_builtin** | classic | `sorted()`/`list.sort` on ints and short strings | B3 |
| **crc32 / xorshift** | classic | 64-bit bit ops, masking | nothing |
| **wordcount** | memsim bench | Dict counting on string keys | B4, R4 for the `KeyError` form |
| **richards** | pyperformance | OO scheduler: dispatch, attribute access, linked lists | R7, R5 |
| **float** | pyperformance / `bm_float` | Allocates many small objects with float fields | R1, B5, GC-0 |
| **raytrace** | pyperformance / `misc_raytrace` | OO + float, vector classes | R7, R1, B5, GC-0 |
| **compile** | this repo | On-device `compile()` of `compile_suite/*.py`: cycles per source line. PyCore's own systems-software workload. | device path only |

### 2.3 Extended set (after P2 items)

| Benchmark | Why | Needs |
| --- | --- | --- |
| **binary_trees** | Allocation/GC stress; the benchmark that shows what the missing collector costs | GC-2 |
| **deltablue** | Heavy OO, inheritance, list manipulation | R7, R8, B3 |
| **chaos** | Float, classes, RNG | R7, B7, B5 |
| **hexiom** | Search, dicts, strings | R8, B4 |
| **go** | Large OO program, the biggest pyperformance kernel that is not library-bound | R7, R9, B7, GC-2 |
| **generators** | Generator creation and resumption | R9 |
| **pidigits** | Big-int arithmetic | R10 |
| **self-compile** | The compiler compiling its own sources (`compile_limitations.md` §1.3) | stage-2 fixpoint work |

### 2.4 Not in scope

`json`, `regex_*`, `pickle`, `sqlite`, `asyncio_*`, `django_*` and other
pyperformance entries that measure C extension modules or I/O. They do not
exercise the interpreter and cannot run without a filesystem and imports.

---

## 3. How to run the benchmarks

### 3.1 File layout

```text
pycore/benchmarks/
  benchmarks.toml        # manifest: one table per benchmark
  _shims.py              # rng, math helpers (§1.6 I2)
  micro_int_loop.py
  fib.py
  nbody.py
  ...
pycore/tools/bench.py    # runner (M4) and report (M5)
build/bench/<sha>/<config>/<name>.json
```

### 3.2 Benchmark file convention

Each file runs unchanged on CPython 3.14 and PyCore:

```python
# shims: rng
# PyCore benchmark: nbody. Origin: pyperformance bm_nbody (simplified).

def setup(n):
    """Build input data. Not timed."""
    ...
    return state

def run(state, n):
    """The timed work. Returns an int checksum (< 2**63)."""
    ...
    return checksum

def managed_entry():
    return run(setup(N), N)
```

`N` is injected by the runner from the manifest (`smoke` / `full` scale).
`bench.py` wraps the file in a harness that calls `setup`, emits the
region-begin mark (M1), calls `run` `R` times with a heap mark/release
around each (GC-0), emits region-end, and prints the checksum. The CPython
side times the same region with `time.perf_counter_ns()`.

Manifest entry:

```toml
[nbody]
path = "nbody.py"
path_mode = "host"          # host | device | both
smoke = { n = 20,  repeat = 1 }
full  = { n = 2000, repeat = 3 }
checksum = 1234567
max_cycles = 400_000_000
tags = ["float", "standard"]
```

### 3.3 One-off runs (works today)

```bash
git submodule update --init --recursive
make pycore-sim-img-twocore        # build the two-core simulator once

# Host-compile path (primary): CPython builds the image, the hart runs it.
B=pycore/tools/memsim/bench/bench_fib.py
python3.14 pycore/tools/pycore_cli.py lint $B
python3.14 pycore/tools/pycore_cli.py run $B \
    --host-compile --cache-en 1 --mem-latency 30 --max-cycles 400000000

# Device-compile path: the hart compiles and runs the source, CPython diff.
python3.14 pycore/tools/pycore_cli.py run $B \
    --cache-en 1 --mem-latency 30 --max-cycles 400000000 \
    --json build/bench/bench_fib.json
```

Docker equivalent: `make docker-run-file RUN_SOURCE=$B HOST_COMPILE=1 EXEC_ARGS="--mem-latency 30"`.

These give whole-phase cycles only; setup is included until M1 lands.

### 3.4 Full runs (after M4)

```bash
python3.14 pycore/tools/bench.py list [--tag standard]
python3.14 pycore/tools/bench.py run --scale smoke            # all, fast
python3.14 pycore/tools/bench.py run --scale full --config headline -j 8
python3.14 pycore/tools/bench.py run --scale full --config sweep 'n*'
python3.14 pycore/tools/bench.py report build/bench/<sha>
python3.14 pycore/tools/bench.py compare build/bench/<sha-a> build/bench/<sha-b>
```

Named configs:

| Config | Settings | Use |
| --- | --- | --- |
| `ideal` | cache off, `MEM_LATENCY=1`, FU latency 0 | Upper bound of the core alone |
| `headline` | cache on, `MEM_LATENCY=30`, L2 hit 8, R1 latencies | Every published number |
| `sweep` | cache on at latency 4, 30, 100; cache off at 30 | Memory sensitivity (H2) |
| `ci` | cache on, `MEM_LATENCY=4` | Smoke only, never published |

### 3.5 Methodology

1. **Correctness first.** Checksum must match CPython (§1.8).
2. **Same region on both sides.** Setup excluded (M1). Report
   `cycles per iteration` = region cycles / `repeat`.
3. **Determinism.** The simulator is deterministic, so one PyCore run per
   config is enough; re-run only to confirm a surprise. CPython: median
   of ≥ 5 runs, cold and warm reported, host pinned (M7).
4. **Cycles, not seconds.** Primary metric is PyCore cycles vs host
   cycles for the same region. Wall time only at a measured Fmax (R3),
   or labeled "assumed 100 MHz".
5. **Second reference.** MicroPython unix port on the same host (M7).
6. **Attribute.** For every benchmark record: bytecodes issued, cycles
   per bytecode, FSM-state breakdown (M3), excore handoffs and wait
   cycles, L1I/L1D/L2 hit rates, CODC/GIC hit rates, RF spills, heap
   used, CODC/GIC flushes from mark/release (GC-0).
7. **Summarize.** Geometric mean of PyCore/CPython cycle ratios over the
   standard set, per config. Never an arithmetic mean of ratios.
8. **Record the build.** Git SHA, Verilator version, config, FU
   latencies, and the host CPU model travel with every JSON result.

### 3.6 Reporting

The per-SHA report (`bench.py report`) contains:

- Headline table: benchmark, PyCore cycles/iter, CPython cycles/iter,
  ratio, MicroPython ratio, cycles per bytecode, result status.
- Mechanism table: FSM-state percentages and cache/CODC/GIC hit rates.
- Memory sweep chart: cycles vs `MEM_LATENCY` per benchmark.
- Caveats block, generated from the config: FU latencies, L2 hit cycles,
  "no GC (arena reset per iteration)", assumed clock.

Archive the report for each milestone under `docs/benchmarks/<date>.md`
(not in `planning/`: results describe the machine as built).

---

## 4. Order of work

Each step unblocks the next.

1. **Measure honestly (P0).** M1, M2, M3, R1, R2, H1, H3, B1, C1, C2,
   I1, GC-0. Then build M4/M5 and run §2.1 plus the §2.2 rows that need
   nothing new (fib, sieve, crc32, matmul). This produces the first
   baseline report.
2. **Standard set (P1).** R4, R5, R6, R7, B2–B5, B7, I2, M6, M7, M8, H2,
   H5. Bring up the rest of §2.2 one benchmark at a time; each one lands
   with its manifest entry and a CI smoke run.
3. **Optimize from the data.** Use the M3 breakdown to pick RTL work
   (likely candidates: call path, excore handoff cost, fetch). Re-run
   `compare` against the step-2 baseline for every change.
4. **Extended set (P2).** GC-1/2/3, R8–R10, I3, C3, C4, R3 (Fmax), and
   the §2.3 benchmarks.
