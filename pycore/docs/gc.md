# Garbage collection (as built)

Status: built, **off by default** (`+GC_EN=1` turns it on). Acceptance
gates G0-G16 passed on the 1 MB memory map, except G9 (fixed afterwards,
`img_gc_call_varargs`); the record is
[`planning/gc_plan.md`](../../planning/gc_plan.md) and
[`planning/gc_progress.md`](../../planning/gc_progress.md). On `main`'s
16 MB map the gates run from `hw_tests.toml` (Testing, below): `MODE=quick`
(G0-G8) and G10 (every mutant killed) pass, and with the collector off every
existing test is cycle-identical to `main` (G1). It becomes the default
after one `MODE=full` run on the 16 MB map.

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
  full, the engine spills the oldest 32 entries to the 192 KB region at
  `PYCORE_GC_MARK_STACK` (12,288 entries, one 16 B slot each); when a pop
  finds it empty and the memory part is non-empty, it refills 32. The plan's
  provable bound (§4.3, at most 30,686 pending entries on the 1 MB map) does
  not hold on the 16 MB map, and no fixed size can hold every graph, so the
  stack is bounded instead by the two rules in "Bounded marking" below.
- **Why.** Maas (§V-C, §VI-B) keeps a 1,024-entry mark queue on chip and
  spills only when it is full: spilling was about 2 % of memory requests.
  Our draft (§4.5) made every push and pop a dmem transaction, which roughly
  doubles mark traffic. Depth-first marking of typical PyCore heaps stays
  shallow: a linked chain keeps one or two pending entries, and a wide
  container at most 129 (chunked scans). The stack is LIFO, so spilling the
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

#### Bounded marking: chunked scans and the rescan list

A stack sized for the largest graph does not exist, so marking never needs
more than the stack holds:

- **Chunked scans.** One pop scans at most `PYCORE_GC_SCAN_CHUNK` (128)
  slots of a range: a tuple, a list buffer, a set table, a dict order
  buffer or a dict table. Before scanning, the tracer pushes the rest of the
  range, unmarked, as a continuation entry (`K_TUPLE` for 32 B slots, the
  continuation-only `K_DICTT` for 64 B dict slots). Children are pushed on
  top of it and popped first, so a wide container holds at most 129
  entries, and every popped entry scans one range. A dict's order buffer
  and table are two ranges of one pop; the tracer starts the table once no
  order-buffer child can still overflow (fewer than 8 items in flight, or
  all drained).
- **Rescan list.** Only depth can still fill the stack (a 100,000-node
  chain of `(payload, next)` leaves one payload per level). A child that
  does not fit is not marked; the range being scanned (`t_re_r`: the chunk,
  or the whole object for an OBJECT or CODE entry) is written once to the
  rescan list at `PYCORE_GC_RESCAN` (4,096 entries, the top 64 KB of the
  mark-stack region), and later children of that range are dropped. A
  continuation that does not fit is recorded itself. When the stack and
  its memory part are empty, the marker moves the newest recorded range
  back onto the stack. Already-marked children are skipped, and the stack
  is empty when a recorded range is rescanned, so each rescan marks at
  least one new child and marking terminates with the same set an
  unbounded stack marks. A root that does not fit (no range to rescan) is
  marked and recorded itself.
- **Abandoning.** Only a full rescan list abandons the collection
  (`overflow`, `MemoryError`; see "Architecture and interfaces").
  That takes more than 4,096 partly scanned ranges pending at once: a graph
  deeper than the 12,544-entry stack in which most nodes popped while it is
  full have several unmarked pushable children. Wide and deep graphs
  (`img_gc_wide_live_list`, `img_gc_deep_live_chain`) need one or two.

The oracle (`gc_model.trace`) applies the same rules with the engine's
limits, which every dump records (`stack_limit`, `onchip`, `rescan_limit`),
so `objects`, `stack_hw`, `rescans` and an abandoned collection must agree.
G3 runs every eighth seed with a five-entry stack, and its directed cases
check a wide list and a deep chain with tiny stacks and the abandon path.

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
  `heap_dyn_base`. Words above the highest word this collection marked
  (`mark_hi_w_r`) are already zero, so the sweep lists everything above it
  as one run without reading it, and it jumps over a kept run
  (`[keep_lo, keep_hi)`) instead of painting it into the bitmap. On the
  16 MB map a collection with little live data swept 7,680 bitmap words
  (15,000+ cycles with a kept run); it now sweeps 200-600 cycles
  (`cs_control` boundary collections: 15,125 -> 419). There is no separate
  `CLEAR` phase in the pause: after reset (RAM contents are not guaranteed)
  and after an aborted collection the idle engine clears the bitmap in the
  background, one word per cycle (`bg_clr_r`); a collection that starts
  first finishes the clear. `bitmap_clean_r` tracks it.
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
  header miss. `bench_full` sweep is 2172 cycles (P4 cap 5292). The table
  holds 14,272 runs; past that the header goes in place, in the run's first
  granule, so the list has no fixed limit (`img_gc_run_table_overflow`:
  the sweep used to abort there and raise `MemoryError` with most of the
  heap free).

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

A collection the engine abandons (rescan list full, a dmem fault) raises
`MemoryError` and leaves marks in the bitmap, so the next collection clears
the whole bitmap first (`M_CLEAR`, one cycle per word). Without that clear a
stale mark made the marker skip a live object that was pushed but never
scanned, and the sweep freed its children (`img_gc_mark_overflow_recover`,
caught by the shadow-heap checker). The fixture now reaches the abandon
path with a 64-entry stack and a 64-entry rescan list (`+GC_ONCHIP`,
`+GC_STACK_LIMIT`, `+GC_RESCAN_LIMIT`).

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
The static prune map (`PYCORE_GC_STATIC_MAP`, 8 KB) has one bit per granule
of the first 1 MB. Static objects above that are not pruned but traced each
collection: the run table follows the map, and map words written past it
were overwritten by run headers and read back as premarks.
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

Ranges longer than 128 slots are scanned in chunks ("Bounded marking").
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

On-chip storage on the 1 MB map:
mark bitmap 480 × 128 = 61,440 bits; run table 1,024 × 64 = 65,536 bits;
mark stack 256 × 67 = 17,152 bits; static prune-map copy 256 × 128 =
32,768 bits; total 176,896 bits (21.6 KB). The bitmap is sized from
`PYCORE_HEAP_LIMIT`: on the 16 MB map it is 7,680 × 128 bits (120 KB),
and the memory mark stack holds 12,288 entries beside a 4,096-entry rescan
list. A wide live list no longer overflows the stack (chunked scans:
`img_gc_wide_live_list`, 18,000 tuples, stack high-water 130), and a
100,000-node chain marks with seven rescans (`img_gc_deep_live_chain`,
high-water 12,544). Above the plan's
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

G13 targets, re-measured on the 16 MB map at CACHE_EN=1 MEM_LATENCY=4
(`make pycore-gc-bench`; P1/P2 from G13's run of every existing single-core
image test with `+GC_EN=1`; P8 over 50 single-core `pycore-gc-fuzz` seeds).
The 1 MB-map value, where it differs, is in brackets. Since that measurement
the map grew 16x (the sweep covers 7,680 bitmap words instead of 480) and
`main` began modelling an 8-cycle L2 hit; which of the two moved P5 and P6b
has not been isolated.

| ID | Target | Measured (16 MB map) | |
| --- | --- | --- | --- |
| P1 | no-collect tests match G0 cycles | 359 of 359 existing image tests run without a collection; 357 cycle-identical to `main`, the two release-zeroing tests within the revised bound (`heap-mark-release` 5610 vs G0 5468, zeroing 30 cycles over 2 lines; `compile-release-realloc` 781,887 vs 779,159, zeroing 5,056 over 361 lines) and identical with mutant 46. G1: all 372 single-core tests identical with `GC_EN=0` | met |
| P2 | a collecting existing test adds only its pause (+0.5%) | no existing test collects at the default heap | — |
| P3 | mark port utilisation ≥ 0.80 on `bench_full` | 0.970 | met |
| P4 | sweep ≤ 4 cycles/bitmap word + 6/run | 9,430 cycles on `bench_full` (cap 4 × 7,680 + 6 × 562 = 34,092) [2,172, cap 5,292] | met |
| P5 | max pause ≤ 400,000 cycles on `bench_full` | **560,333** [399,009] | missed |
| P6a | GC share ≤ 2% on `img_gc_compile_loop` | 1,077,132 / 83,824,420 = 1.28% [1.92%] | met |
| P6b | GC share ≤ 25% on `bench_churn` | **1,734,345 / 6,694,230 = 25.9%** [24.2%] | missed |
| P7 | mark-stack spills ≤ 5% of mark transactions | `bench_full` 256 / 29,181 = 0.9%; `bench_deep` 0 / 40,331 | met |
| P8 | ≤ 0.05 run-list pops per allocation over the G8 corpus | 1,493 / 102,431 = 0.0146 | met |

Other counters (`bench_*`, two collections each unless noted): `bench_full`
mark 1,050,932 cycles; `bench_deep` max pause 426,538; `bench_wide` max pause
968,978, 31,104 spills / 79,437 mark transactions (a wide live list,
expected to spill); `bench_churn` 47 collections, max pause 51,712.
P5 and P6b are open (`planning/master_plan.md`, GC sizing); `MODE=full`
fails G13 until they are met or the targets are revised for the 16 MB map.

## Clock and timing

`tools/gc_timing.sh` estimates the engine's logic depth: sv2v, the mark
bitmap and mark-stack ring shrunk to 16 entries (the run table, 1,024
entries, and the prune-map copy, 256, stay full size), Yosys + ABC mapped to
the SkyWater sky130 hd library (typical corner, no wire load). One sky130
FO4 is 80.5 ps.

| Path | Delay | FO4 |
| --- | --- | --- |
| Worst register-to-register logic path, before the sweep-step fix | 9.02 ns | 112 |
| Same, now (sweep: `sw_g_r` compares and adds into the run-emit write enables) | 7.23 ns | 90 |
| Read mux of a 256 / 1,024 / 7,680-word flop array | 1.03 / 1.26 / 1.88 ns | 13 / 16 / 23 |

Adding ~0.4 ns of flop overhead and ~25% for wires puts the engine at about
9.5 ns, **roughly 100 MHz in sky130 at the typical corner** (less at the slow
corner), for the logic alone.

On an FPGA the deep single-cycle paths cost far more. With every array at 16
entries (bitmap, ring, run table and prune-map copy), `synth_ecp5` needs
55,272 LUT4 and 10,186 flops, 71% of the logic of the largest ECP5 (LFE5U-85),
and nextpnr's post-placement estimate is **11.3 MHz** (worst slack about
-68 ns at a 50 MHz target; routing did not converge in an hour and was
stopped). An FPGA prototype of the collector needs the sweep and marker
paths pipelined before it is worth benchmarking at a useful clock.

The arrays are the real limit:

- The mark bitmap is 7,680 x 128 bits on the 16 MB map and is read
  combinationally in up to four places in one cycle (marker test, marker
  set, sweep scan, kept-run update before this revision). Built from flops
  it would be about 20 mm2 of sky130. As SRAM it needs a registered read
  port, so the marker's test-and-set becomes read-then-write (one extra cycle
  per marked object, about 1% of a mark-bound pause) and the sweep reads the
  next word a cycle ahead. The run table (1,024 x 64 bits, read
  combinationally by the core's allocator through `run_peek`), the prune-map
  copy and the mark-stack ring have the same property.

### A separate clock

Marking is memory-bound: the dmem port is busy 84-97% of the mark phase
(blocking L1D/L2, one outstanding request). The part of a pause that the
engine's own clock speeds up is small:

| Benchmark | Live | Mark cycles | Port busy | Engine-only (mark + sweep) |
| --- | --- | --- | --- | --- |
| `bench_full` | 502 KB | 511,616 | 496,108 | 17,661 (3.4%) |
| `bench_deep` | 320 KB | 381,349 | 321,108 | 60,596 (15.9%) |
| `bench_wide` | 512 KB | 912,995 | 867,366 | 46,081 (5.0%) |
| `bench_churn` | 30 KB | 23,645 | 22,356 | 1,934 (8.0%) |

So the engine belongs on the memory hierarchy's clock, or a synchronous
integer ratio of it. A faster asynchronous GC clock would save at most the
engine-only share and pay a synchronizer on every dmem transaction (two or
three cycles on ~20-60-cycle transactions). Its interfaces to the core are
the dmem port, the root stream, the start/done handshake and `run_peek` (the
core reads the on-chip run table combinationally in `S_GC_ALLOC`); a clock
crossing would need the last moved to the core side or behind a handshake.
For benchmarking at a clock `f` with memory latency in core cycles:
pause ~= port-busy cycles / f_mem + engine-only cycles / f_gc.

## Testing

| Tier | Command | What | When |
| --- | --- | --- | --- |
| PR | `make test-gc` | engine unit testbench (200 seeded heaps × 6 memory configs, G3) and the `[gc]` area of `hw_tests.toml` (64 programs) | every PR (CI `gc` area job) |
| Long | `make test-gc-long` | the `[gc-long]` area: steady-state plateaus, allocation-site churn, benches, compile loops | nightly (`.github/workflows/gc-nightly.yml`) / on demand |
| Compiler | `make test-compiler-gc` | the compile suite with the collector on and a 512 KB heap: 3-7 collections per program, several inside `compile()`; output must match CPython | nightly / on demand |
| Fuzz | `make pycore-gc-fuzz SEEDS=0..49 TOP=single` | random programs checked against CPython and the oracle | nightly, both tops / on demand |
| Acceptance | `make pycore-gc-acceptance MODE=quick` | gates G0-G8 | before merging a collector change |
| Acceptance | `make pycore-gc-acceptance MODE=full` | gates G0-G16 | before a collector design change or turning it on by default |
| Mutants | `make pycore-gc-mutants [MUTANTS=1,5]` | the quick gates against each of the 49 mutants (G10) | after a change to the gates or the RTL they cover |

A new PR-tier program must stay under 2M cycles at the default config;
anything longer goes in `[gc-long]`. The exception is `gc-wide-live-list`
(6.7M cycles, almost all of it building a list wider than the mark stack),
kept per PR because it guards the bounded-marking rules. A known bug is
marked `xfail = "<why>"` in `hw_tests.toml`: the run must fail, and the
suite fails if it passes, so the marker comes off with the fix.

The steady-state programs (`img_gc_steady_*`) check themselves, like
`img_gc_leak_check`: live bytes from `_bi_gc_collect()` after a warm-up and
again at the end; any growth returns minus the growth instead of the
checksum.

### Gates

`tools/gc_acceptance.py` runs the gates in order and writes
`build/gc_acceptance/status.json` and `report.md`; `tools/gc_gates.py` holds
them. A gate that runs hardware tests takes its test set and plusargs from a
`[gate.*]` table at the end of `pycore/programs/hw_tests.toml` and runs it
through `hw_tests.py`, one log per run under
`build/gc_acceptance/runs/<gate>/<test>/` (dumps beside it).
`python3.14 pycore/tools/hw_tests.py --gate G4 [--mode full]` runs one set by
hand, without the checks.

| Gate | Runs | Passes when |
| --- | --- | --- |
| G0 | — | `pycore/tests/data/gc_baseline_cycles.tsv` covers every test and config `main` ran at its commit |
| G1 | baseline tests, `+GC_EN=0` (quick: single-core, default config; full: every test-hw and test-caching config) | every result and cycle count equals G0 |
| G2 | `pycore/tests/test_gc_model.py` | the oracle agrees with Python reachability |
| G3 | `make pycore-gc` | 200 seeds × 6 configs exact |
| G4 | `[gc]` + `gc-mutant-*` (full: + `[gc-long]`, CACHE_EN 0 and 1, and every existing image test with `+GC_AT_EXIT=1`), `+GC_DUMP_EACH` | every dump equals `gc_model.py` |
| G5, G6 | the shadow self-test; every GC log so far | the self-test fires; no `[GC-SHADOW]` or `[GC-INV]` |
| G7 | as G4, `+GC_EVERY_N_RUNS=1` in a 2.5×-peak heap (full: also `+GC_AT_BOUNDARY_EVERY=K` and poison) | goldens hold, dumps exact |
| G8 | `gc_fuzz.py`, 50 seeds single-core (full: 1000 per top) | no failure; every kind and site covered |
| G9-G16 | full only: site coverage, mutants, steady state, every memory config, P1-P8, `test-all` and warnings, review, docs/CI | see `planning/gc_plan.md` §10.2 |

`make pycore-gc-baseline` regenerates G0 from a worktree of `main`
(`tools/gc_baseline.py`: `main`'s own `hw_tests.py` under the test-hw and
test-caching configs, plus its Verilator warnings and host steps).

The on-device compiler is the largest Python program the hart runs, so the
compile suite doubles as a collector test. `--plusargs` passes simulator
plusargs through `pycore_cli.py run` and `compile_suite.py`; with `+GC_EN=1`
the exec harness also calls `_bi_gc_collect()` before compile, after compile
and after the run, and the report gives exact live bytes (what `compile()`
kept), the number of collections and the longest pause:

```bash
python3.14 pycore/tools/compile_suite.py --jobs 4 --plusargs "+GC_EN=1 +HEAP_DYN_BYTES=524288"
python3.14 pycore/tools/pycore_cli.py run FILE.py --plusargs "+GC_EN=1 +GC_PHASE_PROF=1"
```

A small `+HEAP_DYN_BYTES` makes the collector run inside every compile.
`compile()` keeps only its code object (2-10 KB per suite program); its
working set is reclaimed. The peak live set during a compile (tokens plus
AST at the end of parsing, about 190 KB for the 65-line `cs_control`) is the
smallest heap a file compiles in.

## Debugging

Plusargs the gates use (give any of them to a test with
`hw_tests.py --plusargs`, e.g. `--plusargs "+GC_LOG=1"`):

| Plusarg | Effect |
| --- | --- |
| `+GC_EN=1` | collector on (the RTL default is off). The `gc` and `gc-long` entries in `hw_tests.toml` set it; `make test-hw HW_PLUSARGS=+GC_EN=1` runs every hardware test with it. `+GC_EN=0` is cycle-identical to the pre-GC machine (G1) |
| `+GC_LOG=1` | one `[GC-LOG]` line per collection (live, free, pause, reason) |
| `+GC_SITE_STATS=1` | one `[GC-SITE]` line per allocation site at exit (G9) |
| `+GC_DUMP_EACH=<dir>` | coherent dump after each collection, checked by `gc_model.py` |
| `+GC_ROOT_STASH=1` | write the streamed roots for the oracle |
| `+GC_PHASE_PROF=1` | one `[GC-PHASE]` line per collection: cycles in each engine phase (clear, cleanup, preload, roots, mark, sweep), objects, mark transactions |
| `+GC_POISON=1` | poison reclaimed granules so a use-after-free faults (the sweep writes whole aligned 64 B lines in one line write when `CACHE_EN=1`, 16 B words otherwise) |
| `+GC_AT_EXIT=1` | collect once at halt |
| `+GC_EVERY_N_RUNS=1` | collect when a run cannot satisfy the allocation (G7 mode a) |
| `+GC_AT_BOUNDARY_EVERY=K` | collect every K instructions (G7 mode b, G8 measure) |
| `+HEAP_DYN_BYTES=N` | shrink the dynamic heap |
| `+GC_MUTANT=n` | enable mutant n (`make pycore-gc-mutants`); 0 is inert |
| `+MAX_CYCLES_SCALE=k` | raise the cycle cap for a run that collects |

`[GC-SHADOW]` is the shadow-heap checker (G5). `[GC-INV]` is an in-RTL
invariant: a bad object kind, a reserved tag, or an excore grant past
`heap_limit`. A fuzz failure is shrunk (statements deleted while it still
fails) and committed as `img_gc_fuzz_<seed>` before the fix. Mutants are
never deleted; a survivor means the suite is too weak, and the answer is a
new `img_gc_mutant_<n>` fixture.
