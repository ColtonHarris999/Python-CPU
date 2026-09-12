# Memory system plan — L1I / L1D / L2 / RAM, strings in dmem, descriptor caches

Implementation plan for the "Neumann on the outside, modified Harvard on the
inside" memory system. Sizing and priority come from the measurements in
[`memory_hierarchy_report.md`](memory_hierarchy_report.md); the harness that
produced them is [`pycore/tools/memsim/`](../pycore/tools/memsim/README.md) and
is re-run as the acceptance gate in P9.

**In scope:** L1I, L1D, unified L2, a parameterized RAM model, moving string
bytes out of `pycore_string_mem.sv` into ordinary dmem behind a dedicated
String Accelerator,
the code-object descriptor cache, the global-name inline cache, and the frame
top-of-stack buffer.

**Explicitly out of scope:** the constant cache (measured weakest of the four —
report F6); storage / block device; any change to the ISA, the tag map, or the
object layout; growing the object heap past `PYCORE_HEAP_LIMIT`.

---

## 0. The one contract everything rests on

`pycore_mem_bank.sv` today accepts a request combinationally and returns
`ack_o` (with `rdata_o`, `fault_o`) exactly one cycle later. Every master
already **waits for `ack` rather than assuming a fixed latency**:

| Master | Wait mechanism | File |
| --- | --- | --- |
| fetch | `awaiting_r` holds until `imem_ack_i` | `pycore_fetch.sv` |
| MEM stage | `req_sent_r && dmem_ack_i` | `pycore_mem_stage.sv` |
| container FSM | `container_dmem_pending_r` cleared on `dmem_ack_i` | `pycore_core.sv:2343` |
| CALL / RETURN | `frame_dmem_pending_r` | `pycore_call_fsm.svh` |
| exc stack | `dmem_req_r && dmem_ack_i` | `pycore_exc_stack.sv:135` |
| excore | `sp_ack` through the grant mux | `pycore_excore_system.sv:309` |

**Therefore caches drop in underneath the existing port with no core changes**,
provided they preserve this contract:

> A request is captured on the cycle `req_i` is high (the master need not hold
> it). `ack_o` pulses for exactly one cycle when the response is ready, any
> number of cycles later. `fault_o` accompanies `ack_o`. At most one request is
> outstanding per master port.

Do not change this. If any phase needs to change it, stop and re-plan — it is
the reason this work can be staged behind a green regression at every step.

The one addition in P0 is a byte-enable, which the String Accelerator needs
for unaligned payload writes.

---

## 1. Target configuration

All of these become named localparams in `pycore_defs.svh` (see P0).

| Level | Size | Line | Ways | Sets | Policy | Hit latency |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| **L1I** | 8 KB | 64 B | 4 | 32 | read-only; line-granular refill | 1 cyc |
| **L1D** | 8 KB | 64 B | 4 | 32 | write-back, write-allocate, LRU | 1 cyc |
| **L2** | 128 KB | 64 B | 8 | 256 | unified, write-back, **inclusive** | 8 cyc |
| **RAM** | 16 MB | — | — | — | behavioral, parameterized latency + burst | `RAM_T_FIRST` |

Structure caches (result caches, not line caches):

| Structure | Entries | Ways | Key | Payload |
| --- | ---: | ---: | --- | --- |
| **CODC** code-object descriptor | 4 | 2 | code object base addr `[31:0]` | `entry_slot[63:0]`, `co_consts[127:0]`, `co_names[127:0]`, `metadata[127:0]`, `co_defaults[127:0]` — 576 b |
| **GIC** global-name inline cache | 16 | 2 | `{code_addr[31:0], namei[15:0]}` | resolved `{tag[3:0], val[127:0]}` — 132 b |
| **FTB** frame top-of-stack buffer | 4 frames | — | stack depth | 2 × 128 b per frame |

### Why these sizes

* **L1I 8 KB / 4-way.** Report F1 measures 4 KB/64 B/4-way at 99.96% on the
  current program set. 8 KB is the conservative ship: the ROM firmware builtins
  and the future on-device compiler are both far larger than these fixtures.
  Note that when the compiler stops emitting `CACHE`, the *dynamic* slot count
  drops from 1.37 per opcode to near zero and the L1I working set shrinks ~3.5×
  — so 8 KB is right before and after that change, and must not be sized
  against today's inflated slot stream.
* **L1D 8 KB / 4-way.** F2 shows the metadata working set is only 143 lines and
  2 KB/2-way already hits 99.4%. But that number excludes heap traffic, which
  is up to **96%** of accesses in `bench_sort` (F5), and excludes the string
  bytes that P5 relocates into dmem. 8 KB/4-way covers both. 4-way is not
  optional: F2 measures 2 KB direct-mapped at 89.1% against 99.4% at 2-way,
  because the object layout is stride-regular.
* **64 B line everywhere.** F3: a dict slot is exactly 64 B
  (`kval`,`ktag`,`vval`,`vtag`), a tuple element 32 B, a code object 8 × 32 B.
  Line sweep at 512 B/2-way: 16 B → 64.9%, 32 B → 70.6%, 64 B → 76.0%. 128 B
  buys 0.13 points at 2 KB and costs fill bandwidth.
* **L2 128 KB / 8-way, inclusive.** Covers the whole present dmem footprint, so
  the excore handoff never has to reach RAM. Inclusive because it makes the
  handoff protocol in §4 a two-signal affair instead of a coherence problem.
* **CODC 4 entries.** F6 measures 4 entries/2-way at **98.6%**; 16 entries/4-way
  reaches 98.8%. Four is the knee. `PYCORE_CODC_ENTRIES` is a parameter —
  widen only if a future workload shows otherwise, because each entry is 576 b
  of flops.
* **GIC 16 entries.** F6: 8/1-way = 98.5%, 16/2-way = 99.0%, no gain past that.

---

## 2. Memory map

**Keep every existing address through P4.** The heap, exception arena and
frame stack constants are mirrored between `pycore_defs.svh` and
`pycore/tools/encoding.py` and are referenced by ~300 host tests plus
`excore/tb/tb_excore.sv` (which hardcodes `BLOCK_SHIFT(17)` to span
`PYCORE_HEAP_LIMIT`). P0–P4 do not move any of them, so no phase before P5
carries that regression risk.

P5 does move them, deliberately: strings become heap objects and the heap has
to grow. By then the P0 constant mirror and the P1 placement mirror both exist
to guard the move. The post-P5 map is in the P5 section.

```
0x0000_0000 – 0x0000_03DF   reserved
0x0000_03E0 – 0x0000_043F   boot record (96 B)                     unchanged
0x0000_0440 – 0x0001_AFFF   object heap (bump allocator, ~106 KB)  unchanged
0x0001_B000 – 0x0001_BFFF   exception-info arena (4 KB)            unchanged
0x0001_C000 – 0x0001_FFFF   call-frame stack (16 KB)               unchanged
0x0002_0000 – 0x00FF_FFFF   unallocated (P5 grows the heap into this)
0x0100_0000 – …             CODE address space (slot-indexed, unchanged split)
```

`DATA_LIMIT` in `pycore_ram.sv` is the current 128 KB dmem through P4, so an
access past `0x0002_0000` still faults. P5 widens it to 1 MB.

> **Invariant, restated for P5.** Today `encoding.py::StringHeapBuilder`
> interns identical byte sequences and LONG_STR equality compares
> `{size, addr}` descriptors *only*, so two LONG_STR handles are equal iff they
> name the same interned payload. That is correct only for compile-time
> constants — a runtime-built string that equals an interned one compares
> unequal and hashes differently, so `d[a + b]` silently misses.
>
> P5 replaces descriptor equality with a content hash carried in the handle
> plus a three-tier compare (identical address → equal; differing
> `(hash, nbytes, nchars)` → unequal; otherwise an accelerator content
> compare). Interning survives as the tier-1 fast path, not as a correctness
> requirement. Until P5c lands, **do not weaken interning** — the current
> semantics still depend on it. Details in
> [`string_accelerator_plan.md`](string_accelerator_plan.md) §3.4.

---

## 3. Module inventory

**New RTL** (`pycore/rtl/`)

| File | Role |
| --- | --- |
| `pycore_cache.sv` | Generic set-associative cache. Parameterized `SIZE_BYTES`, `LINE_BYTES`, `WAYS`, `READ_ONLY`, `WRITE_BACK`. Used for L1I, L1D and L2. One module, three instantiations. |
| `pycore_cache_lru.sv` | Pseudo-LRU victim select, split out so it is unit-testable. |
| `pycore_ram.sv` | Behavioral RAM: `RAM_BYTES`, `RAM_T_FIRST`, `RAM_T_BEAT`, line-granular fill/writeback, 4 × 128 b beats per 64 B line. |
| `pycore_mem_xbar.sv` | Routes L1I / L1D / excore onto the L2, and the L2 onto RAM. Owns the flush/invalidate sequencer of §4. |
| `pycore_str_accel.sv` | **String Accelerator.** Replaces `pycore_string_mem.sv`. Own dmem master port so it is verifiable standalone; entered from the core's new `S_STRACC` state. |
| `pycore_codc.sv` | Code-object descriptor cache. |
| `pycore_gic.sv` | Global-name inline cache. |
| `pycore_frame_buf.sv` | Frame top-of-stack buffer (gated — see P8). |

**Changed**

| File | Change |
| --- | --- |
| `pycore_defs.svh` | All new localparams; `wstrb` width; STR object/handle layout and STRACC op encodings; `PYCORE_CACHE_EN`. |
| `pycore_mem_bank.sv`, `pycore_dmem.sv`, `pycore_code_ram.sv`, `pycore_imem.sv` | Add `wstrb_i`; otherwise unchanged (they become the RAM-side backing store or are replaced by `pycore_ram.sv` — see P2). |
| `pycore_mem_stage.sv`, `pycore_exc_stack.sv` | Tie `wstrb_o` to all-ones. |
| `pycore_fetch.sv` | P4b: 64 B line buffer, `CACHE`/`EXTENDED_ARG` folded inside it. |
| `pycore_core.sv` | CODC/GIC/FTB lookups; `heap_ptr_r` 64 B alignment; string-unit port swap; `gic_valid_r` flush points. |
| `pycore_call_fsm.svh` | CODC hit path around phases 3–6 and RETURN phases 1–2. |
| `pycore_cont_object.svh` | GIC hit path in `CONT_LOAD_GLOBAL`; GIC invalidate in `CONT_STORE_NAME`. |
| `pycore_cont_str.svh`, `pycore_cont_list.svh` | String window reads become `str_win_valid` handshakes. |
| `pycore_system.sv`, `pycore_excore_system.sv` | Instantiate the hierarchy; wire the handoff flush. |
| `pycore/tools/encoding.py`, `heap_image.py`, `image_from_source.py` | 64 B allocator alignment; `StringHeapBuilder` replaced by `HeapImageBuilder.alloc_str` emitting STR objects into the object heap. |
| `Makefile` | New TB targets; `PYCORE_MEM_SRCS` gains the cache sources. |

**Deleted**

* `pycore/rtl/pycore_string_mem.sv`
* `pycore/tb/tb_string_exec.sv` → replaced by `tb_str_accel.sv`
* the `--string-hex` / `STRING_HEX` plusarg path and `pycore/programs/string_mem.hex` (P5)
* `pycore_firmware/builtins/str_{find,join,startswith,endswith}.py` (P5f)

---

## 4. Coherence and invalidation

The system is **not** cache-coherent and does not need to be. There is exactly
one sharing event and it is coarse.

### excore handoff

`pycore_excore_system.sv` hands the dmem bank over with a registered
`mem_owner_r` grant (`:278`–`:311`), never cycle-level arbitration: pycore is
frozen in `S_TRAP_MARSHAL` / `S_TRAP_WAIT` for the whole excore window, and a
`$fatal` already checks that the non-owner never raises `req`. So:

1. **excore attaches at the L2**, not at RAM and not at the L1D.
2. On `trap_req_valid && trap_req_ready`: **write back and invalidate L1D**
   before `mem_owner_r` flips. The mux must not grant excore until the flush
   sequencer reports done. Add a `flush_done` gate on the grant transition.
3. On `trap_res_valid && trap_res_ready`: **invalidate L1D** (no writeback —
   pycore made no writes while frozen) before granting pycore.
4. Also on step 3: **flush CODC and GIC**. excore resizes and rehashes
   dicts — `PY_TRAP_DICT_GROW`, `PY_TRAP_SET_GROW`, dict update/merge — which
   moves the exact table slots the GIC memoised. Relocating list/dict grow also
   moves buffers the L1D may hold; step 2/3 covers that.
5. L1I needs nothing: excore never writes the code region.

### Full invalidation matrix

| Event | L1I | L1D | L2 | CODC | GIC | FTB |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| `trap_req` (grant to excore) | — | wb+inv | — | — | — | flush |
| `trap_res` (grant back) | — | inv | — | flush | flush | — |
| code-RAM write (future writers) | inv | — | — | flush | — | — |
| `MAKE_FUNCTION` / code release | — | — | — | flush | — | — |
| `STORE_NAME` / `STORE_GLOBAL` | — | — | — | — | flush | — |
| `globals_base_r` change (`_bi_exec_globals`) | — | — | — | — | flush | — |
| reset / boot | inv | inv | inv | flush | flush | flush |

**GIC validity is a whole-cache flush, deliberately.** The dict header already
carries a `version` field, and the "right" key is
`(code, namei, globals_base, version)` — but reading the current version is
itself a dmem access, which defeats the purpose. A blunt flush measures at
**27 flushes across 64,065 opcodes** (report F6), so it costs nothing today.
If generated code later makes `STORE_GLOBAL` hot, add a `globals_version_r`
shadow register in the core (loaded at boot, bumped on every insert the core
performs, reloaded on `globals_base_r` change) and compare against that. Do not
build the version path first.

**A GIC miss must never be cached.** A name absent from both globals and
builtins raises `PY_TRAP_MEM_FAULT`. Only fill on a successful resolve.

---

## 5. Phases

Every phase ends with the **full regression green**. Do not stack phases.

### P0 — Groundwork and contracts

* Add `wstrb_i[15:0]` to the dmem port chain (`pycore_mem_bank`, `pycore_dmem`,
  `pycore_mem_stage`, `pycore_exc_stack`, the container FSM's dmem pulse
  registers). Existing masters drive all-ones. `pycore_mem_block.sv` gains
  per-byte write enables.
* Add `PYCORE_CACHE_EN` (default 1). When 0, every cache instantiated in this
  plan is a straight pass-through to the next level. **This is the bisect
  switch and the transparency test's control arm — build it first and keep it
  working in every later phase.**
* Add performance counters (hit/miss/writeback per level, exposed as module
  outputs that testbenches can read; no MMIO needed yet).
* Add a host test asserting `encoding.py` and `pycore_defs.svh` agree on every
  shared memory-map constant. This mirror is already a live hazard
  (`encoding.py:76` hardcodes `0x1B000`); P1 and P5 both touch it.

**Done when:** `make pycore-python-tests pycore-rtl-unit pycore-img` green with
`PYCORE_CACHE_EN` at both 0 and 1.

### P1 — 64-byte heap alignment (report F3b)

Round every bump allocation up to `PYCORE_LINE_BYTES` in **both** allocators:

* `pycore/tools/heap_image.py::HeapImageBuilder._alloc` (image build)
* `heap_ptr_r` in `pycore_core.sv` (runtime)

These must agree exactly or `HEAP_INIT_PTR` handoff diverges between the image
and the hardware. Measured payoff: L1D misses −45% at 1 KB, −36% at 512 B; it
saturates by 2 KB, so the value is a **smaller L1D for the same hit rate**,
which is why it lands before the L1D is built rather than after.

Costs a few hundred bytes of heap fragmentation. `allocator_list.py` and
`list_oom.py` probe `HEAP_LIMIT - HEAP_INIT_PTR` and will shift — re-derive,
do not hand-patch.

**Done when:** full regression green; `memsim` E8 re-run shows the aligned row.

### P2 — RAM and L2

* `pycore_ram.sv`: 16 MB backing array, `RAM_T_FIRST` (default 30, **CI default
  4** via plusarg so the suite stays fast), `RAM_T_BEAT` 2, 4 beats per line.
  A `+MEM_LATENCY=` plusarg sweeps it — this is what reproduces report E7 in
  real RTL.
* `pycore_cache.sv` instantiated once as the unified L2, sitting between the
  existing `pycore_dmem` / `pycore_code_mem` ports and `pycore_ram.sv`.
* `pycore_mem_xbar.sv` routes the imem and dmem masters onto the L2.

L1s do not exist yet; both masters go straight to L2. This proves the cache
module and the variable-latency contract in isolation.

**Done when:** full regression green at `MEM_LATENCY` of 1, 4 and 30, with
byte-identical retired results at all three.

### P3 — L1D and the excore handoff

* Instantiate `pycore_cache.sv` as the 8 KB/64 B/4-way write-back L1D on the
  dmem path.
* Build the flush/invalidate sequencer in `pycore_mem_xbar.sv` and gate the
  `mem_owner_r` transition on it (§4 steps 1–3).
* Attach excore's `sp_*` port at the L2.

**Done when:** `make pycore-excore-system` and `make pycore-img-two-core` green,
plus a new directed test that dirties a list buffer in L1D, takes a
`PY_TRAP_LIST_GROW`, and checks excore observes the written-back data.

### P4 — L1I, then the fetch line buffer

**P4a (drop-in).** Instantiate the 8 KB/64 B/4-way read-only L1I on the code
path. `pycore_fetch.sv` is unchanged; per-instruction fetch drops from 3 cycles
to 2, and each skipped `CACHE` slot from 2 extra cycles to 1.

**P4b (the actual win).** Give the L1I a 512-bit line read port and add a 64 B
line register to `pycore_fetch.sv`: 8 × 64-bit slots plus a line tag and valid
bit. When the PC's line matches, deliver the slot from the register with **no
memory access at all**, and do the `CACHE` skip and `EXTENDED_ARG` fold inside
the buffer. On branch redirect, check the buffer tag before requesting — loop
bodies usually stay in-line.

This is what attacks report F1's 21.8%. It is also the change that survives the
compiler dropping `CACHE`: the same buffer then just delivers more real
instructions per line.

> **Do not break the PC↔slot invariant.** imem slot index equals CPython
> code-unit index, and `image_from_source.py` relies on that to skip branch-arg
> remapping. The architectural PC stays in wordcode units; compaction happens
> *inside* the line register only.

**Done when:** full regression green, and the fetch-cycle counter shows the
predicted drop on `bench_fib`.

### P5 — String Accelerator, and strings as ordinary heap objects

**Superseded design.** P5 was originally "relocate the bytes, keep a copy
engine". It is now a dedicated accelerator inside pycore, alongside the
container FSM, that owns every non-trivial string operation — and strings
become ordinary dmem heap objects with a self-describing header.

Full design, including the 47-method coverage matrix, the new object and
handle layout, the standalone verification plan and the phase gates:
**[`string_accelerator_plan.md`](string_accelerator_plan.md)**.

Why the change: `pycore_string_mem.sv` is a 64 KB private byte array with
combinational whole-string concat and slice, and everything past
`join`/`startswith`/`endswith`/`find` is firmware Python at roughly 250 cycles
per haystack position. A copy engine would have preserved that. The
accelerator replaces it, and along the way closes a real semantic hole:
LONG_STR equality and hashing today use the `{size, addr}` descriptor and are
correct only because every constant is interned, so `d[a + b]` silently misses
for a runtime-built key.

Sub-phases (each ends with the full regression green):

| | | Gate |
| --- | --- | --- |
| **P5a** | `pycore_str_accel.sv` + `tb_str_accel.sv` + a CPython 3.14 differential harness. Not wired into the core. | The differential passes over the full corpus for COPY, COMPARE, SEARCH, CHAR_AT, ITER_NEXT, HASH |
| **P5b** | New STR object + handle in the image tools and RTL helpers; memory map grows (below). Host-side only. | Host tests green; the Python model reads image-built objects |
| **P5c** | Cutover: core adopts the handle, gains `S_STRACC`, `pycore_string_mem.sv` deleted, write-full-line path added to `pycore_cache.sv` | Every existing string fixture green at `CACHE_EN` 0 and 1 |
| **P5d** | Container integration: three-tier string equality, `CONTAINS_OP`, `sorted`/`min`/`max`, `FOR_ITER`, `join`/`split` over LIST | `img_str_dict_key_runtime` passes (it fails on today's main) |
| **P5e** | The 47 methods in four batches, each with fixtures and a differential sweep | Per-batch fixtures green |
| **P5f** | Retire the firmware string builtins and reclaim their ROM slots | ROM size report |

**Memory map (changed from §2).** Strings become heap objects, so the
dedicated string regions in §2 are **not built**. Instead the data region grows
and the exception/frame stacks move up — the move §2 deliberately deferred,
taken now because `DATA_LIMIT` has to widen anyway and the P0 constant mirror
plus the P1 placement mirror now guard it:

```
0x0000_0440 – 0x000E_FFFF   object heap (~955 KB)          grows
0x000F_0000 – 0x000F_0FFF   exception-info arena (4 KB)     moves
0x000F_1000 – 0x000F_8FFF   call-frame stack (32 KB)        moves, 1024 frames
0x0010_0000                 DATA_LIMIT                      widened from 128 KB
```

`excore/tb/tb_excore.sv`'s hand-written `BLOCK_SHIFT(17)` sizes its bank to
span `PYCORE_HEAP_LIMIT` and must move with it.

**New dmem master.** STRACC drives the dmem port only while the core is frozen
in `S_STRACC`, so the §4 invalidation matrix is unchanged — but assert that
`cmd_valid` never overlaps an excore-owned memory window.

### P6 — Code-object descriptor cache

`pycore_codc.sv`, 4 entries / 2-way, keyed on the code object base address.

* **Lookup** in `S_CALL` phase 2 (`pycore_call_fsm.svh:82`). On a hit, skip
  phases 3–6 entirely — all five field reads — and proceed to phase 14 / 7 with
  the cached `call_entry_slot_r`, `call_consts_r`, `call_names_r`, the unpacked
  metadata, and the defaults handle. On a miss, run the existing phases and
  fill from the values they already latch.
* **Also serve `S_RETURN`** phases 1–2 (`pycore_call_fsm.svh:3926`), which
  re-read the caller's `co_consts` and `co_names`.
* Invalidate per §4.

Measured: 98.6% hit, removes 5 dependent reads per `CALL` and 2 per `RETURN`.

**Done when:** full regression green; `make pycore-frame-fib` and
`img_deep_callgraph` show the predicted cycle drop; a directed test proves a
stale entry is flushed on code release (`img_code_release_stale_trap` is the
existing hook).

### P7 — Global-name inline cache

`pycore_gic.sv`, 16 entries / 2-way, keyed on `{code_addr, namei}`.

* **Lookup** at `CP_INIT` of `CONT_LOAD_GLOBAL`
  (`pycore_cont_object.svh:178`), *before* the `co_names` read. A hit writes
  the cached entry straight to TOS and honours `container_push_null_r` for the
  `LOAD_GLOBAL` null bit — the two-beat `CP_LG_WB_NULL` path must still run.
* **Fill** at `CP_DICT_RD_VTAG`, only on a successful resolve (globals *or*
  builtins).
* **Flush** in `CONT_STORE_NAME`, on `globals_base_r` change, and per §4.

Removes an 8-link dependent chain 99% of the time (report F4).

**Done when:** full regression green, including `img_load_global_namei`,
`img_builtins_shadow`, `img_undef_global`, `img_attr_grow_global` and
`img_exec_globals_type_trap` — that last one is the `globals_base_r` swap and
is the test most likely to catch a missing flush.

### P8 — Frame top-of-stack buffer (gated)

`pycore_frame_buf.sv`, 4 frames, a shift register rather than a cache: push
writes into the buffer and marks dirty, overflow spills the oldest frame to
dmem, pop reads from the buffer when present.

> **Gate this phase on measurement.** Report F6 measured 34k cycles for the FTB
> *without an L1D in the system*. Once P3 lands, frame slots will hit in L1D at
> ~99% anyway, so the FTB's marginal value may be near zero. **Measure first:
> instrument L1D hit rate on the frame region after P3, and if it is above 95%,
> skip P8 and record that decision in the P9 write-up.** Building it anyway
> costs 1 kbit of flops and adds a real correctness surface.
>
> **P3 measurement — skip P8.** L1D frame-region hit rate (`0x1C000`–`0x20000`)
> at `CACHE_EN=1` / `MEM_LATENCY=4`: `img_recursion` 1414/1420 = **99.58%**,
> `img_deep_callgraph` 263/276 = **95.29%**. Both above the 95% gate. Do not
> build `pycore_frame_buf.sv`. Reconfirm in P9.

If it is built: the exception-unwind path in `pycore_call_fsm.svh` pops frames
too (`call_exc_pending_r`, RETURN phases 3–4). It must go through the same
buffer, or unwind reads stale dmem. `img_try_exc_cross_frame_fatal` and
`img_deep_callgraph` are the tests that catch this.

### P9 — Re-measure, and write down what actually happened

* Extend `pycore/tools/memsim/` to ingest the RTL performance counters and
  compare measured hit rates against the model's predictions. Where they
  disagree by more than a few points, the model was wrong — say so and fix it.
* Re-run `experiments.py`; update
  `planning/memory_hierarchy_report.md` with a measured-vs-predicted column.
* Update `pycore/docs/architecture.md` §"Memory subsystem" and
  §"Code memory regions"; add a new `pycore/docs/memory_hierarchy.md` covering
  the levels, the port contract of §0, and the invalidation matrix of §4.
* Extend `memsim` with string workloads and a STRACC access model. Strings in
  dmem are a new traffic class and are part of what the 8 KB L1D was sized for
  (report F5) — re-run E1/E3/E7 with them present and say whether the sizing
  held.
* Remove the string-memory rows from `pycore/docs/architecture.md` and
  `pycore/docs/object_model.md`; add the STR object to `object_model.md` and
  rewrite the LONG_STR row in `pycore/docs/tags.md` for the new handle.
* Record the STRACC Unicode ceiling in `pycore/docs/bytecode_support.md`, next
  to the 64-bit `int` ceiling.
* Graduate `planning/string_accelerator_plan.md` to
  `pycore/docs/string_accel.md`.
* Note in `planning/compile_plan.md` that on-device `compile()` allocates
  string constants through `HeapImageBuilder.alloc_str`, so a compiled-on-device
  module and an image-built module produce byte-identical string objects.
* Update the root `README.md` register/memory section.

---

## 6. Verification

Per-module testbenches, added to `PYCORE_MEM_SRCS` and `pycore-rtl-unit`:

| TB | Must cover |
| --- | --- |
| `tb_cache.sv` | hit; cold miss; capacity miss; conflict miss at every way; dirty eviction ordering; `fault_o` propagation from below; invalidate-all; flush-all with dirty lines; back-to-back requests; `READ_ONLY` write rejection |
| `tb_cache_lru.sv` | victim selection over every access order for 4 and 8 ways |
| `tb_ram.sv` | burst ordering; latency parameter honoured; writeback then read-back |
| `tb_l1d_handoff.sv` | dirty L1D line is invisible at the excore L2 port until flush; inv refill; `CACHE_EN=0` still pulses `flush_done` |
| `tb_str_accel.sv` | the accelerator against real memory, standalone: every primitive engine, the SHORT/LONG boundary at 15/16 bytes, every source/destination byte phase, UTF-8 across word and line boundaries, OOM with the heap pointer unmoved. Plus the CPython 3.14 differential harness — see `string_accelerator_plan.md` §9 |
| `tb_codc.sv` | fill, hit, way eviction, flush |
| `tb_gic.sv` | fill, hit, flush on store, no-fill on miss |
| `tb_frame_buf.sv` | push/pop/spill/refill, flush with dirty frames (if P8 is built) |

**The acceptance gate is a transparency test.** Run the entire image suite
twice — `PYCORE_CACHE_EN=1` and `PYCORE_CACHE_EN=0` — and require
**byte-identical retired results**. A cache that changes an architectural
result is a bug, and this catches it across all ~200 fixtures at once. Wire it
as a new Makefile target `pycore-cache-transparency` and add it to
`make all-tests`.

Second gate: run the image suite at `MEM_LATENCY` 1, 4 and 30 and require
identical results. This catches anything that assumed a fixed memory latency.

---

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| A cache changes an architectural result | The transparency gate in §6. Build `PYCORE_CACHE_EN=0` in P0 and never let it rot. |
| Something assumed 1-cycle memory | The latency-sweep gate. §0 lists every master and its wait mechanism — re-check each one in P2. |
| `encoding.py` / `pycore_defs.svh` drift | The mirror test in P0. Both P1 and P5 touch shared constants. |
| String equality regresses during the P5 cutover | `img_str_dict_key_runtime` is the fixture that proves the new model, and it fails on today's main. Silent failure mode: dict lookups on long-string keys start missing. |
| STRACC diverges from CPython on one of 47 methods | The differential harness, not directed tests, is the P5a/P5e gate. |
| L1D sized against alignment-unaware measurements | P1 lands before P3. |
| GIC missing a flush point | §4 matrix; `img_exec_globals_type_trap` is the sharpest test. |
| FTB and exception unwind diverge | P8 gate; if built, route unwind through the buffer. |
| P5 is large enough to strand the branch | P5a/P5b/P5c each end green independently. |

---

## 8. Where to look

| Need | Path |
| --- | --- |
| Measurements behind every size in §1 | `planning/memory_hierarchy_report.md` |
| Re-run the measurements | `python3.14 pycore/tools/memsim/experiments.py` |
| Existing bank + tiling | `pycore/rtl/pycore_mem_bank.sv`, `pycore_mem_block.sv` |
| A model memory TB | `pycore/tb/tb_mem_bank.sv` |
| Core FSM, dmem arbitration, heap pointer | `pycore/rtl/pycore_core.sv` (`:1124`, `:1202`, `:2343`) |
| CALL / RETURN code-field reads | `pycore/rtl/pycore_call_fsm.svh` (phases 2–6, RETURN 1–2) |
| `LOAD_GLOBAL` probe chain | `pycore/rtl/pycore_cont_object.svh:178` |
| String unit being replaced, and its four ports | `pycore/rtl/pycore_string_mem.sv`, `pycore_core.sv:1485`–`:1531` |
| String Accelerator design | `planning/string_accelerator_plan.md` |
| Native method dispatch (extends to 47 str methods) | `pycore_defs.svh::pycore_native_method_id` |
| excore grant mux and handoff | `pycore/rtl/pycore_excore_system.sv:278`–`:325` |
| Memory map, address helpers, tag map | `pycore/rtl/pycore_defs.svh`, `pycore/docs/tags.md` |
| Image build and heap allocator | `pycore/tools/heap_image.py`, `image_from_source.py`, `encoding.py` |
| Two-core protocol and trap taxonomy | `pycore/docs/architecture.md` §"Two-core transport" |
| Object layouts (list/dict/set/tuple/code) | `pycore/docs/architecture.md` §"Container heap and object model" |
| Test invocation | root `README.md` §"Testing workflows" |
