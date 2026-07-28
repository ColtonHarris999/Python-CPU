# Agent onboarding: getting up to speed on PyCore fast

For Claude / Cursor agents. Read this before editing. It is a map, not a spec —
the authoritative details live in the files it points at.

## What this repo is (one paragraph)

PyCore is a research CPU whose **native ISA is CPython 3.14 bytecode**, written
in portable SystemVerilog. It is a **two-core** system: **pycore** (the
CPython-bytecode hart) executes bytecode over tagged 132-bit register entries
`{tag[3:0], value[127:0]}`; **excore** is a vendored RV32 multicycle hart that
services *recoverable* container traps (list/dict/set grow, extend, delete,
update) in firmware instead of halting. The two cores share one data-memory bank
via an ownership grant that flips on trap request/result. Instruction memories
are private per core (Harvard). Everything is a functional/FPGA-class prototype,
not an ASIC floorplan.

## The 10-minute mental model

1. pycore runs an instruction through `S_FETCH→S_DECODE→S_EXEC→S_MEM→S_WB`.
   Container ops (`BUILD_*`, `LIST_APPEND`, subscript, etc.) divert to a big
   `S_CONTAINER` state machine with `CP_*` sub-phases.
2. When a container op needs capacity-changing or O(n) work (grow a list,
   rehash a dict, merge a set), pycore raises a **recoverable trap** *before it
   commits any state*, marshals the operands into a mailbox, and **freezes**.
3. Memory ownership flips to excore. Excore firmware (`excore/fw/list_grow.s`)
   dispatches on the trap code, does the work against shared dmem through a
   128-bit **slot port** (MMIO bridge), writes a result (`COMPLETED`/`RETRY`/
   `FATAL`, pop/push counts, entries), and parks.
4. Ownership flips back; pycore applies the result (pops/pushes RF entries,
   resumes). Fatal traps instead halt via `pycore_trap.sv`.

That "complete the semantic effect, don't just retry" contract, and the
"trap before any commit" discipline, are the two invariants everything depends
on. Both are explained in `pycore/docs/architecture.md` §"The excore contract".

## Where things live

| You want to… | Look at |
|---|---|
| Understand the whole system | `pycore/docs/architecture.md` (start here) |
| Tag encodings, container dmem layouts | `README.md` + architecture.md §"Container heap and object model" |
| Trap codes / recoverable split | `pycore/rtl/pycore_defs.svh` (`PY_TRAP_*`, `pycore_trap_recoverable`) — **source of truth** |
| pycore control + container FSM | `pycore/rtl/pycore_core.sv` (~6.7k lines; grep by `CONT_*` / `CP_*`) |
| excore firmware (all trap handlers) | `excore/fw/list_grow.s` (~2.2k lines; labels are the index) |
| excore↔pycore mailbox + MMIO | `excore/rtl/excore_mmio.sv`, `excore/rtl/trap_mailbox.sv`, `excore/docs/mmio_map.md` |
| excore RISC-V subset | `excore/docs/rv32i_subset.md` |
| The RV32 assembler | `excore/tools/asm_rv32.py` (self-contained; no external toolchain) |
| Dict / set ownership split | `pycore/docs/dict_excore.md`, `pycore/docs/set_excore.md` |
| Image tooling (bytecode → dmem) | `pycore/tools/image_from_source.py`, `run_image_test.py` |
| Static heap image construction | `pycore/tools/heap_image.py` (mirrors RTL hash/probe/size rules) |
| **Architectural constraints & deferred decisions** | `docs/constraints.md` — read before heap/trap/allocator work |
| **The active memory-manager project** | `docs/memory_manager_plan.md` |

## Build & test (what actually runs)

Toolchain: `make`, `g++`, **Verilator**, and **Python 3.14** (only the pycore
image tooling needs 3.14; the excore assembler and mocked-mailbox tests are
plain Python 3 + Verilator).

```bash
# excore only — assembler unit tests + mocked-mailbox RTL TB (no Python 3.14):
make excore-test

# the hash-container update regression (DICT_UPDATE/SET_UPDATE/rehash):
make excore-hashupdate-test          # (added by the memory-manager project)

# full two-core + image-boot suite (needs Python 3.14):
make all-tests

# run one Python file through the two-core system:
make run-file RUN_SOURCE=pycore/programs/smoke_return.py RUN_FUNCTION=managed_entry
```

Three test layers, cheapest first (details in
`docs/memory_manager_plan.md` §"Test design"):
- **A** — assembler unit tests, pure Python, `excore/tests/test_*.py`.
- **B** — excore mocked-mailbox RTL TBs (Verilator), `excore/tb/tb_excore*.sv`.
  You control every dmem byte via `poke_slot`/`peek_slot`. This is where
  allocator/firmware correctness is nailed down.
- **C** — two-core image-boot differentials vs CPython (needs Python 3.14).

## Traps that route to excore (from `pycore_defs.svh`)

| Code | Name | Meaning |
|---|---|---|
| 9 | LIST_GROW | append at capacity → double+append |
| 10 | LIST_EXTEND | non-empty extend → in-place or grow-to-fit |
| 11 | DICT_GROW | new-key insert at load ≥ 2/3 → realloc+rehash+store |
| 12 | LIST_DELETE | mid-list delete → shift down |
| 13 | SET_GROW | add at load ≥ 2/3 → realloc+insert |
| 14 | SET_UPDATE | bulk merge from list/tuple/set |
| 15 | **DICT_UPDATE** | `{**a, **b}` merge — **live** (some older docs wrongly say "15 free"; trust `pycore_defs.svh`) |

## Landmines (learned the hard way — don't rediscover these)

1. **The assembler treats `;`… correctly now, but historically did not.**
   `asm_rv32.py` used to treat `;` as a *comment marker*, silently truncating
   any `lw …; sw …` one-liner to just the `lw`. This produced a real,
   shipped DICT_UPDATE bug (merges inserted stale scratch values). `;` is now a
   **statement separator**. Still, prefer one instruction per line in firmware.
   If you see two instructions joined by `;`, assemble and check the word count.
2. **excore does not clear scratch or dmem between traps.** Firmware scratch
   (`SCR_*`) and the shared heap persist across traps. Any handler that inserts
   from scratch MUST freshly load every word it uses. Any *testbench* must
   `clear_region` the heap and use non-overlapping addresses per scenario —
   otherwise a stale value fakes a pass or a fail.
3. **"Trap before any commit" is load-bearing.** A new recoverable trap must be
   raised before any RF/heap/dmem write, or `RETRY` semantics break. See
   `excore/docs/adding_a_trap_handler.md` step 3.
4. **`BUILD_LIST` capacity == count exactly** (CPython literal semantics). Do
   not "over-allocate" list literals; growth only happens via append/extend.
   Dicts/sets round up to `next_pow2(max(4, 2n))` — that's fine.
5. **Register/scratch save discipline in firmware is manual.** Helpers save
   `ra` and callee-saved `s*` on the private-scratch software stack. `keys_rich_eq`
   clobbers `SCR_TMP_L0/L1`; callers that need those across it stash elsewhere
   (e.g. `do_dict_update` keeps src table ptr in `s10`, not `SCR_TMP_*`).
6. **Docs drift.** Several docs predate the DICT_UPDATE handler and the current
   allocator constraints. When RTL and a `.md` disagree, RTL + `pycore_defs.svh`
   win; then fix the doc.

## How to add an excore trap handler (short version)

Full checklist: `excore/docs/adding_a_trap_handler.md`. In brief: assign a code
in `pycore_defs.svh` + add it to `pycore_trap_recoverable`; raise it before any
commit in the detecting `S_CONTAINER` phase and marshal operands; add a dispatch
case in `list_grow.s`; choose `COMPLETED`/`RETRY`/`FATAL`; test at Layer B
(mocked mailbox) then Layer C (two-core image), plus an `EXCORE_EN=0` companion
proving it stays fatal when excore is off.

## Current active work

The **memory manager** project (`docs/memory_manager_plan.md`): a firmware
allocator with a size-class cache and object-header pre-fill, routing all
`BUILD_*`/grow allocations through it, making excore self-sufficient for grow
allocations, and adding free-on-resize + coalescing to stop the intentional
bump-allocator leaks. Workstream 0 (assembler fix + DICT_UPDATE fix + hash-
container regression tests) is done and verified; start by re-running its tests
green, then proceed in order.

## Quick sanity commands

```bash
# assemble the firmware and check it fits IMEM (2048-word budget):
python3 excore/tools/asm_rv32.py excore/fw/list_grow.s -o /tmp/fw.hex

# build+run the excore mocked-mailbox TB directly (bypassing make):
verilator -sv --binary --timing +incdir+pycore/rtl +incdir+excore/rtl/singlecore \
  +incdir+excore/rtl --top-module tb_excore -GFW_HEX='"/tmp/fw.hex"' \
  --Mdir /tmp/vb -Wall -Wno-fatal \
  pycore/rtl/pycore_mem_block.sv pycore/rtl/pycore_mem_bank.sv \
  excore/rtl/excore_cpu.sv excore/rtl/excore_mmio.sv excore/tb/tb_excore.sv
/tmp/vb/Vtb_excore
```
