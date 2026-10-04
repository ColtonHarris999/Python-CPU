# Garbage collection (as built)

Status: built, **off by default** (`+GC_EN=1` turns it on). Acceptance
gates G0-G16 passed on the 1 MB memory map, except G9 (fixed afterwards,
`img_gc_call_varargs`); the record is
[`planning/gc_plan.md`](../../planning/gc_plan.md) and
[`planning/gc_progress.md`](../../planning/gc_progress.md). On `main`'s
16 MB map it passes the unit gate (G3) and the `gc` test area, and with it
off every existing test is cycle-identical to `main`. It becomes the default
after one full acceptance run on the 16 MB map; the acceptance runner
(`tools/gc_acceptance.py`) still drives the old per-fixture make targets
and is being ported to `hw_tests.toml`.

PyCore has a precise, stop-the-world, non-moving mark-and-sweep collector.
The engine (`pycore/rtl/pycore_gc.sv`) is a core-side dmem master beside
STRACC. Collections start only at instruction boundaries: an allocation that
does not fit aborts its instruction before the first architectural commit,
the core collects, and the instruction is re-dispatched. `S_GC_ENTER` holds
until any outstanding dmem beat from that abort acks, so a skip-clear
`PRELOAD` cannot treat that rdata as prune-map word 0.

## Prior art and design decisions

Phase R of the plan. Each entry answers one row of the plan's §2.5 adoption
table: the decision, why, the expected cycle and area effect, and the G13
measurement that confirms it. Measured numbers replace the expectations as
the gates produce them (§"Performance").

Sources: Bacon, Cheng, Shukla, *And Then There Were None*, PLDI 2012 §3
(CACM 56(12) 2013); Maas, Asanović, Kubiatowicz, *A Hardware Accelerator for
Tracing Garbage Collection*, ISCA 2018 §V and Maas's thesis
(UCB/EECS-2018-152); Ramsay, Stewart, *Cloaca*, Haskell 2024 §6; Blackburn,
McKinley, *Immix*, PLDI 2008; Jones, Hosking, Moss, *The Garbage Collection
Handbook*, 2nd ed.

### 1. On-chip mark stack that spills only on overflow (Maas) — adopted

- **Decision.** A 256-entry on-chip LIFO of compressed entries
  (`{kind[2:0], size[31:0], addr[31:0]}`, 67 bits). When a push finds it
  full, the engine spills the oldest 32 entries to the 512 KB region at
  `PYCORE_GC_MARK_STACK` (one 16 B slot each); when a pop finds it empty and
  the memory part is non-empty, it refills 32. The memory part is sized for
  the provable bound (§4.3 of the plan): at most 30,686 pending entries.
- **Why.** Maas (§V-C, §VI-B) keeps a 1,024-entry mark queue on chip and
  spills only when it is full: spilling was about 2 % of memory requests.
  Our draft (§4.5) made every push and pop a dmem transaction, which roughly
  doubles mark traffic. Depth-first marking of typical PyCore heaps stays
  shallow: a linked chain keeps one or two pending entries; only very wide
  objects (a 16k-element list) overflow. The stack is LIFO, so spilling the
  oldest entries is legal (marking is order-independent).
- **Expected effect.** Removes ~2 transactions per pushed object on normal
  heaps. Area: 256 × 67 bits = 17,152 bits.
- **Measured.** At 64 entries `bench_churn` (a 200-entry live list of
  tuples, stack high-water 202) spilled 320 slots per collection, about a
  third of its mark transactions. At 256 entries it spills none and its GC
  share fell from 0.283 to 0.266 (P6b; the other P6b changes are in
  Performance).
- **Confirmed by.** G13 P7 (spill traffic ≤ 5 % of mark transactions on
  `bench_full` and `bench_deep`); G3 runs with the on-chip part shrunk to two
  entries so the spill and refill path is exercised on every seed.

### 2. Bitmap-slot cache (Maas mark-bit cache) — adopted

- **Decision.** The engine never reads or writes mark bits one at a time.
  It holds one 128-bit bitmap word (128 granules = 2 KB of heap) in a
  register with a dirty bit and writes it back only when the word index
  changes or the phase ends.
- **Why.** Extent marks of adjacent allocations hit the same word, so most
  read-modify-writes become register updates.
- **Expected effect.** With a dmem-backed bitmap, a bitmap transaction pair
  (writeback + fill) only on a word change; with the on-chip bitmap (next
  entry) the cache still turns the array access into a one-cycle refill.
- **Confirmed by.** G13 counters `bm_fills` per marked object on
  `bench_full`.

### 3. Sweep clears the bitmap as it scans (Cloaca Alg. 5; plan credits Bacon) — adopted

- **Decision.** The sweep reads every bitmap word it covers and writes zero
  back to each non-zero word, including the pinned static range below
  `heap_dyn_base`. There is no separate `CLEAR` phase except on the first
  collection after reset (RAM contents are not guaranteed), tracked by a
  `bitmap_clean_r` flag.
- **Why.** Clearing marks during the sweep lets the next collection start
  from a clean map for free. The plan attributes this to Bacon, but Bacon's
  sweep zeroes object data and never states that it clears the Mark Map;
  Cloaca's sweep (Alg. 5) is the published source. Cloaca's first bug (the
  last address read but never written) is the classic failure of such a
  sweep, so G3 heaps vary `heap_limit` to end runs in every bitmap-word
  position, and G4 checks precision (Cloaca's property 3) as well as safety.
- **Expected effect.** Saves one 480-word clear pass per collection.
- **Confirmed by.** Mutant 25 (bitmap not cleared between collections) is
  killed; G4 checks the run list, not a post-sweep bitmap.

### 4. Whole bitmap in on-chip SRAM (Bacon Mark Map) — evaluated

- **Decision.** Both variants are built behind the `GC_BITMAP_ONCHIP`
  parameter: the 7,680 B bitmap either lives in dmem at
  `PYCORE_GC_MARK_BITMAP` behind the slot cache, or in a 480 × 128-bit
  on-chip array behind the same cache. The default is chosen by G13
  measurement at the end of Phase 2 (plan default: dmem).
- **Why.** On chip, a mark costs one cycle and never pollutes L1D/L2; in
  dmem it costs port transactions on every word change but no dedicated
  storage.
- **Expected effect.** On-chip: 61,440 bits of storage; saves 2 port
  transactions per bitmap word change during mark and 2 per word during
  sweep.
- **Confirmed by.** G13 P5 (max pause on `bench_full`) and P3 measured in
  both configurations; numbers recorded below.

### 5. Decoupled marker and tracer (Maas) — issue discipline adopted

- **Decision.** The port contract allows one outstanding request per
  master, so full decoupling (many requests in flight) cannot help. The
  engine instead computes its next address combinationally from the ack
  data and issues the next request in the cycle after each ack.
- **Why.** Maas's speedup (4.2x marking vs an in-order Rocket core, at
  18.5 % of its area, mostly a 64 KB mark queue; §VI-A) tracks memory-level
  parallelism: 8-16 requests in flight. With one outstanding request there
  is no parallelism to harvest. What transfers is having the next request
  ready in the cycle after each ack and doing bitmap and stack work while a
  request is in flight; our tracer and marker are separate FSMs joined by a
  4-entry queue for exactly that overlap.
- **Expected effect.** Port idle ≤ 1 cycle between mark transactions.
- **Confirmed by.** G13 P3 (`port_busy_mark / mark_cyc ≥ 0.80` on
  `bench_full`). A word read returns the containing L1D line; the tracer
  consumes two PLAIN pairs or one 64 B dict slot (`T_LINE_W`), or a 32 B
  list/set header (`T_HDR_LINE_W`), per transaction. `bench_full`
  max_pause 399009 (P5 cap 400000).

### 6. Lazy sweeping (Immix) — evaluated, default eager

- **Decision.** Eager sweep in the pause. Lazy sweeping would move bitmap
  scanning into the run allocator and require the oracle to model
  partially swept heaps.
- **Why.** The eager sweep is linear in 480 bitmap words plus one header
  write per free run; it is expected to be a small share of a pause
  dominated by marking.
- **Expected effect.** Sweep ≤ 4 cycles per bitmap word + 6 per free run.
- **Confirmed by.** G13 P4 and the `sweep_cyc / total_pause` share on every
  benchmark. Lazy sweeping is reconsidered only if that share exceeds 20 %.
  Headers now go to a sequential table at `PYCORE_GC_RUN_TABLE` (not
  in-place); the first 1024 listed runs stay on-chip so sweep pays no
  header miss. `bench_full` sweep is 2172 cycles (P4 cap 5292).

### 7. Root region in memory that the unit reads (Maas) — already adopted

- **Decision.** The core streams register and RF roots into the engine;
  with `+GC_ROOT_STASH=1` the engine also writes them to
  `PYCORE_GC_ROOT_STASH` (count word, then value/tag pairs) so the host
  oracle can compare them with the testbench's independent root record.
  Memory-resident roots (spill, frames, exception stack, boot record,
  native-method table, StopIteration sidecar) are walked by the engine in
  place.
- **Confirmed by.** G4 independent-roots check; mutants 1-11.

### 8. Concurrent collection with a snapshot write barrier (Bacon, Cloaca) — rejected for v1

- **Decision.** Stop-the-world.
- **Why.** Bacon's concurrent collector won because the heap lived in the
  collector's own BRAMs, whose read-before-write ports make a Yuasa barrier
  nearly free (Cloaca relies on READ_FIRST BRAM the same way), and it still
  cost 4-39 % more slices and 2-12 % more BRAM than stop-the-world. PyCore's heap sits behind L1D/L2, and a barrier would be
  needed at every pointer-store site: dozens of RTL container/CALL sites,
  STRACC, and excore firmware (list/dict/set growth). Each would add a
  memory transaction to the mutator's common path, violating the
  zero-cost-when-not-collecting requirement, and the pause targets (G13 P5)
  are met without it.
- **Confirmed by.** G13 P1 (no-collect fixtures are cycle-identical, apart from
  the release-zeroing revision under Performance) and P5.

### 9. Bidirectional object layout (Maas) — rejected

- **Decision.** Layouts stay as the image format defines them.
- **Why.** Object layouts are fixed by `heap_image.py`, `encoding.py`,
  excore firmware and every RTL handler. Extents and child slots are
  already derivable from the owner (§"Traversal"), so the tracer does not
  need references grouped on one side.

### 10. Cloaca's three invariants as executable checks — adopted

- **Decision.** Free-list consistency → G4 run-list well-formedness and G6
  allocator invariants; free set disjoint from the reachable set → G4 exact
  free-set comparison and the G5 shadow-heap checker; every dead address
  reclaimed within a bounded number of passes → G4 with a bound of one
  collection (the collector is precise), and G11 steady-state plateaus.
  Cloaca reports (§6.2) that only the reclamation property caught its real
  bugs, which is why G4 fails on retained garbage, not just on freed live
  data. Cloaca checked its properties with Hedgehog property tests and
  shrinking; our analogue is G3's seeded random heaps and G8's fuzzer, with
  failing programs shrunk into permanent fixtures.
- **Confirmed by.** G4, G5, G6, G11, and mutants 12-28 that violate each.

## Architecture and interfaces

The collector is precise, stop-the-world, and non-moving. `pycore_gc.sv` is a
dmem master beside STRACC. The core only enters it at an instruction boundary,
after the aborting instruction has undone every architectural commit.

States, after the ordinary fetch/execute path:

1. `S_GC_ENTER` drains outstanding dmem beats, including a skip-clear
   `PRELOAD` that must not be consumed as prune-map word 0.
2. `S_GC_ROOTS` streams register and register-file roots into the engine.
3. `S_GC_RUN` marks, sweeps, and rebuilds the free-run list.
4. `S_GC_ALLOC` satisfies the failed allocation from that list, or raises
   `MemoryError` when nothing fits. Raising clears the request's
   "already collected" flag, so the next allocation miss collects again
   before it can fail. An explicit `_bi_gc_collect()` (`need = 0`)
   leaves the free run queued and does not zero it; the bytes are zeroed when
   a later allocation hands them out.

`GC_EN=0` never takes these states. A `NEED_HEAP` result from excore becomes
`MEM_FAULT`, which is what the pre-GC out-of-memory goldens expect.

On the two-core top, excore growth firmware reads `MB_HEAP_LIMIT` (`0x1C`)
and, when the grant is too small, returns `RES_CODE=3` (`NEED_HEAP`) with
`RES_HEAP_PTR` equal to the byte count it needs. PyCore collects and
re-dispatches. The mailbox delays that limit read and the `NEED_HEAP`
response by four cycles so the firmware `lw` matches the old two-instruction
`li` and the old out-of-memory path keeps its cycle count.

The host oracle is `pycore/tools/gc_model.py`. `+GC_DUMP_EACH` writes a
coherent dump per collection; the oracle's trace must match the engine's
free set and counters. The compiler's idle cleanup descriptor
(`PYCORE_GC_COMPILER_CLEANUP`, magic `PYCC`) is part of that dump so the
oracle can reconstruct the two objects the engine premarks while the
compiler arena is idle.

The descriptor lists the reference-valued compiler scratch slots of
`_PYC_G`. When `_PYC_G["_busy"]` is 0 the engine overwrites each with
INT 0 before tracing, so a finished `compile()` does not retain its AST and
emitter arrays. The image builder omits the descriptor when the program
itself names `_PYC_G`: such a program may run compiler passes directly,
with `_busy` still 0, and read their arrays back after they return
(`img_symtab_closure`). For it those slots are data, not scratch. Every
other program reaches them only through `compile()`, which writes `_busy`
first; the core watches that word and the engine skips the clearing loop
when it has not been written since the last one.

While compile() is idle the engine also premarks the builtins dict
header, so it does not walk that table every collection. Builtins values
the prune map keeps (types whose `tp_dict` is mutable) are then roots of
their own: the image lists them at `PYCORE_GC_EXTRA_ROOTS` (32 tagged
pairs in the otherwise unused mark-bitmap region), or clears the builtins
field of the descriptor when they do not fit. The engine traces them only
once the program has executed LOAD_ATTR `__dict__` on a type (the core's
sticky `gc_tdict_exposed_r`): that is the only way to obtain a type dict,
and until then every type dict still holds its static image contents
(`img_gc_compile_loop` would otherwise pay about 4k cycles a collection,
P6a). A program that names none of
`__dict__`, `setattr`, `delattr`, `vars`, `compile`, `exec`, `eval`,
`_bi_exec_globals`, `_bi_code_new`, `_bi_code_blit` or `_bi_code_patch`
cannot obtain a type's dict (STORE_ATTR on a type traps), so the builder
treats type dicts as immutable for it and they are pruned like code
objects.

"Names" means more than `co_names` when the program can run code the
builder never sees. A program that names `compile`, `exec`, `eval`,
`_bi_exec_globals`, or a firmware builtin that calls one of them (`bios`),
also reaches every identifier spelled in its string constants, including
strings inside tuple constants such as folded defaults
(`exec("_PYC_G['k'] = [..]")`, `img_gc_exec_pyc_g`). A
program that names `_bi_code_new`, `_bi_code_blit` or `_bi_code_patch`
assembles code objects with arbitrary names, so the builder assumes it
reaches every name: no cleanup descriptor and no immutable type dicts.
Source text assembled at run time (for example by string concatenation)
that spells `_PYC_G` or `__dict__` is outside this rule; such a program
must name the identifier itself. This is an open hazard
(`planning/master_plan.md`).

A boundary or at-exit collection (no allocation to satisfy) keeps the
current run. An explicit `_bi_gc_collect()` does not: the program asked
for memory back, so the next allocation re-selects first-fit. The engine sets the bitmap bits of the unallocated
`[heap_ptr, heap_limit)` before the sweep, so no listed run overlaps it,
and adds its size to `free`; the core leaves `heap_limit_r` alone. The next
allocation therefore bumps on without a run-list pop (G13 P8).

After any collection except an explicit one, the run search is next-fit:
it starts at the first listed run whose base is at or above the old bump
pointer and wraps to the runs below it before the list counts as empty (the
engine reports the start index as `run_rover_o`; with more than 1024 runs
it falls back to first-fit from the lowest address). Restarting at the
lowest address after every collection re-examined the same small holes:
G8 seed 4 (mode a, a collection at every run switch) popped 590 runs for
1,115 allocations, 72 with the rover. Over seeds 0-9 single-core the corpus
rate fell from 1,662 / 19,824 = 0.084 (keep-run only) to 195 / 17,810 =
0.011. Dumps carry
`keep_lo`/`keep_hi` and the oracle splits its maximal runs around them.

A CALL reserves its binder allocations (the `*args` tuple and the
`**kwargs` dict, each with 64 B of placement slack) before phase 14 on
both the CODC-hit and the CODC-miss path. The binder permutes argument
slots before it allocates, so a binder allocation that failed after that
point could not be unwound (B18).

The CALL a container op launches for a protocol method (`__next__`,
`__iter__`, ...) has no undo record, so an allocation that does not fit
during that launch is out of memory (trap 7). CALLs in the protocol
method's body run at the protocol frame's depth or deeper and abort,
collect and re-dispatch like any other (`img_gc_protocol_body_call`).

## Roots

Scanned at every collection. "Derived" means already reachable from another
root. Mid-instruction scratch (binder temps, STRACC regs, `rs1_r`/`rs2_r`)
is dead at the boundary and is not a root.

| Root | When it is live | Who scans it |
| --- | --- | --- |
| RF ring `[rf_wm_r, tos_r)` | always (empty when equal) | core, one entry per cycle |
| RF spill `[0x100000, spill_sp)` | always | engine |
| Frame descriptors | `frame_active_depth` | engine: caller code, caller globals, constructor instance |
| `cur_code_r`, `globals_base_r`, `builtins_base_r` | after boot | core |
| `cur_closure_r` | nonzero only between CALL of a function and `COPY_FREE_VARS` | core |
| `active_exc_r`, exception stack, pending `call_exc_handle_r` | when valid | core / engine |
| Suspended container call (`saved_rs1`, `saved_rs2`, `proto_iter`) | `container_call_active_r` | core |
| `container_call_result_r` | `container_call_return_valid_r`, not while the call is still active | core |
| Boot record, native-method table, StopIteration sidecar | static | engine |
| CODC / GIC | flushed, not traced | core |

`consts_base_r` and `names_base_r` are derived from `cur_code_r`. The
compiler namespace and builtins are derived from the builtins dict, except
for the idle-arena premarks above. GC metadata (`[0xF80000, 0x1000000)`, above the RF spill area, and
the free-run headers) is outside the managed heap and is never traced.

With `+GC_ROOT_STASH=1` the streamed roots are also written to
`PYCORE_GC_ROOT_STASH` so the oracle can compare them with the testbench's
own root record. That stash traffic is not part of the pause targets.

## Traversal

One bit in the extent bitmap is one 16-byte granule (`addr >> 4`). The bit
is set when the granule belongs to a live allocation. The static image below
`HEAP_INIT_PTR` is marked and then treated as permanently live by the sweep.
Child slots are those in the plan's §4.1 table, as implemented in
`pycore_gc.sv` and `gc_model.py`:

| Kind | Extent | Children |
| --- | --- | --- |
| LONG_STR | `16 + pad16(nbytes)` | none |
| TUPLE | `size * 32`; size 0 allocates nothing | elements |
| LIST | 32 B object plus `capacity * 32` buffer | elements `0 .. length-1` only |
| DICT | 48 B object, order buffer, table | occupied slots' key and value; empty and tombstone slots skipped |
| SET | 32 B object plus table | occupied slots |
| BYTEARRAY | 128 B object plus raw buffer | buffer is marked, not scanned |
| OBJECT | by `ob_kind` (instance, type, bound method, builtin, exception, cell, function) | the fields listed for that kind; unknown kind is fatal in simulation |
| CODE | 256 B | tuple/dict fields; `entry_slot` and the metadata word are integers |
| RANGE | mode 1 is a 3-element tuple; mode 0 is inline | the tuple |
| ITER | the underlying list, tuple, string, dict, set, or object | per iterator kind; an empty short string has no heap object |

Non-pointers (int, float, bool, short string, control) are not followed.
A wrong extent under-marks and the next reuse corrupts a live object; G4
compares the free set with the oracle, and G5's shadow heap checks every
mutator access.

## Invariants

1. A reachable object is never freed.
2. Every unreachable object is freed at the collection that follows it
   becoming unreachable. The collector is precise and stop-the-world, so
   there is no floating garbage.
3. With `GC_EN=0`, every cycle count matches the G0 baseline.
4. An allocation that does not fit aborts before the first architectural
   commit of that instruction, then the instruction is re-dispatched.
5. The free set and the reachable set are disjoint. The run list is
   well-formed: runs are aligned, non-overlapping, and inside the heap.
6. Storage is zero when it is next allocated. Explicit collection does not
   zero a run it is not handing out. A `_bi_heap_release(mark)` that
   rewinds the bump pointer zeroes `[mark, old pointer)` at the next
   instruction boundary (`S_GC_ALLOC` phase 2 only, no collection), so
   reallocated bytes hold no stale dict or set keys
   (`img_gc_release_zero`). With `GC_EN=0` the release only rewinds, as
   before the collector. The core tracks `heap_zero_r`, one past the
   highest dynamic-heap byte any core write has touched (including STRACC
   pieces written before a NEED_HEAP abort); a run install zeroes up to it,
   and G6 fires if a heap write ever lands above it.
7. Code RAM is not reclaimed. `compile()` can grow code RAM without bound;
   that ceiling is Phase 7 and is out of scope.

## Performance

On-chip storage (1 MB map, where the G13 numbers below were measured):
mark bitmap 480 × 128 = 61,440 bits; run table 1,024 × 64 = 65,536 bits;
mark stack 256 × 67 = 17,152 bits; static prune-map copy 256 × 128 =
32,768 bits; total 176,896 bits (21.6 KB). The bitmap is sized from
`PYCORE_HEAP_LIMIT`: on the 16 MB map it is 7,680 × 128 bits (120 KB),
and the memory mark stack holds 16,384 entries. Both need re-sizing before
the collector is on by default (`planning/master_plan.md`, known bugs). Above the plan's
16 KB guideline: the run table is what brought the `bench_full` sweep from
7,784 to 2,172 cycles (P4), and the prune-map copy and the deeper stack
are what bring `bench_churn` under 25% (P6b): per collection they removed
about 1,500 cycles of static-map reads and 320 spill transactions.

P1 (no-collect fixtures identical to G0) has one revision. A rewinding
`_bi_heap_release` zeroes the bytes it hands back (invariant 6), which is an
`S_GC_ALLOC` visit without a collection: `img_heap_mark_release` 3441 -> 3535
cycles (zeroing 30 cycles, 2 lines), `img_compile_release_realloc` 423,129 ->
426,993 (zeroing 4,888 cycles, 349 lines, about 14 cycles per 64 B line). G13
requires such a fixture to match G0 exactly with the zeroing disabled (mutant
46) and allows the mutator at most G0 + max(0.5%, 64 cycles per zeroed line)
for the cache lines the pass displaces; the zeroing pause itself may take at
most 16 cycles per zeroed line plus 64.

Fixed per-collection work, `bench_churn` (47 collections, before these
changes): idle compiler cleanup 1.5k cycles, static-map preload 2.3k, mark
12.7k, sweep 0.6k, zeroing the next run 10.7k (14 cycles per 64 B line).
The cleanup loop now runs only when something other than the collector
has written `_PYC_G["_busy"]` since the last loop; the image omits the
cleanup descriptor for programs that name `_PYC_G`, so only `compile()`
writes those slots.

G13 targets, from measurements already recorded in this file and in
`planning/gc_progress.md`. A blank cell has not been re-measured on the
current commit.

| ID | Target | Measured |
| --- | --- | --- |
| P1 | no-collect fixtures match G0 cycles | G1 full pass at `c09384c` (cycle-identical with the collector off) |
| P3 | mark port utilisation ≥ 0.80 on `bench_full` | line consume of PLAIN pairs, dict slots, and list/set headers |
| P4 | sweep ≤ 4 cycles/bitmap slot + 6/run | 2172 cycles on `bench_full` (cap 5292) |
| P5 | max pause ≤ 400000 cycles on `bench_full` | 399009 |
| P6a | GC share ≤ 2% on `img_gc_compile_loop` | 910656 / 47506100 = 1.92% (was 1.963% before the cleanup skip and prune-map copy) |
| P6b | GC share ≤ 25% on `bench_churn` | 1080241 / 4464246 = 0.242 (was 0.283: 256-entry stack, on-chip prune-map copy, cleanup skip) |
| P7 | mark-stack spills ≤ 5% of mark transactions | `bench_full` 256 spills / 30,164 transactions with 256 entries (1,024 with 64); 0 on `bench_churn` |
| P8 | ≤ 0.05 run-list pops per allocation over the G8 corpus | 1.43 / 1.17 (measure / shrunk) at 10b2ba8; 0.011 on single-core seeds 0-9 with keep-run and next-fit |

## Testing

| Tier | Command | What | When |
| --- | --- | --- | --- |
| PR | `make test-gc` | engine unit testbench (200 seeded heaps × 6 memory configs, G3) and the `[gc]` area of `hw_tests.toml` (61 programs, each under ~1M cycles) | every PR (CI `gc` area job) |
| Long | `make test-gc-long` | the `[gc-long]` area: steady-state plateaus, allocation-site churn, benches, compile loops | nightly / on demand |
| Fuzz | `make pycore-gc-fuzz SEEDS=0..49 TOP=single` | random programs checked against CPython and the oracle | nightly / on demand |
| Acceptance | `make pycore-gc-acceptance MODE=full` | gates G0-G16 | before a collector design change |

A new PR-tier program must stay under 2M cycles at the default config;
anything longer goes in `[gc-long]`.

## Debugging

Plusargs the gates use:

| Plusarg | Effect |
| --- | --- |
| `+GC_EN=1` | collector on (the RTL default is off). The `gc` and `gc-long` entries in `hw_tests.toml` set it; `make test-hw HW_PLUSARGS=+GC_EN=1` runs every hardware test with it. `+GC_EN=0` is cycle-identical to the pre-GC machine (G1) |
| `+GC_LOG=1` | one `[GC-LOG]` line per collection (live, free, pause, reason) |
| `+GC_SITE_STATS=1` | one `[GC-SITE]` line per allocation site at exit (G9) |
| `+GC_DUMP_EACH=<dir>` | coherent dump after each collection, checked by `gc_model.py` |
| `+GC_ROOT_STASH=1` | write the streamed roots for the oracle |
| `+GC_POISON=1` | poison reclaimed granules so a use-after-free faults (the sweep writes whole aligned 64 B lines in one line write when `CACHE_EN=1`, 16 B words otherwise) |
| `+GC_AT_EXIT=1` | collect once at halt |
| `+GC_EVERY_N_RUNS=1` | collect when a run cannot satisfy the allocation (G7 mode a) |
| `+GC_AT_BOUNDARY_EVERY=K` | collect every K instructions (G7 mode b, G8 measure) |
| `+HEAP_DYN_BYTES=N` | shrink the dynamic heap |
| `+GC_MUTANT=n` | enable mutant n (`tools/gc_mutants.py`); 0 is inert |
| `+MAX_CYCLES_SCALE=k` | raise the cycle cap for a run that collects |

`[GC-SHADOW]` is the shadow-heap checker (G5). `[GC-INV]` is an in-RTL
invariant: a bad object kind, a reserved tag, or an excore grant past
`heap_limit`. A fuzz failure is shrunk (statements deleted while it still
fails) and committed as `img_gc_fuzz_<seed>` before the fix. Mutants are
never deleted; a survivor means the suite is too weak, and the answer is a
new `img_gc_mutant_<n>` fixture.
