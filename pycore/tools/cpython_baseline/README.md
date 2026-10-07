# CPython 3.14 cycle baseline

Measures one CPython 3.14 binary on a machine you can resize. The output is
cycles and cache hits for three phases:

| Phase | What it is |
| --- | --- |
| `compile_cold` | `compile(source, path, "exec")`. Source to bytecode. The first call, which is what PyCore runs once from reset. |
| `interpret` | The dispatch edge of the cold `exec`: fetch the next code unit, decode the opcode, indirect-jump into the handler. |
| `run` | The rest of that `exec`. Inline opcode bodies inside `_PyEval_EvalFrameDefault`, plus every C helper they call. |

`compile_warm` and `run_warm` repeat the same work. The warm exec reuses the
code object the cold exec specialized (PEP 659). Compare PyCore with the cold
pair. The warm pair is the steady state a pyperformance run keeps after its
discarded warmup.

## Why this shape

CPU and interpreter papers do not time "Python" as one number.

- Ertl and Gregg, "The Structure and Performance of Efficient Interpreters"
  (JILP 2003), split a VM instruction into argument access, the operation,
  and **dispatch** (fetch, decode, indirect branch). On a default 3.14 build
  the tail-call interpreter and the experimental JIT are off, so that edge is
  duplicated at the end of every opcode handler inside
  `_PyEval_EvalFrameDefault`. The tool finds those jump-table sites with
  `objdump` and charges only those instructions. Whole-function attribution
  is what RegCPython (TACO 2023) uses as a proxy; it mixes dispatch with
  inline opcode work. Zhang, Xu, and Xu (SCP 2022) put the real edge near
  8.5% of cycles.
- Ismail and Suh (IISWC 2018) time a simple core as one cycle per retired
  instruction, plus a stall only on a cache miss. That is the cycle formula
  here. An L1 hit is already inside the instruction. A last-level miss is a
  subset of the L1 misses, so it pays `P_L1 + P_LLC`, not `P_L1` twice.
- RegCPython's x86 branch penalty is the pipeline length, 16 cycles. Romer
  et al. (ASPLOS 1996) used 4. Both are presets; `--branch-penalty` overrides.
- Nethercote's Callgrind is the simulator: I1, D1, and a unified last-level
  cache, plus a 2-bit conditional predictor and a small branch-target buffer.
  gem5 is the other standard and is not what this runs. `gem5_classic.toml`
  copies the learning-gem5 cache sizes so a later gem5 run can use the same
  geometry. Do not add `P_br` on top of a TimingSimpleCPU or O3CPU result;
  TimingSimple has no predictor, and O3 already charges the mispredict.
- pyperformance leaves the GC on, and so does this. It does **not** average
  twenty processes. One Callgrind run with a random `PYTHONHASHSEED` is not
  a result, so the runner pins `PYTHONHASHSEED=0` and `PYTHON_JIT=0`.

Callgrind's own manual prefers `perf` when the PMU exists. This repository's
host path (`host_reference.py`) already uses `perf_event_open`, and on a VM
that call fails. The simulated numbers are the baseline in that case. They
are also the numbers to use when the machine under test is not the host:
the preset `pycore` has this hart's 8KB/8KB/128KB caches and latencies, and
it still times the x86-64 CPython binary, not the bytecode hart.

## Run

Requires Python 3.14, `valgrind`, `gcc`, and `binutils` (`objdump`, `readelf`).

```bash
make cpython-baseline
make cpython-baseline CPYTHON_BASELINE_MACHINE=skylake
PYTHONPATH=pycore/tools python3.14 -m cpython_baseline.baseline \
    pycore/programs/demo_exec.py --machine pycore --json build/baseline.json
```

Presets (`--list-machines`):

| Name | Caches | Penalties |
| --- | --- | --- |
| `pycore` | 8KB 4-way L1I, 8KB 4-way L1D, 128KB 8-way L2, 64B | P_L1=7, P_LLC=4, P_br=16, 100 MHz |
| `gem5_classic` | 16KB 2-way L1I, 64KB 2-way L1D, 256KB 8-way L2 | P_L1=16, P_LLC=180, P_br=16 |
| `skylake` | 64KB 8-way L1s, 256KB 4-way L2. L3 is not modeled; DRAM is 173 cycles | P_L1=8, P_LLC=161, P_br=16 |
| `romer` | 8KB direct L1s, 512KB direct L2, 32B lines | P_L1=6, P_LLC=24, P_br=4 |

Overrides (applied on top of the preset, then checked for a power-of-two set
count, which Callgrind requires):

```bash
python3.14 -m cpython_baseline.baseline --suite --machine pycore \
    --l1d-bytes 32768 --l1d-assoc 8 --mem-latency 40 --branch-penalty 5
```

`--mem-latency` is the full miss latency, not the extra penalty. With an LLC
hit of 8, `--mem-latency 40` means `P_LLC = 32`.

A custom machine is a TOML file with the same fields as `machines/pycore.toml`.
`model` must be `simple-core`.

## What a run records

Instrumentation is off during process startup. An `arm` dump must stay under
100k instructions or the record gains a note. Caches are flushed before the
cold compile and then left warm across compile and exec, which is one process
compiling and then running. The garbage collector is left on.

Per phase the JSON has retired instructions, the thirteen Callgrind events,
cycles, CPI, simulated nanoseconds at the spec clock, and for L1I, L1D, and
the LLC: accesses, hits, misses, hit rate, and MPKI. Branch mispredicts are
split into conditional and indirect. The indirect counts are the dispatch
predictor; Callgrind's BTB is a 2004-era model and overstates modern
indirect MPKI (Rohou, Swamy, Seznec, CGO 2015).

`run_cold_breakdown` is `dispatch`, `inline_opcodes`, and `c_helpers`. Their
instruction counts sum to the cold exec. `cycles_per_bytecode` divides the
cold dispatch and cold exec by a native `sys.monitoring` count of the same
source (a fresh code object, so it is the first execution, not the specialized
second one).

The hottest-function list names an exported symbol when the instructions
fall inside one. A stripped `libpython` has no names for its static helpers,
and Callgrind's own ids (`706`) change between runs, so those are labeled
`libpython3.14.so.1.0+0x<address>`.

Valgrind prints `L3 cache found, using its data for the LL simulation` and
then applies `--I1/--D1/--LL`. The tool reads the dump header back and raises
if the simulated geometry is not the one requested.

## Suite

`benchmarks/` is a closed set in the PyCore subset, sized so Callgrind
finishes quickly. It is not pyperformance. The shapes follow the programs
those papers actually discuss: a dispatch floor (`dispatch_loop`), iterative
fib, list traffic, integer dicts, an integer n-body, and a nested-loop
spectral kernel. The suite report ends with the geometric mean of cold exec
cycles and of the dispatch-instruction share.

`benchmarks/research/` is the set those papers actually time: pyperformance,
the Computer Language Benchmarks Game, and SciMark, rewritten onto the
grammar PyCore can compile. `--research` / `make cpython-baseline-research`
runs it. The measured table is `pycore/docs/cpython_benchmarks.md`.

## Formula

```
P_L1I = T_LLC - T_L1I          # extra cycles for an L1I miss that hits LLC
P_L1D = T_LLC - T_L1D
P_LLC = T_mem - T_LLC          # further cycles if that miss also misses LLC

cycles = Ir
       + I1mr * P_L1I + ILmr * P_LLC
       + (D1mr + D1mw) * P_L1D + (DLmr + DLmw) * P_LLC
       + (Bcm + Bim) * P_br
```

Hit rate at L1I is `(Ir - I1mr) / Ir`. At L1D it is
`((Dr + Dw) - (D1mr + D1mw)) / (Dr + Dw)`. LLC lookups are the L1 misses, so
the LLC hit rate is `(L1 misses - LL misses) / L1 misses`. MPKI is
`1000 * misses / Ir`.
