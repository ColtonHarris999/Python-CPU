# Plan: pycore-owned memory management (excore does not allocate)

**Status:** **plan only — do not implement yet.** Issued because a
**bytecode-native** memory manager on pycore is not possible with current
bytecode/ISA support (see §1). The *ownership* model (pycore allocates in RTL,
excore only consumes a pre-granted buffer) is implementable without new
opcodes; implement that only after this plan is explicitly approved.

Supersedes the excore-centric `mm.s` authority in
`docs/memory_manager_plan.md` workstreams 1–4 for *who allocates*.

**Goal:** pycore is the sole allocator. For every recoverable trap that needs
new memory, pycore computes size, allocates, and marshals the region (plus
operands) to excore. Excore only fills/copies/rehashes into the provided
buffer; it never calls `mm_alloc` / bumps a heap pointer of its own.

---

## 1. Is this possible with current bytecode support?

### Short answer

| Layer | Possible now? | Notes |
|---|---|---|
| **A. Pycore RTL allocates before trap** (bump or freelist in `pycore_core.sv`) | **Yes** | No new bytecode. Matches “know max size → alloc → send task”. |
| **B. Python/bytecode program is the allocator** (`.py` on pycore imem) | **No** | Blocked by missing call-in from `BUILD_*` / trap sites and missing raw-heap primitives (below). |

So the *ownership model* (pycore allocs, excore consumes) is implementable
now in RTL. A *bytecode-native* MM is not — that needs new support first.
This plan therefore stages **RTL ownership first**, and treats a real
Python MM as a later optional policy layer.

### Bytecode / ISA gaps blocking a Python MM (layer B)

1. **`BUILD_*` and grow traps are RTL, not CALL targets.**  
   `BUILD_LIST` / `BUILD_MAP` / `BUILD_SET` and the grow detection paths live
   in `S_CONTAINER`. There is no hook that says “call this code object to
   malloc, then continue.” Without that, a `.py` allocator cannot run on
   the hot alloc path.

2. **No supported way to maintain freelist metadata from bytecode.**  
   Heap block headers are raw 16-byte dmem slots. Current bytecode can
   build lists/dicts/sets and do subscript ops; it cannot cleanly do
   untyped pointer arithmetic + raw slot read/write of allocator metadata
   (no `ctypes`-like surface, no `PTR`-payload store/load ops for MM).

3. **Trap nibble is full (9–15).**  
   A voluntary “call MM” trap (plan 2.2 style) has no free 4-bit code
   without widening the trap encoding or retiring a code.

4. **`LOAD_ATTR` unsupported.**  
   A Python `mm.alloc(n)` style API via methods is out; only bare
   `CALL` to a known function handle would work, and that still needs the
   RTL call-in from (1).

**Gate for layer B:** add either (i) a fixed-address “alloc helper”
invoke from RTL (not full bytecode MM), or (ii) new opcodes / a small
raw-memory builtin set + a way to enter a resident code object from
`BUILD_*` and pre-trap sites. Until then, implement only layer A.

---

## 2. Target architecture (layer A — implementable)

```text
pycore (allocator authority)
  BUILD_* / frame / pre-trap:
      size = f(operands)          # exact, or upper bound for UPDATE
      (ptr, size) = pycore_alloc(size)
      marshal { trap, operands…, new_ptr, new_size }
      freeze; grant → excore

excore (worker only)
  handler:
      use MB-provided new_ptr/new_size
      copy / rehash / merge into that region
      result: COMPLETED + optional old_ptr to free
      never mm_alloc / never wilderness bump

pycore (on COMPLETED)
      install already done by excore in-place on objects
      pycore_free(old_ptr) if non-null and MM-backed
```

### Size rules (pycore computes before trap)

| Trap | Size formula (bytes of *payload* region) |
|---|---|
| `LIST_GROW` | `new_cap = cap ? cap<<1 : 4`; `new_cap * 32` |
| `LIST_EXTEND` | if `need=len+src_len <= cap`: **0** (in-place). Else grow-to-fit doubling from `max(cap*2\|\|4, need)` → `new_cap*32` |
| `DICT_GROW` | same slots-from-used policy as today’s `dict_grow_rehash` → `new_slots * 64` |
| `SET_GROW` | analogous → `new_slots * 32` |
| `DICT_UPDATE` | **upper bound** `need_used = dst.used + src.used` → slots formula → `slots*64` (overlap uncommon; over-alloc OK) |
| `SET_UPDATE` | same upper-bound idea → `slots*32` |
| `LIST_DELETE` | **0** |

All inputs are already in RF / object headers at the detecting
`S_CONTAINER` phase — no excore round-trip needed to size.

### Mailbox / result ABI changes

Today `MB_HEAP_PTR` is a wilderness bump tip. Under this design it becomes
(or is joined by) an **explicit grant**:

| Field | Meaning |
|---|---|
| `MB_NEW_PTR` (reuse `MB_HEAP_PTR` or add) | payload address of pre-allocated region (0 = none) |
| `MB_NEW_SIZE` (**new**, or pack into unused mailbox word) | byte size of that region |
| `RES_OLD_PTR` (**new** result field, or reuse a `RES_ENTRY`) | old buffer/table for pycore to free (0 = none) |
| `RES_HEAP_PTR` | retire as bump tip, or redefine as “unused / echo” |

Excore must **fault** (`FATAL(MEM_FAULT)` or `ILLEGAL`) if the handler
needs a region and `MB_NEW_PTR==0` or `MB_NEW_SIZE` is too small — that
catches sizing bugs on the pycore side.

### Free-on-resize

- Excore does **not** free. After install, it returns `old_buf` /
  `old_table` in the result.
- Pycore, in `S_TRAP_WAIT` on `COMPLETED`, calls `pycore_free(old_ptr)`.
- Pre-MM / image-boot objects without headers: free is a no-op (same
  magic check as today’s `mm_free`).

### What happens to `excore/fw/mm.s`

- **Remove** `mm_alloc` / `mm_free` from grow/extend/update handlers.
- Keep or delete `mm.s` / `tb_mm`: either delete as dead, or retarget
  later as a **pycore-side** reference model (C/Python) — not live
  excore firmware.
- Re-shrink IMEM if word count allows after removal.

---

## 3. Implementation phases

### Phase 0 — Doc / contract lock (this PR-sized doc)

- [ ] Mark `C-HEAP-002` resolved: **pycore is allocator authority**.
- [ ] Amend `C-HEAP-005`/`006`: excore never allocates; pycore pre-grants.
- [ ] Amend `C-HEAP-007`: free happens on pycore after `COMPLETED`.
- [ ] Update `mmio_map.md` + trap marshal notes for `NEW_PTR`/`NEW_SIZE` /
  `OLD_PTR`.
- [ ] Leave bytecode MM (layer B) as `deferred` with gaps listed in §1.

### Phase 1 — Pre-size + pre-bump on pycore (no freelist yet)

Still a bump allocator, but **authority and timing** match the new model.

1. In each trap-raising site in `pycore_core.sv`, before
   `trap_marshal_pending_r <= 1`:
   - compute `need_bytes` per §2 table;
   - if `need_bytes > 0`: bump `heap_ptr_r` (OOM → `MEM_FAULT` *before*
     marshal); set marshal heap fields to `{ptr, size}`;
   - if `need_bytes == 0`: marshal `{0, 0}`.
2. Excore handlers: use marshaled ptr as `new_buf` / `new_table`; delete
   `mm_alloc` / wilderness updates; on grow paths write `RES_OLD_PTR`.
3. Pycore `S_TRAP_WAIT`: ignore freelist for now (bump leak remains for
   old buffers) **or** simply drop `old_ptr` — document as interim.
4. Tests: `tb_excore*` updated for “ptr = MB grant, not grant+16”;
   two-core image suite green; negative test: wrong/zero grant → excore
   FATAL.

**Exit:** excore has zero allocation logic; behavior matches today’s
semantics for programs (still leaks on grow until Phase 2).

### Phase 2 — Pycore freelist + free-on-resize (RTL)

1. Port the size-class + wilderness + header format from `mm.s` into
   pycore-side logic:
   - **Preferred for cycle cost:** small RTL helper / FSM (`pycore_alloc` /
     `pycore_free`) used by `BUILD_*` and pre-trap sites.
   - **Alt:** keep bump for `BUILD_LIST` literals (capacity==count) and
     freelist only for grow grants — document asymmetry.
2. `S_TRAP_WAIT` on `COMPLETED` with `old_ptr != 0` → `pycore_free`.
3. Reclaim stress: grow-heavy loop must not OOM (`excore-reclaim-test` +
   image-boot). Close `C-HEAP-007` under pycore authority.
4. Remove dead excore MM firmware and `tb_mm` (or rewrite as a pycore TB).

**Exit:** true free-on-resize; one metadata format; excore still alloc-free.

### Phase 3 — Optional bytecode policy layer (blocked today)

Only after §1 gates:

1. Resident alloc code object at a fixed imem/dmem location **or** new
   `PY_OP_ALLOC` / helper CALL convention from RTL.
2. Raw heap load/store builtins or opcodes for header updates.
3. Trap-code space expansion if MM entry is trap-mediated.
4. Measure `cycle_count` / CPO vs Phase-2 RTL helper (`C-HEAP-004`).
5. Keep excore path unchanged (still consumes pre-granted regions only).

---

## 4. Risks and non-goals

- **Over-alloc on UPDATE** is accepted (uncommon; upper bound is fine).
- **Do not** re-introduce excore→pycore upcall for memory mid-handler
  (still violates the spirit of `C-HEAP-005`; under this design it is
  unnecessary because the grant is pre-sized).
- **Do not** require bytecode MM for Phase 1–2 correctness.
- Image tooling (`heap_image.py`) must stay consistent with pycore’s
  size formulas when laying out static heap.

---

## 5. Suggested first engineering slice (when implementation is approved)

1. Phase 0 doc updates (`constraints.md`, `mmio_map.md`, this file’s
   checkboxes).
2. Phase 1 only: pre-size/pre-bump + strip `mm_alloc` from
   `list_grow.s` + TB/image green.
3. Stop and measure; then Phase 2 freelist on pycore.

No Phase 3 work until bytecode gaps in §1 are closed.
