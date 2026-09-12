# Memory-hierarchy study: what PyCore should cache, and why

Findings report ahead of the L1I / L1D / L2 / RAM work. It answers the
question that was asked alongside the hierarchy request: **would
Python-specific cache structures — for code objects, frames, functions,
constants, names — be a meaningful win, or is a conventional hierarchy
enough?**

Short answer: **you need both, and they are not substitutes.** The
interpreter's own metadata traffic is a set of *serial pointer chases* that a
line cache shortens but does not remove; user data traffic is ordinary
addresses that only a line cache can help. Which one dominates depends
entirely on the program, and the two halves of the benchmark set sit at
opposite extremes (0% vs 96% heap traffic).

There is also a free 45%-fewer-misses result hiding in the allocator (F3b).

Harness, benchmarks and raw output: [`pycore/tools/memsim/`](../pycore/tools/memsim/README.md).

---

## 1. Method, and what is *not* measured

Verilator is not required for this study; it is a trace-and-model analysis.

* A program is folded through the **production image flow**
  (`pycore_cli.prepare_module_code` → `image_from_source.build_image_from_code`)
  and the **real dmem addresses** are read out of the built heap image —
  code-object field addresses, `co_consts` / `co_names` tuple bases, the
  globals and builtins dict objects and their tables.
* The **same folded module code** is then executed on CPython 3.14 under
  `sys.monitoring`, recording every retired instruction plus `PY_START` /
  `PY_RETURN` markers, so a `CALL` that pushed a Python frame (including a
  recursive one) is distinguishable from a builtin dispatch.
* Each retired opcode is expanded into the dmem access sequence the as-built
  RTL issues, at those real addresses, against a live shadow of the globals
  dict so that runtime `STORE_NAME` inserts change later probe sequences.

**Cycle model** (read out of `pycore_core.sv`, not measured):

| Component | Cycles | Source |
| --- | --- | --- |
| `S_FETCH`, first slot | 3 | `imem_req` → `ack_r` → registered `instr_valid_o`; `fetch_skip_r` forces a fresh fetch on every re-entry (`pycore_core.sv:545`, `:2226`) |
| each skipped `CACHE` / `EXTENDED_ARG` slot | +2 | separate imem req/ack round trip in `pycore_fetch.sv` |
| scalar pipe (`S_DECODE`+`S_EXEC`+`S_MEM`+`S_WB`) | 4 | control FSM |
| container pipe (`S_DECODE`+`S_EXEC`+terminal phase) | 3 | `S_CONTAINER` bypasses `S_MEM`/`S_WB` |
| **one dependent dmem access** | **3** | set `container_dmem_pending_r` at T; `dmem_req` at T+1; `ack` at T+2; the phase arm only observes `!pending` at T+3 |

Treat absolute CPO as ±1 cycle/opcode. The *ratios between configurations*
are what the study is for.

**Exactly modelled:** `LOAD_CONST`, `LOAD_GLOBAL` / `LOAD_NAME`,
`STORE_NAME` / `STORE_GLOBAL`, `CALL` frame entry, `RETURN_VALUE` frame exit —
all of the interpreter's metadata traffic, at real addresses.

**Bounded, not modelled:** container/heap traffic (list and dict elements,
attributes, iterators). E1c estimates it from RTL-counted per-opcode access
counts. Excluding it from the baseline *understates* total traffic, so every
saving below is a lower bound.

Ten programs: five written for this study (`pycore/tools/memsim/bench/`, all
pass `pycore_cli.py lint`) and five repo fixtures. 64,065 dynamic opcodes.

---

## 2. Findings

### F1 — Fetch, not data, is the single largest cost today

Baseline breakdown over all ten programs: **45.7% fetch, 30.6% pipeline,
23.6% dmem**, CPO 12.54.

The reason is that the image is a 1:1 transcode of CPython wordcode, so every
inline-cache unit CPython reserves is a real 64-bit imem slot that fetch walks
at 2 cycles apiece:

```
dynamic opcodes            64,065
dead CACHE/EXTENDED_ARG    87,572     (1.37 per executed opcode)
cycles burned on them     175,144     (21.8% of all modelled cycles)
```

More than a fifth of the machine's cycles are spent fetching slots that exist
only because CPython's adaptive interpreter wanted somewhere to write a
specialisation. Attribution:

| opcode | dead slots | |
| --- | ---: | --- |
| `BINARY_OP` | 49,970 | 5 cache units each in 3.14 |
| `LOAD_GLOBAL` | 13,036 | 4 |
| `CALL` | 10,452 | 3 |
| `POP_JUMP_IF_FALSE` | 4,989 | 1 |
| `COMPARE_OP` | 4,908 | 1 |
| `LOAD_ATTR` | 1,926 | 9 |

`BINARY_OP` alone is 57% of the waste.

### F2 — The metadata working set is tiny and pathologically conflict-prone

Across the call-heavy programs the metadata stream touches only **143 distinct
64-byte lines (~9 KB)**: 57 code-object lines, 37 name-tuple, 34 globals-table,
24 const-tuple, 21 frame, 9 builtins.

(That count and the sweep below use the six call-heavy programs; the full
ten-program stream touches 151 lines.)

The image layout is stride-regular — code objects 256 B, tuple elements 32 B,
dict slots 64 B — so direct-mapped behaves badly:

| L1D size (64 B line) | 1-way | 2-way | 4-way | 8-way |
| --- | ---: | ---: | ---: | ---: |
| 512 B | 78.7% | 76.0% | 84.9% | 97.2% |
| 1 KB | 84.7% | 84.0% | 99.2% | 99.2% |
| 2 KB | **89.1%** | **99.4%** | **99.4%** | 99.4% |
| 4 KB | 99.4% | 99.6% | 99.6% | 99.7% |

A 2 KB direct-mapped L1D loses 10 points of hit rate to conflicts that 2-way
removes entirely. **Do not ship direct-mapped.**

### F3 — Object layout already rewards a ≥64-byte line

The layout is accidentally cache-friendly, which is worth keeping:

* a tuple element is `{val@+0, tag@+16}` — 32 B contiguous, and `LOAD_CONST`
  reads both, so a 32 B line makes the second access a guaranteed hit;
* a dict slot is `{kval@+0, ktag@+16, vval@+32, vtag@+48}` — 64 B, so a probe
  that hits *can* be one fill and three hits (see F3b — today it usually is
  not);
* a code object is 8 × 32 B fields = 256 B, and `CALL` reads fields 0–4, which
  a 64 B line covers in 3 fills instead of 5 accesses.

Line-size sweep on the metadata stream at fixed 512 B / 2-way: 16 B → 64.9%,
32 B → 70.6%, 64 B → 76.0%. **64 B is the right line.** 128 B buys nothing
(99.51% vs 99.38% at 2 KB) and costs fill bandwidth.

### F3b — …but the bump allocator only aligns to 16 B, so it throws that away

`HeapImageBuilder._alloc` (and `heap_ptr_r` in `pycore_core.sv`) guarantee
16-byte alignment only. Measured over one image: code-object base addresses mod
64 are spread `{0: 14, 16: 12, 32: 9, 48: 12}`, and the builtins dict table
lands at `…b70` — offset 48. **A 64 B dict slot straddles two cache lines three
times out of four.**

Rounding every allocation up to the line size (E8):

| allocator align | distinct lines | 512 B/2w | 1 KB/2w | 2 KB/2w | 2 KB/4w |
| --- | ---: | ---: | ---: | ---: | ---: |
| 16 B (today) | 151 | 75.96% | 83.92% | 99.31% | 99.38% |
| **64 B** | **141** | **84.54%** | **91.19%** | 99.39% | 99.43% |

It saturates by 2 KB, so the payoff is not peak hit rate — it is **a smaller
L1D for the same hit rate**: at 1 KB, aligning cuts misses by 45%. This is a
one-line change in `heap_image.py` and the RTL bump pointer, and it should land
*before* the L1D is sized, not after.

### F4 — Metadata access is a *serial dependent chain*, and that is the crux

This is the finding that decides the Python-specific question. Measured
accesses per execution, and the resulting latency under three regimes:

| opcode | execs | dmem acc/exec | today (3 cyc) | **perfect L1D** (1 cyc) | result cache |
| --- | ---: | ---: | ---: | ---: | ---: |
| `LOAD_GLOBAL` | 3,259 | 8.10 | 24.3 | **8.1** | 1 |
| `CALL` | 3,283 | 6.94 | 20.8 | **6.9** | 1 |
| `RETURN_VALUE` | 3,243 | 4.00 | 12.0 | **4.0** | 1 |
| `LOAD_NAME` | 10 | 8.20 | 24.6 | **8.2** | 1 |
| `LOAD_CONST` | 341 | 2.00 | 6.0 | **2.0** | 1 |
| `STORE_NAME` | 27 | 13.41 | 40.2 | **13.4** | 1 |

A `LOAD_GLOBAL` is: `co_names[i].val` → `co_names[i].tag` → globals header →
`table_ptr` → probe `ktag` → probe `kval` → `vval` → `vtag`. Each address
depends on the previous result. **A 100%-hit L1D still walks all eight links.**
A result cache keyed on `(code object, name index)` collapses the whole chain
into one tag compare.

Same shape for `CALL`: `entry_slot`, `co_consts`, `co_names`, `metadata`,
`co_defaults` are five reads of a *constant, immortal* object
(`pycore_call_fsm.svh` phases 2–6), repeated on every single call to the same
function. Recursive `fib` re-reads `fib`'s code header 3,193 times.

That is the argument for Python-specific structures in one line: **a line
cache attacks miss latency; the interpreter's problem is chain length.**

### F5 — But the metadata/heap split is bimodal, so a generic L1D is not optional

| program | metadata acc | heap acc (est.) | heap share |
| --- | ---: | ---: | ---: |
| `bench_fib` | 60,716 | 0 | 0% |
| `img_deep_callgraph` | 1,183 | 0 | 0% |
| `img_branchy` | 33 | 0 | 0% |
| `bench_objloop` | 293 | 485 | 62% |
| `bench_matmul` | 402 | 4,585 | **92%** |
| `bench_wordcount` | 81 | 1,185 | **94%** |
| `bench_sort` | 369 | 8,637 | **96%** |

Call/name-heavy code is 100% metadata; data-structure code is >90% heap. The
Python-aware structures do nothing at all for `bench_sort`, and the L1D does
comparatively little for `bench_fib`. **Both halves are load-bearing.**

### F6 — Head-to-head, on today's 1-cycle dmem

| change | cycles saved | share | CPO |
| --- | ---: | ---: | ---: |
| baseline | — | — | 12.54 |
| generic L1D 2 KB / 64 B / 4-way | 125,780 | 15.7% | 10.58 |
| const + global IC + code-object cache | 147,186 | 18.3% | 10.24 |
| **predecoded L1I** (strip `CACHE`, 1-cycle hit) | **303,274** | **37.8%** | **7.80** |
| L1I + L1D together | 429,054 | 53.4% | **5.84** |

Sizing for the Python-aware structures (E4):

| structure | key | size | hit rate | cycles saved |
| --- | --- | --- | ---: | ---: |
| code-object descriptor cache | code address | **4 entries, 2-way** | 98.6% | 67,137 |
| global-name inline cache | `(code, namei)` | **16 entries, 2-way** | 99.0% | 78,297 |
| const cache | `(code, const idx)` | 8 entries | 85.3% | 1,746 |
| frame top-of-stack buffer | — | 4 frames | 86.8% | 33,972 |

The code-object cache is remarkable: **4 entries, 2-way gets 98.6%**, because
the live function working set of a loop nest is a handful of code objects.
Going to 16 entries buys 0.2 points. The global IC saturates at 16 entries with
only 27 flushes across the whole run (a `STORE_NAME`/`STORE_GLOBAL` is rare
after module init).

The const cache is the weakest of the four — `LOAD_CONST` is only 341 dynamic
executions here because 3.14 hoists small integers into `LOAD_SMALL_INT`
(6,386 executions in `bench_fib` alone, zero dmem). **The const cache the
architecture doc lists as future work is the *least* valuable of these four.**
A 64 B L1D line already halves `LOAD_CONST` for free.

### F7 — The hierarchy is not an optimisation, it is what keeps CPO from exploding

Today `pycore_dmem` is a 128 KB single-cycle SRAM. That is a fiction that will
not survive real RAM. CPO vs RAM latency:

| RAM latency | no cache | L1I 2K + L1D 2K + L2 16K | + result caches | + predecoded L1I |
| ---: | ---: | ---: | ---: | ---: |
| 1 cyc | 11.54 | 7.24 | 6.47 | **5.10** |
| 20 cyc | 70.94 | 7.30 | 6.53 | **5.16** |
| 60 cyc | 205.12 | 7.43 | 6.66 | **5.29** |

Without caches, a 60-cycle RAM is a **16× regression**. With the hierarchy the
same RAM costs 3.7% over the 1-cycle case. After the result caches only
**14,221 of 63,283** metadata accesses ever reach L1D, and after predecode only
**64,065 of 151,637** fetches ever reach L1I — that reduction in *request count*
is what makes the hierarchy latency-tolerant, not the L2 hit rate.

### F8 — The L2 is insurance, not a measured win (yet)

At a 143-line metadata working set plus small heaps, a 2 KB L1 already runs at
99.4% and the L2 almost never fires. The L2's job is the cases this study
cannot reach: large heaps, the 256 KB code RAM once the on-device compiler
writes into it, string memory, and the excore handoff. Size it for the future,
but do not expect it to show up in these numbers.

---

## 3. Constraints the implementation has to respect

These fall out of the existing design, not the measurements.

1. **excore shares dmem.** `pycore_excore_system.sv` hands the single dmem bank
   between pycore and excore via a registered `mem_owner_r` grant, never
   cycle-level arbitration — pycore is frozen in `S_TRAP_MARSHAL`/`S_TRAP_WAIT`
   while excore owns memory. That makes coherence *easy*: an L1D must write
   back and invalidate at exactly two points, the `trap_req` handoff and the
   `trap_res` return. No snooping, no MESI. Conversely, **the result caches
   must also be invalidated there** — excore resizes and rehashes dicts, which
   moves the very table slots a global IC memoises.
2. **Code RAM is writable and `exec`-able.** Once runtime code-RAM writers land
   (`planning/master_plan.md` track 1), the L1I needs an explicit invalidate —
   a `fence.i` equivalent — on the writer path, and the code-object descriptor
   cache needs one on `MAKE_FUNCTION` / code release
   (`img_code_mark_release.py` already exercises release).
3. **The global IC needs a version, not a flush.** The dict header already
   carries a `version` field (`heap_image.py` bumps it on insert); the natural
   validity check is `(code, namei, globals_base, version)`. A blunt flush on
   every `STORE_GLOBAL` costs nothing today (27 flushes) but will matter for
   generated code.
4. **Predecode changes the PC↔slot invariant.** Today imem slot index equals
   CPython code-unit index and branch args need no remapping
   (`image_from_source` relies on this). A predecoded L1I that strips `CACHE`
   slots must keep the architectural PC in wordcode units and do the
   compaction *inside* the cache line, or branch targets break.
5. **The heap is a bump allocator with no reuse**, so an L1D never sees stale
   lines from freed objects — except via the excore's relocating list/dict
   grow, which is covered by (1).

---

## 4. What I would build, in order

Ranked by measured cycles-per-gate, not by architectural tidiness.

1. **Predecoded L1I** (37.8% of cycles on its own). Strip `CACHE` and fold
   `EXTENDED_ARG` at line fill instead of at fetch. 2 KB, 64 B lines, 2-way is
   already at 99.87%; 4 KB/4-way reaches 99.96% and is probably the right
   shipping point. This is the largest single win and it is independent of
   everything else.
2. **L1D, 2 KB, 64 B lines, 4-way** — or 2-way, which measures identically at
   2 KB and is cheaper. Non-negotiable for heap-heavy programs (F5) and for
   surviving real RAM (F7).
3. **Code-object descriptor cache, 4 entries, 2-way.** Tiny structure,
   98.6% hit, removes 5 dependent reads from every `CALL` and 2 from every
   `RETURN`. Best value-per-flop in the whole study.
4. **Global-name inline cache, 16 entries, 2-way**, validated on the globals
   dict `version`. Removes an 8-link chain 99% of the time.
5. **Frame top-of-stack buffer, 4 frames.** 86.8% of frame push/pop traffic,
   and it is a stack — a shift register, not a cache. Note the attic already
   has an unintegrated design study (`pycore/rtl/attic/pycore_frame_buffer.sv`).
6. **L2, unified, 16 KB+.** Build it for the code RAM / large-heap / storage
   future, not for these numbers.
7. **Line-align the bump allocator (F3b).** One line of code in
   `heap_image.py::_alloc` and `heap_ptr_r`; costs a few hundred bytes of heap
   fragmentation; lets the L1D be half the size. Do this *first*, so the L1D
   is sized against the aligned layout.
8. **Const cache — skip it.** The 64 B L1D line already gets most of it and
   3.14's `LOAD_SMALL_INT` removed most of the traffic. Revisit if the
   on-device compiler emits a different const mix.

## 5. Open questions for the implementation plan

* **One L1D or two?** Metadata and heap have very different reuse. A split
  (or a way-partitioned L1D) would stop `bench_sort`'s list walk from evicting
  the code-object lines. Not measured — needs a mixed workload the current
  benchmark set does not have.
* **Does the FSM keep one logical read per transaction?** An L1D only shortens
  each link (F4). If the container FSM can consume a whole 64 B fill — read a
  dict slot's four words from one fill, or two code fields from one line —
  chains shorten *and* shorten again. That is a control-path change, not a
  cache change, and it may be worth more than the cache.
* **String memory** (`pycore_string_mem.sv`) is a third, separate bank outside
  this study. Does it join the hierarchy or stay private?
* **Storage.** Nothing here constrains it; the natural shape is a block device
  behind the L2 with the module loader as its only client, which fits the
  BIOS/module-loader track already in `master_plan.md`.

## 6. Reproduce

```bash
python3.14 pycore/tools/memsim/experiments.py
```

Prints E1–E8. Requires Python 3.14 (same gate as `image_from_source.py`); no
Verilator.
