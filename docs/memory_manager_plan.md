# Implementation plan: PyCore memory manager + excore allocation handoff

> **SUPERSEDED (target design).** Do not implement further workstreams from this
> document as written. Allocator **authority** must move to **pycore** (pre-size
> + allocate, then send the grant with the trap). Excore must not own freelists.
>
> **Active plan:** [`docs/pycore_owned_allocator_plan.md`](pycore_owned_allocator_plan.md)
>
> A full **bytecode-native** MM on pycore is **not** possible with current ISA
> support; that plan therefore stages RTL ownership first and defers Python MM.
> Keep this file only as historical context for the DICT_UPDATE fix and the
> experimental excore `mm.s` that shipped in PR #43.

---

# (Historical) Implementation plan: excore-centric memory manager

**Audience:** a dedicated Cursor coding agent working in this repo.
**Status:** **superseded** — see `docs/pycore_owned_allocator_plan.md`.
Bug #1 (DICT_UPDATE / assembler `;`) is fixed; workstreams 1–4 below describe
the excore-`mm.s` experiment, not the target architecture.

This plan has five workstreams. They are ordered so each builds on a *verified*
predecessor. Do not start a workstream until the previous one's tests are green.

| # | Workstream | Risk | Depends on |
|---|------------|------|-----------|
| 0 | Assembler `;` fix + DICT_UPDATE fix + hash-container regression tests | low | — (done, verify) |
| 1 | Memory-manager firmware (`mm.s`) — cached bytecode allocator ABI | high | 0 |
| 2 | pycore integration: route `BUILD_*`/grow allocs through the MM | high | 1 |
| 3 | excore self-sufficient sizing + allocation for grow traps | med | 1 |
| 4 | Free-on-resize (reclaim old buffers) + coalescing free list | high | 1–3 |

Constraints this plan must honor are in `docs/constraints.md`
(`C-HEAP-001`…`C-HEAP-008`, `C-XCORE-001`…`C-XCORE-004`). Update that file's
revision log and any `open` entries you close.

---

## Background the agent needs before touching anything

Read `docs/agent_onboarding.md` first, then:

- Two cores share one dmem bank via an ownership grant. pycore freezes in
  `S_TRAP_MARSHAL`/`S_TRAP_WAIT` while excore owns memory. See
  `pycore/docs/architecture.md` §"Two-core transport".
- Today's allocator is a **bump pointer**. In pycore it is `heap_ptr_r` in
  `pycore/rtl/pycore_core.sv` (allocation = `heap_ptr_r += size` at each
  `BUILD_*` site, with an inline `> PYCORE_HEAP_LIMIT` OOM check). In excore
  firmware it is the same bump against `MB_HEAP_PTR`/`HEAP_LIMIT`
  (`dgr_alloc` / `sgr_alloc` in `excore/fw/list_grow.s`).
- Grow paths **leak** the old buffer today (documented, intentional — see
  `C-HEAP-007`). Workstream 4 removes this.
- Container in-dmem layouts (list/dict/set/tuple) are in
  `pycore/docs/architecture.md` §"Container heap and object model". You must
  not change these layouts; the MM allocates *regions*, it does not own object
  formats — with one deliberate exception (workstream 1's header pre-fill).

---

## Workstream 0 — assembler + DICT_UPDATE fix + regression net (DONE — verify)

### What was wrong (root cause, empirically confirmed)

`excore/tools/asm_rv32.py`'s `strip_comment()` treated `;` as a **comment
marker**. Any firmware line written as two instructions separated by `;` was
silently truncated at the `;` — the second instruction was dropped with no
error. `do_dict_update`'s merge loop in `excore/fw/list_grow.s` used exactly
this style for its per-word scratch stores:

```asm
lw a0, SP_DATA0(s11); sw a0, SCR_VVAL0(x0)   # the sw was DELETED at assemble time
```

Result: DICT_UPDATE loaded each source key/value word into `a0` but never
committed it to `SCR_KVAL*`/`SCR_VVAL*`. The subsequent insert used **stale
scratch left over from a previous trap**, so `{**a, **b}` merged wrong keys and
values. Reproduced under Verilator: a first-ever DICT_UPDATE inserting `{7:77}`
produced `{7:99}` (99 leaked from an earlier DICT_GROW).

Only DICT_UPDATE was affected — it was the sole handler using the `;`-joined
one-liner style, which is also why it had no passing test to catch it.

### The fix (already applied on this branch)

1. `asm_rv32.py`: `;` is now a **statement separator**, not a comment. A single
   source line may hold several `;`-separated instructions; a leading label
   binds to the first. `#` and `//` remain comments.
2. `excore/fw/list_grow.s`: the 8 offending `du_loop` lines were rewritten one
   instruction per line (belt-and-suspenders; correct regardless of assembler).

### Verification (the agent must re-run and keep green)

- `python3 -m unittest discover -s excore/tests -p "test_*.py"` → 26 pass.
- New assembler test: `;` yields N instructions (see workstream-0 test tasks).
- `excore/tb/tb_excore_hashupdate.sv` (new) drives DICT_UPDATE/SET_UPDATE/
  DICT_GROW-with-rehash against a real `pycore_mem_bank` + mocked mailbox and
  checks table contents bit-exactly. All probes green on the fixed firmware;
  D0/D2/D3/D4 fail on the pre-fix firmware (keep that as a documented negative
  control, e.g. a `make` target that builds the *old* source and expects fail —
  optional but recommended).

### Tasks for workstream 0 (finish what's started)

- [ ] Add `asm_rv32.py` unit tests to `excore/tests/test_asm_rv32.py`:
  - `a;b;c` on one line → 3 encoded words in order.
  - `label: a; b` → label resolves to `a`'s address; `b` follows.
  - `#` and `//` still strip to end-of-line; a `;` inside nothing-but-comment
    (`# foo ; bar`) is not treated as a separator.
  - `.equ` unaffected.
- [ ] Wire `tb_excore_hashupdate.sv` into the Makefile as `excore-hashupdate-test`
  and into `excore-test`. Model it on `excore-cpu-test`.
- [ ] Add a pycore-side image-boot differential (workstream-0 test layer below)
  for `{**a, **b}` and `s |= t` so the bug is also caught end-to-end on the
  two-core top, not just the mocked-mailbox TB.
- [ ] Fix doc drift: `architecture.md`, `constraints.md`, `dict_excore.md`,
  `set_excore.md` all say "code 15 is free" — DICT_UPDATE (15) is live. Correct
  the trap taxonomy table, the `adding_a_trap_handler.md` "codes taken" line,
  and add DICT_UPDATE rows.

---

## Workstream 1 — memory-manager firmware (`excore/fw/mm.s`)

### Goal

A **bytecode/firmware allocator** that is "firmware on the pycore," stored in a
dedicated fast cache at a known fixed location, invoked automatically whenever a
region must be allocated. It returns, at the top of the register-file stack, the
**address** and **size** of the granted region. For the common containers
(dict/list/set) it also **pre-fills the object header** so the memory latency
and the switch-back-to-caller latency overlap.

> **Design note — where does the MM run?** `constraints.md` `C-HEAP-002` leaves
> "which core is allocator authority" open. This plan implements the allocator
> as **excore firmware** callable in-process (`C-HEAP-005`/`C-HEAP-006` require
> that excore can allocate during a trap without a pycore upcall), plus a
> **pycore-invocable entry** for pycore-originated `BUILD_*`. Both share one
> metadata format in dmem so either core can allocate under the heap grant.
> This is the "dual code, one metadata format" option in `C-HEAP-006`. The
> "Python bytecode program" framing in the request is satisfied by making the
> *policy* live in a relocatable firmware image at a fixed cache location; the
> CPython-bytecode-native pathway (an actual `.py` compiled to pycore imem) is
> recorded as a stretch alternative in "Open questions" below, because the
> current excore slot-port ABI is the only proven way to touch shared dmem
> today (`C-XCORE-003`).

### 1.1 Allocator metadata format (new region of dmem)

Reserve an allocator-metadata area. Proposal (put exact addresses in
`pycore_defs.svh` and mirror `.equ`s in `mm.s`):

```
PYCORE_MM_BASE      : base of allocator metadata (size-class heads + free list)
PYCORE_MM_FREE_HEADS: array of size-class free-list head pointers
PYCORE_HEAP_BASE..LIMIT : the managed region (unchanged window for now)
```

Free block header (16-byte slot, lives at the start of each free block):

```
free_blk + 0  : { next_free[63:0], size_bytes[63:0] }   // intrusive free list
free_blk + 16 : { prev_free[63:0], magic[63:0] }        // magic = 0xF2EE... sanity
```

Allocated block header (so `free` can find the size without a size-class scan):

```
alloc_blk + 0 : { size_bytes[63:0], class_id[63:0] }    // one 16B slot of overhead
alloc_blk + 16: <payload starts here — this is the address returned to caller>
```

- **Alignment:** 16 bytes (dmem slot granularity, `C-HEAP-008`).
- **Size classes:** pick a small set covering hot allocations. Recommended
  seed set (bytes of *payload*), derived from the container layouts:
  - list object = 32B; list buffers grow by doubling (128, 256, 512, …)
  - dict table = `slots*64`; min 4 slots = 256B; then 512, 1024, …
  - set table = `slots*32`; min 4 slots = 128B; then 256, 512, …
  Seed classes: 32, 64, 128, 256, 512, 1024, 2048, 4096. Larger → "large"
  path (first-fit on the general free list; no class cache).
- **Common-size cache (`C-HEAP-003`):** each size class has a free-list head;
  alloc of a cached size is an O(1) pop, free is an O(1) push. Only the
  large/uncached path walks the general free list (first-fit).

### 1.2 Allocator ABI (the return contract)

The request says: "returns to the top of the register file stack an address of
the region and the size of the region." Concretely, adopt the
`{status, size, ptr}` shape from `C-HEAP-008` (preferred there for explicit
OOM):

- **excore-side (in-process call), registers:**
  `mm_alloc(a0=req_bytes, a1=class_hint/0, a2=header_kind)` →
  `a0=status (0 ok, 1 OOM)`, `a1=size_bytes (actual, ≥ req)`, `a2=ptr (payload
  addr; 0 on OOM)`. `header_kind ∈ {NONE, LIST, DICT, SET}` selects pre-fill
  (§1.3). Callee-saved discipline identical to existing helpers (save `ra`,
  `s*` on the private-scratch stack).
- **pycore-side result (for the pycore-invocable entry / trap result):** push
  two RF entries at TOS: a `PTR`-tagged region address and an `INT`-tagged
  size, "address of the region and the size of the region" as stated. Use the
  existing `RES_ENTRY[i]` push mechanism (`push_count=2`). Reserve a trap code
  for a pycore→MM allocation request **only if** workstream 2 chooses the
  trap-based invocation (see 2.2); the in-process excore path needs no trap.

### 1.3 Header pre-fill (latency overlap)

For `header_kind` in {LIST, DICT, SET}, `mm_alloc` writes the object header
**before returning**, so the caller resumes with the header already valid and
the memory-write latency overlapped with the core switch-back:

- **LIST** (`header_kind=LIST`, caller passes desired capacity in `a1`):
  allocate object (32B) + buffer (`cap*32`); write object header
  `{capacity, length=0}` and `ob_item = buf_addr`; return the **object**
  address + total size. (Empty list: `cap=0`, no buffer, `ob_item=0`.)
- **DICT** (`header_kind=DICT`, caller passes slot_count in `a1`): allocate
  object (32B) + table (`slots*64`); zero the table key tags (UNINIT=empty);
  write header `{slot_count, used=0}` and `table_ptr`; return object addr.
- **SET**: like DICT but table stride 32, header `{slot_count, used=0}`.
- **NONE** (`header_kind=NONE`): raw region; caller (pycore) fills any object
  data itself. Use this for objects the MM can't hardcode (the request's "for
  other objects we can't hardcode … let pycore deal with setting any relevant
  data").

> The pre-fill deliberately teaches the MM about three object formats. This is
> the *only* place the allocator knows object layout; keep it isolated in
> clearly-commented `mm_prefill_{list,dict,set}` routines so a layout change is
> a one-routine edit. Record this coupling in `constraints.md`.

### 1.4 Over-allocation for hot containers

The request: "for basic calls like creating maps, lists, and sets we want to
create large enough allocations … so we don't have to allocate a new region
over and over as we add the first few items."

- **CPython-literal semantics must be preserved for `BUILD_LIST`** (capacity ==
  count exactly — see `CONT_BUILD_LIST` and `alloc_list_with_capacity` in
  `pycore/tools/heap_image.py`). So over-allocation applies to the **grow**
  path and to `BUILD_MAP`/`BUILD_SET` (which already round up to
  `next_pow2(max(4, 2n))`), **not** to list literals. Document this asymmetry.
- For dict/set the existing `dict_min_slots` / `next_pow2(max(4,2n))` policy is
  already "large enough"; the MM just honors the slot_count the caller computes.
- For the list *grow* path, the excore already doubles (floor 4). Keep that; the
  MM's size-class cache makes the doubled request O(1) when cached.

### 1.5 Cache location / fast access

"Firmware … stored in a dedicated cache in a known location so we can access it
very fast." Implement as:

- A dedicated **MM imem region** in the excore private instruction memory at a
  fixed base (extend `excore_cpu.sv`'s IMEM or add a second small IMEM slave;
  see `excore/docs/rv32i_subset.md` "Memory model"). Simplest v1: append `mm.s`
  to the existing firmware image so it is already resident (no new cache) and
  measure; promote to a dedicated tightly-coupled region only if profiling
  shows fetch pressure. Record the decision in `constraints.md`.
- The metadata (§1.1) lives at a fixed dmem base so both cores reach it via the
  slot port with no pointer chasing to find the allocator roots.

### Workstream 1 tasks

- [ ] Add `PYCORE_MM_*` constants to `pycore_defs.svh`; mirror `.equ`s in `mm.s`.
- [ ] Write `excore/fw/mm.s`: `mm_init` (build initial single free block over
  `[HEAP_BASE, HEAP_LIMIT)`), `mm_alloc`, `mm_free`, `mm_prefill_{list,dict,set}`,
  size-class helpers, general first-fit fallback.
- [ ] Assemble stand-alone; assert it fits IMEM (`asm_rv32.py` reports word
  count; current fw is 1674 words of a 2048 budget — MM must fit the remainder
  or IMEM must grow in `excore_cpu.sv`).
- [ ] Unit-test `mm.s` in isolation (new `excore/tb/tb_mm.sv`, mocked mailbox
  driving a synthetic `mm_alloc`/`mm_free` sequence, real `pycore_mem_bank`):
  alloc/free round-trips, size-class pop/push O(1), OOM, coalesce (with
  workstream 4), header pre-fill bit-exact for each kind.

---

## Workstream 2 — pycore invokes the MM for `BUILD_*` and grow

"It is automatically called when we need to allocate memory for any reason."

Two invocation styles; pick per the measured cost (`C-HEAP-004` says the open
question is dispatch cost, not find-space):

### 2.1 Keep pycore's inline bump for now, back it with the MM metadata

Lowest-risk first step: leave the `heap_ptr_r` bump sites in `pycore_core.sv`
but have them **carve from the MM's free structure** instead of a raw pointer,
so free-on-resize (workstream 4) has real blocks to reclaim. This is a
mechanical change at each `heap_ptr_r + size > LIMIT` site (grep
`heap_ptr_r` in `pycore_core.sv`; there are ~6 `BUILD_*`/frame sites).

### 2.2 Or: route pycore `BUILD_*` allocations through a trap to the MM

If profiling justifies putting policy in one place: a pycore-originated alloc
becomes a **voluntary trap** (`C-HEAP-005`: "pycore needs slow-path alloc while
it owns the heap → voluntary trap/call") to a new MM entry in excore firmware.
Reuse the `S_TRAP_MARSHAL`/`S_TRAP_WAIT` machinery; result pushes `{ptr, size}`
(§1.2). Add a trap code (15 is taken by DICT_UPDATE; use the next free nibble
and update `pycore_trap_recoverable`). This is heavier per-alloc; only choose it
if the inline path's duplicated policy becomes a maintenance problem.

**Recommendation:** ship 2.1 first (unblocks workstream 4), evaluate 2.2 with
the cycle counter (`cycle_count`, `CPO` metric) before committing.

### Workstream 2 tasks

- [ ] Convert each `heap_ptr_r` bump site to `mm_alloc`-carve semantics
  (2.1). Preserve exact OOM behavior (`PY_TRAP_MEM_FAULT`) and the
  `BUILD_LIST` capacity==count invariant.
- [ ] Two-core image-boot differentials proving allocation still matches CPython
  object graphs for list/dict/set literals and comprehensions.

---

## Workstream 3 — excore self-sufficient sizing + allocation for grow traps

The request: excore "needs to be able to calculate the size of the allocation
and find the allocation" itself, because a round-trip to pycore for memory "adds
lots of delay." Excore already sizes+allocates for DICT_GROW/SET_GROW/list-grow
(bump against `MB_HEAP_PTR`). This workstream **replaces the bump with
`mm_alloc`** so those handlers use the shared allocator (and can later free).

Concretely, the request's worked example — **list extension**: excore computes
`need = len(dst) + len(src)`, calls `mm_alloc` for the grow-to-fit capacity,
gets the new region address, and performs the copy+extend into it during the
trap. This is already the control flow in `do_list_extend`
(`ext_need`/`ext_cap_*`); swap its `MB_HEAP_PTR` bump for an `mm_alloc` call and
(workstream 4) free the old buffer.

> "when the pycore gives excore a task that requires new memory it needs to be
> able to … pass the address over to excore so it can perform the task" — note
> the current ABI already passes `MB_HEAP_PTR` to excore each trap. With the MM,
> excore no longer needs a pre-computed heap pointer handed to it; it calls
> `mm_alloc` in-process. Keep `MB_HEAP_PTR` in the message for one release for
> compatibility, then retire it (update `mmio_map.md`, `trap_mailbox.sv`,
> `excore_mmio.sv`, and the marshal side in `pycore_core.sv`).

### Workstream 3 tasks

- [ ] Replace `dgr_alloc`, `sgr_alloc`, and the list-grow/extend allocation
  bumps in `list_grow.s` with `mm_alloc` calls (link `mm.s` into the firmware
  image).
- [ ] Recompute `RES_HEAP_PTR` semantics: today handlers return the post-bump
  pointer so pycore keeps bumping. With the MM owning free space, `RES_HEAP_PTR`
  becomes advisory/removed. Update `S_TRAP_WAIT` (`heap_ptr_r <= res.heap_ptr`)
  accordingly — this is a cross-core contract change, do it atomically with the
  message-format edit.
- [ ] Extend `tb_excore_hashupdate.sv` + list/set update TBs to assert the new
  regions come from `mm_alloc` (e.g. non-overlapping, header-correct) and that
  results are still `COMPLETED` with correct pop/push.

---

## Workstream 4 — free-on-resize + coalescing (`C-HEAP-003`, `C-HEAP-007`)

"when a collection is resized we want to free the old allocation from memory and
have that area usable again."

- In every grow handler (list grow/extend, dict grow, set grow, and their
  pycore counterparts if any), after installing the new buffer/table, call
  `mm_free(old_buf)`. The old block returns to its size-class free list or the
  general list.
- **Coalesce on free** (`C-HEAP-003`): merge with physically-adjacent free
  neighbors so the heap tends toward `free/allocated/free/…` alternation. Use
  the allocated/free block headers (§1.1) to find neighbor boundaries;
  boundary tags (a footer replicating size) make O(1) coalescing possible —
  add a footer slot to the block format if you want O(1) back-coalesce.
- Remove the "INTENTIONALLY LEAKS" comments in `list_grow.s` as each path gains
  a real free. Update `C-HEAP-007` to `accepted`/closed and note the date.

### Workstream 4 tasks

- [ ] Implement `mm_free` with coalescing; add magic/consistency asserts
  (fatal `MEM_FAULT` on corruption, mirroring existing fault handling).
- [ ] Add `mm_free` calls to all resize handlers; delete leak comments.
- [ ] Stress test: a loop that grows a list/dict/set many times must not run
  the heap out of space (proving reclamation) — a pre-fix run OOMs
  (`PY_TRAP_MEM_FAULT`), a fixed run completes. Make this an explicit
  regression (`make excore-reclaim-test` and a two-core image-boot version).

---

## Test design (applies across workstreams)

Three layers, cheapest first. Every workstream adds to all three where relevant.

### Layer A — assembler unit tests (`excore/tests/test_asm_rv32.py`, pure Python)

Fast, no Verilator. Cover encoding of any new pseudo-ops `mm.s` needs, and the
`;`-separator semantics (workstream 0). Run with
`python3 -m unittest discover -s excore/tests`.

### Layer B — excore mocked-mailbox RTL TBs (Verilator, no Python 3.14)

Model on `excore/tb/tb_excore.sv` and the new `tb_excore_hashupdate.sv`. Drive
canned trap messages / synthetic MM calls onto the mailbox ports; a real
`pycore_mem_bank` backs the slot port; `poke_slot`/`peek_slot` set up and verify
dmem bit-exactly. This is where allocator correctness is nailed down because you
control every byte. **Discipline learned the hard way:** `do_reset()` does NOT
clear dmem and firmware scratch persists across traps, so each scenario must
`clear_region` the whole heap window `[0x400,0x2000)` and use non-overlapping
addresses — otherwise a stale value from a prior scenario masquerades as a pass
or a fail. (This is literally how the DICT_UPDATE bug hid: stale scratch.)

Required scenarios (seed; extend per workstream):

- `tb_mm`: alloc/free/realloc; size-class O(1) pop/push; first-fit large path;
  OOM; coalesce (adjacent-free merge, no false merge across an allocated block);
  header pre-fill bit-exact for LIST/DICT/SET; NONE returns raw region.
- `tb_excore_hashupdate` (already written): DICT_GROW-with-rehash of existing
  entries (not just empty), DICT_UPDATE no-grow / overwrite / grow-forcing,
  SET_UPDATE from list/tuple/set. Keep the "used" count and every surviving
  key/value asserted.
- Post-workstream-3/4: assert grown regions come from `mm_alloc` and old buffers
  are freed (peek the freed block's header for the free magic / that a
  subsequent alloc reuses the address).

### Layer C — two-core image-boot differentials (needs Python 3.14)

`pycore/tools/image_from_source.py` + `run_image_test.py`, run on the
`pycore_excore_system` top (`-GEXCORE_EN=1 -GFW_HEX=…`). These prove the real
bytecode path end-to-end and diff against CPython. Add programs under
`pycore/programs/`:

- `dict_update_merge.py` (`{**a, **b}` with overlap + grow), `set_ior.py`
  (`s |= t`), plus existing container programs re-run to prove no regression.
- Reclaim stress programs for workstream 4.
- Each new trap/alloc program also gets an `EXCORE_EN=0` companion proving the
  op still traps fatally when excore is disabled (mirrors the existing
  convention in `adding_a_trap_handler.md` step 7).

> **Environment note for the agent:** the sandbox used to *find* the
> DICT_UPDATE bug had Verilator but only Python 3.12, so Layers A and B ran but
> Layer C did not. Layer C must be run in a Python 3.14 environment (see
> `README.md` "Quick setup"). Do not mark a workstream done on Layers A+B
> alone if it changes the cross-core contract (workstreams 2–4 all do).

### Regression gates (add to `make all-tests`)

`excore-test` (asm + `tb_excore`), `excore-hashupdate-test`, `excore-mm-test`,
`excore-reclaim-test`, and the new `pycore-img-*` two-core targets. CI must fail
if any single scenario's `soft_fails` is nonzero or `cpu_fault` asserts.

---

## Sequencing checklist (definition of done per workstream)

- **0:** asm tests + `tb_excore_hashupdate` green on fixed fw; docs de-drifted.
- **1:** `mm.s` assembles + `tb_mm` green (alloc/free/prefill/OOM); coalesce may
  be stubbed until 4 but the block format must already carry the headers 4 needs.
- **2:** container literals/comprehensions still match CPython (Layer C); no
  heap-behavior regression in existing tests.
- **3:** all grow handlers use `mm_alloc`; hashupdate + list/set update TBs green;
  cross-core message-format change landed atomically with the RTL that reads it.
- **4:** reclaim stress passes (grow-heavy loop no longer OOMs); leak comments
  gone; `C-HEAP-007` closed in `constraints.md` with date.

## Open questions to resolve while implementing (update `constraints.md`)

- Final size-class set and the max size served by the class cache (§1.1) —
  measure against real container programs, don't guess (`C-HEAP-004`).
- Whether to promote `mm.s` to a dedicated tightly-coupled IMEM/cache region or
  leave it appended to the firmware image (§1.5) — decide on measured fetch
  pressure.
- Whether pycore `BUILD_*` uses inline-carve (2.1) or trap-to-MM (2.2) — decide
  on `cycle_count`/`CPO`.
- Stretch: a genuinely CPython-bytecode-native allocator (an actual `.py`
  compiled to pycore imem) vs. the RV32 firmware MM chosen here. Blocked on a
  32-bit shared-dmem master path for pycore-side data access
  (`C-XCORE-003`); record as deferred.
