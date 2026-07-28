# System design constraints

Living document for architectural constraints and deferred decisions across
**pycore**, **excore**, and shared memory. Review and update this file when
touching heap allocation, trap transport, ownership, or ASIC-facing splits.

---

## How to use this file

| Field | Meaning |
| --- | --- |
| **ID** | Stable id (`C-<AREA>-NNN`). Never reuse an id for a different meaning. |
| **Status** | `open` · `accepted` · `deferred` · `superseded` · `rejected` |
| **Area** | e.g. `heap`, `transport`, `clocks`, `excore`, `pycore` |
| **Recorded** | Date the constraint was written (UTC). |
| **Last review** | Date last explicitly re-validated (UTC). |

**Adding an entry:** append under the right section (or create a section). Prefer
amending the existing id’s notes over inventing a duplicate. When superseding,
set the old entry to `superseded` and point at the new id.

**Review trigger:** before implementing a real allocator, changing trap
ownership, enabling concurrent pycore+excore heap use, or ASIC clock/DRAM work.

---

## Snapshot (current prototype)

| Topic | Current state |
| --- | --- |
| Heap | **Prototype:** excore `mm.s` freelist + wilderness; pycore still bumps. **Target:** pycore-owned alloc (see `docs/pycore_owned_allocator_plan.md`) |
| Free / reclaim | **Prototype:** excore `mm_free` on grow. **Target:** pycore frees `RES_OLD_PTR` after `COMPLETED` |
| Shared dmem | One bank; exclusive `mem_owner` mux (`PYCORE` \| `EXCORE`) |
| Clocks | Single shared clock (FPGA / sim prototype) |
| Excore → dmem | Slot port only (16-byte aligned MMIO bridge); CPU `lw`/`sw` cannot address shared heap |
| Excore stack | Private 1KB scratch (`sp` grows down from scratch top); not heap-backed yet |
| Allocator policy | **Target redesign:** pycore pre-allocates trap grants; excore never allocates (plan only; not implemented) |

---

## 1. Heap and allocator

### C-HEAP-001 — Bump allocator is temporary

| | |
| --- | --- |
| **Status** | `accepted` (prototype) / `deferred` (replacement) |
| **Area** | `heap` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

The bump allocator will not scale: no free, fragmentation via intentional grow
leaks, fixed `PYCORE_HEAP_BASE`…`PYCORE_HEAP_LIMIT` window. A real memory
manager is required before long-running or allocation-heavy workloads.

**Must review later:** free on grow; size classes; metadata in DRAM as source of
truth vs `heap_ptr_r` alone.

---

### C-HEAP-002 — Candidate designs (allocator ownership)

| | |
| --- | --- |
| **Status** | `accepted` (excore firmware MM v1) · **proposed supersession** → pycore-owned |
| **Area** | `heap` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

**Resolution (2026-07-28):** v1 ships an **excore firmware allocator**
(`excore/fw/mm.s`) with size-class free lists + wilderness bump; metadata at
`PYCORE_MM_BASE`. Pycore `BUILD_*` still uses the inline `heap_ptr_r` wilderness
bump; excore syncs `max(wilderness, MB_HEAP_PTR)` each trap. Full pycore
carve-from-MM (plan workstream 2.1) remains a follow-up. The Python-bytecode
and dedicated-hardware options stay deferred.

**Proposed supersession (plan only — not implemented):** allocator authority
moves to **pycore**. For every recoverable trap that needs new memory, pycore
computes size (exact or upper bound), allocates, and marshals `{NEW_PTR,
NEW_SIZE}` with the task; excore fills that region only and never calls
`mm_alloc`. A bytecode-native MM is blocked by current ISA gaps. Full plan:
`docs/pycore_owned_allocator_plan.md`. Flip this entry to `superseded` /
re-`accepted` under pycore when Phase 0 of that plan lands.

---

### C-HEAP-003 — Coalesced free list shape

| | |
| --- | --- |
| **Status** | `accepted` (design intent) |
| **Area** | `heap` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

Free regions are **merged** on free so adjacent frees do not remain split.
In address order, heap blocks should tend to alternate
`free / allocated / free / allocated / …` after coalescing.

**Search structure:** prefer threading **free blocks only** (and/or size-class
free heads). Do not require malloc to scan every allocated object header.
Address-order alternation describes layout after coalesce, not the only
lookup walk.

**Common-size region cache:** required for hot `BUILD_*` / small object paths
so typical allocs are O(1) cache pops, not first-fit scans.

---

### C-HEAP-004 — Hot-path cost is dispatch, not find-space (given C-HEAP-003)

| | |
| --- | --- |
| **Status** | `accepted` |
| **Area** | `heap` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

With coalesce + size cache, “finding space” for common sizes is not assumed to
be the bottleneck. Remaining cost for a Python-firmware malloc is **entering
the routine and updating metadata** (bytecode/dmem ops) vs today’s few-cycle
HW bump in `S_CONTAINER`.

Treat absolute cycle budgets as **open until measured**. Do not reject Option 1
solely on assumed O(n) list walks.

---

### C-HEAP-005 — No alloc-interrupts on excore

| | |
| --- | --- |
| **Status** | `accepted` |
| **Area** | `heap` / `excore` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

Do **not** interrupt excore mid-handler (e.g. list extend, dict resize) to
service a pycore malloc. Heap access is already serialized by ownership/grant
(or a future allocator epoch).

- Pycore needs slow-path alloc while it owns the heap → voluntary trap / call.
- Excore needs alloc during a trap handler → **in-process** `heap_alloc` in
  firmware (same grant), not an upcall and not a nested IRQ.

**Proposed under pycore-owned plan:** excore never needs mid-handler alloc —
pycore pre-grants `{NEW_PTR, NEW_SIZE}` before the ownership flip
(`docs/pycore_owned_allocator_plan.md`).

---

### C-HEAP-006 — Excore must not depend on Python upcall for grow alloc (v1)

| | |
| --- | --- |
| **Status** | `accepted` |
| **Area** | `heap` / `transport` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

While excore holds the heap grant, dict/list/set grow must allocate (and
eventually free) **without** calling back into pycore Python malloc. Options
that keep this true:

- Allocator authority in excore firmware; and/or
- Shared DRAM metadata (size-class heads) that excore updates in-process; and/or
- Pycore-only Python malloc for pycore-originated allocs, with a compatible
  excore walker for the same format (dual code, one metadata format).

Nested ownership / Python upcall mid-trap is out of scope for v1.

**Proposed under pycore-owned plan:** satisfy this by eliminating excore alloc
entirely (pre-sized mailbox grant), not by keeping an in-process excore malloc.

---

### C-HEAP-007 — Grow paths must free old buffers (paired with allocator)

| | |
| --- | --- |
| **Status** | `accepted` |
| **Area** | `heap` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

Grow handlers call `mm_free` on the previous buffer/table after installing the
new region (`excore/fw/list_grow.s` + `excore/fw/mm.s`). Pre-MM buffers that
lack an alloc-header magic are left in place (no-op free) so pycore bump-built
objects remain safe until BUILD_* also routes through the MM.

**Closed:** 2026-07-28 with firmware MM free-on-resize.

---

### C-HEAP-008 — Allocator return ABI

| | |
| --- | --- |
| **Status** | `accepted` |
| **Area** | `heap` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

excore in-process: `mm_alloc` → `{status, size, ptr}` in `a0/a1/a2`
(`status=0` ok, `1` OOM; `ptr=0` on OOM). Alignment **16-byte**. Payload
address is returned (header is 16B before payload).

---

## 2. Transport, ownership, clocks (ASIC-facing)

### C-XCORE-001 — Prototype: single clock, exclusive dmem grant

| | |
| --- | --- |
| **Status** | `accepted` (prototype) |
| **Area** | `clocks` / `transport` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

`pycore_excore_system` uses one clock and flips `mem_owner` on trap_req /
trap_res handshakes. Non-owner must not raise dmem `req`. This collapses CDC
and dual-master DRAM into a functional model.

**Not** the ASIC target floorplan.

---

### C-XCORE-002 — ASIC intent: separate clocks + shared DRAM

| | |
| --- | --- |
| **Status** | `deferred` |
| **Area** | `clocks` / `transport` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

Intended direction:

- Separate pycore / excore clock domains (or independent PLL outputs).
- Shared DRAM via interconnect + controller (third domain).
- Mailbox over CDC (async FIFO / multi-beat), not a same-cycle wide bus only.
- Heap grant or allocator epoch still required for atomic grow/rehash; full
  freeze of pycore may relax later for non-heap ops only.

Cross-core “communication time” becomes CDC + DRAM latency, not 1–2 shared
clock cycles.

---

### C-XCORE-003 — Excore CPU cannot directly load/store shared heap

| | |
| --- | --- |
| **Status** | `accepted` |
| **Area** | `excore` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

`excore_cpu` serves normal `lw`/`sw` only to private scratch and MMIO. Shared
dmem is reachable solely through the **slot port**. Heap-backed `sp` is invalid
until a 32-bit shared-memory master path exists.

Software stack stays in private scratch; optional future heap reservation for
stack requires that path plus allocator cooperation (see C-HEAP-005/006).

---

### C-XCORE-004 — Mailbox is not in shared dmem

| | |
| --- | --- |
| **Status** | `accepted` |
| **Area** | `transport` |
| **Recorded** | 2026-07-28 |
| **Last review** | 2026-07-28 |

Trap request/result payloads use the parallel mailbox (`trap_mailbox.sv`)
because dmem ownership is exactly what the trap transfers. Multi-beat
serialization for ASIC wire count remains future work (`architecture.md`).

---

## 3. Open questions checklist

Use before locking an allocator implementation:

- [ ] Who is metadata authority under the heap grant? (pycore Py / excore / both with one format)
- [ ] Size-class set and max size served by the common-size cache
- [ ] Exact alloc return record (`C-HEAP-008`)
- [ ] Whether Python firmware is primary, slow-path only, or research A/B
- [ ] Cycle budget for cached Python malloc vs HW bump (measure)
- [ ] Free-on-grow + coalesce correctness tests
- [ ] ASIC: CDC mailbox + dual DRAM masters vs continued exclusive epoch

---

## Revision log

| Date | Change |
| --- | --- |
| 2026-07-28 | Initial file: bump limits; allocator options; coalesce + size cache; no alloc-IRQ; ASIC clock/DRAM; slot-port constraint. |
