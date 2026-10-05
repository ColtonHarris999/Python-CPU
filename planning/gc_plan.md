# Garbage collection plan (PyCore + excore)

Status: **approved for implementation; nothing implemented yet.** Design
target is `main` at `f5a8eb92b6b3dc5de9ac5133c8ba9f54a72b79f3` (2026-09-22).

This plan is written for an implementing agent with **no prior context**: no
earlier chat, no brief, no memory of the planning session. Everything you need
is in this file, the repository, and the papers cited in §2.5. Read Part A and
Part B in full before you change any code.

Every statement below is labelled:

- **[V]** verified against RTL / firmware / tooling on that commit (`file:line`).
- **[P]** proposed change (new module, signal, routine, fixture, doc).
- **[?]** unresolved; needs an experiment. Each one has a resolution rule in §9.
- **[A]** analytical estimate (no simulation or synthesis was run for it).

Companion docs to update when this lands: `pycore/docs/memory_hierarchy.md`,
`pycore/docs/architecture.md`, `pycore/docs/code_loading.md` §5,
`pycore/docs/object_model.md`, `excore/docs/mmio_map.md`, `README.md`.

---

## Part A. Mission, rules, and when you may stop

### A.1 Mission

Build a precise, stop-the-world, non-moving mark-and-sweep garbage collector
for PyCore (design in §2-§5) that:

1. **never frees a reachable object** (safety);
2. **frees every unreachable object at every collection** (completeness; the
   collector is precise and stop-the-world, so there is no excuse for
   floating garbage);
3. **costs zero cycles when it is not collecting**, and with `GC_EN=0` is
   cycle-for-cycle identical to today;
4. is a **great** hardware collector, not merely a working one: it adopts or
   explicitly rejects, with measurements, the techniques of published
   full-hardware mark-sweep collectors (§2.5) and meets the performance
   targets in §10.2 gate G13;
5. is **proven by evidence**, meaning the gates in §10, and not by argument.

Out of scope (do not start these; they are documented ceilings): code-RAM
reclamation (§5.3, Phase 7), moving or compacting collection, concurrent or
incremental collection, generational collection.

### A.2 Non-negotiable rules

1. **You may not declare the task complete** until every gate in §10.2
   passes in one `make pycore-gc-acceptance MODE=full` run on a clean tree at
   the commit you are handing back, or at its parent when the only later
   commits are ledger updates (A.3, §10.3). Anything less is a progress
   report and must be labelled as one.
2. "I believe it works" is not evidence. Only gate output counts. When you
   report, quote gate results, not impressions.
3. **Never weaken a check to make it pass.** Do not raise a tolerance or a
   `MAX_CYCLES` cap (the only exception is the procedure in §8 risk 3, with a
   ledger entry). Do not delete, skip, or `xfail` a test. Do not edit an
   existing golden. Do not add `# pycore-expect:` to a program whose result
   host CPython can compute. Do not shrink the fuzz corpus or remove mutants.
   If a check is genuinely wrong, prove it in the ledger (command, output,
   reasoning) and fix the check in its own commit.
4. **Regression first.** Every bug found by fuzzing, torture, a mutant, or a
   review becomes a permanent directed fixture that fails *before* the fix is
   committed.
5. **Reality beats this plan.** When the code contradicts a [V] claim or a
   [P] design turns out wrong, update this plan (mark the old text
   "superseded", with the evidence) and `pycore/docs/gc.md`. Never diverge
   silently.
6. `GC_EN=0` must stay cycle-identical to the baseline at **every** commit
   (gate G1).
7. Work on a branch named `gc/<something>`. Commit at least once per
   completed sub-step, with messages that name the phase and gate
   (e.g. `GC P2: UNPACK_EX reserves before tos change (G9)`). Every completed
   phase stays green for its exit gates.

### A.3 When you may stop

There are exactly two exits.

- **DONE.** `build/gc_acceptance/status.json` records `"mode": "full"` and
  `"pass"` for every gate `G0`..`G16`; its `head` is `HEAD`, or an ancestor
  of `HEAD` where the later commits touch only `planning/gc_progress.md` and
  `planning/gc_reviews.md`; and the tree is clean. Commit the updated ledger,
  then write the final report (gate table, performance table, known
  ceilings).
- **BLOCKED.** Something only a human can provide: a tool that cannot be
  installed in your environment, credentials, or a design contradiction that
  §9's defaults do not resolve and no experiment can. Before stopping,
  finish every other gate and phase that is not blocked. Then write
  `.cursor/gc_blocked.md` containing: the gate ID; the exact commands and
  their output; at least two alternatives you tried; and the precise action
  you need from the human.

These are **not** blockers: slow simulations (run them in the background
and poll), failing tests, hard bugs, large refactors, flaky-looking results
(find the nondeterminism), and a nearly full context window. For the last
one, write a handoff in the ledger (what is done, what is in flight, the next
command to run) and keep working; the ledger exists so a fresh agent can pick
up where you left off.

### A.4 Enforcement

- **Stop hook.** `.cursor/hooks.json` runs `.cursor/hooks/gc_stop_gate.py`
  on every agent `stop` event with no loop limit. It does nothing unless the
  file `.cursor/gc_task_active` exists; the human creates that file to start
  this task. While it is active, the hook reads
  `build/gc_acceptance/status.json` and, unless the DONE conditions in A.3
  hold or `.cursor/gc_blocked.md` exists, sends you a follow-up message that
  lists what is missing. The hook hardcodes the gate IDs `G0`..`G16`;
  changing that list needs a human edit to both this plan and the hook.
  **Do not edit or delete the hook, the marker, or `status.json`.** Only the
  acceptance runner writes `status.json`.
- **Goal.** If your harness has a goal tool (Cursor's `CreateGoal`), the human
  explicitly asks you to create a goal with the objective *"Every gate in
  planning/gc_plan.md §10.2 passes in `make pycore-gc-acceptance MODE=full`
  on a clean tree"*, and to mark it complete only at DONE.

### A.5 Kickoff (first session only; later sessions start at A.6)

1. `git fetch origin && git checkout -b gc/implementation origin/main`. If a
   `gc/*` branch already exists, check it out and go straight to A.6.
2. `git submodule update --init --recursive`. Confirm
   `verilator --version` (5.x) and `python3.14 --version`. If either is
   missing, use the Docker flow (`make docker-build`, then the
   `docker-*` targets; see `README.md` "Docker equivalents").
3. If they are untracked, commit this plan, `.cursor/hooks.json`,
   `.cursor/hooks/gc_stop_gate.py`, and the `.gitignore` entries for the
   marker files. Create `planning/gc_progress.md` from the template in §10.5
   and commit it.
4. Do the revalidation in §0.
5. Capture the baseline (gate G0) **before any RTL change**.
6. Do Phase R, the prior-art design review (§2.5, §6.3), before Phase 0.

### A.6 Session loop (every session)

1. Read `planning/gc_progress.md`: current phase, open bugs, handoff notes.
2. Take the lowest incomplete phase in §6.3. Write the failing fixture or
   check for the next step first, then implement.
3. Run that phase's inner-loop gates (listed per phase), commit, update the
   ledger.
4. At the end of every phase run `make pycore-gc-acceptance MODE=quick`. Run
   `MODE=full` at the end of Phases 2, 3, and 6, and before claiming DONE.
5. Long runs: start them in the background, poll, and do independent work
   (docs, the next fixture, reading) while they run.

### A.7 Kickoff message for the human

The plan and the hook files must be committed (and pushed, for a cloud
agent) before kickoff, so the agent's checkout has them. The marker
`.cursor/gc_task_active` is gitignored, so it is local to one machine. On a
local machine the human runs `touch .cursor/gc_task_active` in the repo root
and then sends:

> Implement garbage collection by following `planning/gc_plan.md` exactly.
> Read Part A and Part B first. I explicitly request that you create a goal:
> "Every gate in planning/gc_plan.md §10.2 passes in
> `make pycore-gc-acceptance MODE=full` on a clean tree". Do not stop until
> the DONE or BLOCKED conditions in Part A.3 hold.

In a remote or cloud environment where the human cannot create the marker,
prefix the message with: "First, run `touch .cursor/gc_task_active` and
never delete it."

To end the task early, the human deletes `.cursor/gc_task_active` or presses
stop (a stop with status `aborted` is always allowed).

---

## Part B. Orientation for a newcomer

### B.1 What this repository is

- **PyCore** (`pycore/rtl/`) is a SystemVerilog CPU whose native ISA is a
  subset of CPython 3.14 bytecode. It is multicycle and non-pipelined: one
  bytecode is in flight at a time, driven by the FSM in `pycore_core.sv`
  (search `state_next`). Container, call, closure, and raise work lives in
  sub-FSMs `included` from `pycore_cont_*.svh` and `pycore_call_fsm.svh`.
- The **operand stack** is a 256-entry register-file ring (`pycore_regfile.sv`)
  of 132-bit tagged entries `{tag[3:0], value[127:0]}`. Its live part is
  `[watermark, tos)`. A CALL that would overflow it spills a prefix to dmem at
  `0x100000`; RETURN fills it back. Call-frame descriptors are a separate dmem
  stack (`pycore_frame.sv`). Tags are listed in `README.md` and
  `pycore/docs/tags.md`.
- **Programs** are ordinary Python files. The host compiles them with CPython
  3.14; `pycore/tools/image_from_source.py` and `heap_image.py` serialise
  the resulting object graph into a dmem image (static heap objects from
  `0x440`) plus a program hex; the core boots from the boot record at
  `0x3E0`. The heap is a bump allocator today; nothing is ever freed except
  by explicit `_bi_heap_mark` / `_bi_heap_release`.
- **excore** (`excore/`) is an RV32I companion core. On the **two-core** top
  (`EXCORE_EN=1`, `pycore_excore_system.sv`) PyCore hands recoverable traps
  such as list, dict, and set growth to excore firmware
  (`excore/fw/list_grow.s`) through a mailbox (`excore/rtl/trap_mailbox.sv`).
  The **single-core** top (`pycore_system.sv`, `EXCORE_EN=0`) halts on those
  traps instead.
- **STRACC** (`pycore_str_accel.sv`) is the string accelerator. It is its own
  dmem master and allocates LONG_STR results and split pieces.
- **Memory**: 8 KB L1I, 8 KB L1D, 128 KB L2, and a RAM model with
  configurable latency. `+CACHE_EN=0` turns every cache into a pass-through;
  `+MEM_LATENCY=N` sets the RAM latency.
- **On-device compiler**: `compile()` is Python firmware
  (`pycore_firmware/`) resident in code RAM. It allocates heavily and is the
  main motivation for GC (§1.4, §5.2).

### B.2 Glossary

| Term | Meaning here |
| --- | --- |
| slot | 16 B, the 128-bit memory transaction unit. A tagged heap value is two slots: value, then tag. |
| granule | 16 B unit of the GC mark bitmap; one bit per granule (§4.2). |
| handle | a tagged value whose payload holds a heap address (§4.1 lists which tags) |
| entry | one 132-bit RF element |
| TOS, watermark | top and bottom of the live RF window |
| spill | RF prefix moved to dmem at `0x100000` |
| CODC | code-object descriptor cache (`pycore_codc.sv`): 4-entry result cache keyed by code-object address |
| GIC | global-name inline cache (`pycore_gic.sv`): 16-entry result cache keyed by `{code_addr, namei}` |
| STRACC | string accelerator |
| container op | a bytecode that runs in `S_CONTAINER` through `CP_*` phases (`pycore_cont_defs.svh`) |
| recoverable trap | a trap that excore can finish (code 9-14 and the dict update/merge codes) |
| image | the dmem hex, program hex, and `image.meta` built from one Python file |
| static image | heap objects placed by the image builder, `[0x440, HEAP_INIT_PTR)` |
| fixture | `pycore/programs/img_<name>.py` plus its `make pycore-img-<name>` target |
| golden | expected result. Normally host CPython's return value of `managed_entry()`; `# pycore-expect: <int>` overrides it when the host cannot mirror the device (`run_image_test.py`) |
| plusarg | simulation runtime option, `+NAME=value`, read with `$value$plusargs` |
| OBK_* / MUT_* | OBJECT kinds and mutable-collection kinds (`pycore_defs.svh`) |
| run | a maximal free extent found by the sweep (§4.4) |
| epoch | collection counter used to invalidate heap marks (§5.4) |
| precommit / bump-first | restartability classes of allocation sites (§1.3) |

### B.3 Commands

| Purpose | Command |
| --- | --- |
| Build the two shared simulators | `make pycore-sim-img pycore-sim-img-twocore` |
| Run one fixture | `make pycore-img-<name>`; prints `PASS: ... cycles=N` or `[FAIL]` |
| Host unit tests (includes the linter) | `make pycore-python-tests` |
| RTL unit testbenches | `make pycore-rtl-unit` |
| Single-core image suite | `make -j$(TEST_JOBS) pycore-img` |
| Two-core image suite | `make -j$(TEST_JOBS) pycore-img-two-core` |
| Cache on/off and latency gates | `make pycore-cache-transparency pycore-mem-latency-sweep` |
| Everything CI runs | `make all-tests TEST_JOBS=<cores>` |
| Heap and code-RAM occupancy | `make pycore-size-report` |

The full suite takes hours: CI splits it into jobs with 30-180 minute
timeouts (`.github/workflows/all-tests.yml`), and the `gates` job alone is
allowed 180 minutes. Both shared simulators are `pycore/tb/tb_container.sv`
compiled against the single-core and two-core tops. "Both tops" in this plan
means those two binaries.

### B.4 Adding an image fixture

1. Create `pycore/programs/img_<name>.py` with a no-argument
   `managed_entry()` that returns `int` or `bool`, and a module-level
   `managed_entry()` call at the end (copy `img_heap_mark_release.py`).
2. Add `pycore-img-<name>:` with
   `$(call PYCORE_IMAGE_RUN,<name>,<max_cycles>,<extra plusargs>)`, a
   `pycore-img-<name>-two-core: excore-fw` twin using
   `PYCORE_IMAGE_RUN_TWOCORE`, `.PHONY` entries, and membership in
   `pycore-img-gc-all` (new) which `pycore-img` and `pycore-img-two-core`
   include. Trap fixtures use `PYCORE_IMAGE_TRAP_RUN` with the expected trap
   code.
3. Programs that call `_bi_gc_*` / `_bi_heap_*` cannot be evaluated on the
   host; either give them host stand-ins in `run_image_test.py` (§4.7) or use
   `# pycore-expect:`. Prefer designs where the *program's* result is
   host-computable and the GC-specific assertions come from simulator
   counters that the acceptance runner checks.
4. Lint first: `make lint-file RUN_SOURCE=pycore/programs/img_<name>.py`.

### B.5 Conventions

- **Line numbers drift.** Every `file:line` here was right at `f5a8eb92`.
  Find code by the symbol quoted next to it (`rg -n "heap_ptr_r" pycore/rtl`),
  never by line number alone.
- Simulation-only behaviour follows the existing pattern: an `initial` block
  with `$value$plusargs` (see `HEAP_INIT_PTR=%d` in `pycore_core.sv`), and
  `$fatal(1, ...)` for checks. Every new plusarg defaults to today's
  behaviour.
- Match the surrounding code: naming (`*_r` registers, `S_*` states, `CP_*`
  phases), comment density, and the Makefile macro style.
- Keep `pycore_defs.svh` and its Python mirror `pycore/tools/encoding.py` in
  lockstep; `test_heap_image_and_constants.py` and
  `test_memory_map_mirror.py` enforce it.

### B.6 Reading order

1. `README.md`.
2. `pycore/docs/architecture.md`: memory map and object layouts (lines
   ~560-900).
3. `pycore/docs/memory_hierarchy.md` and `pycore/docs/tags.md`.
4. `pycore/docs/object_model.md`.
5. §1-§5 of this plan, opening every cited file as you go.
6. `pycore_core.sv`: the state enum, `S_FETCH`, `S_CONTAINER`, `S_CALL`,
   `S_TRAP_WAIT`, and the dmem master mux (search `stracc_dmem_active`).
7. `pycore_cont_list.svh` `BUILD_LIST` (search `CP_INIT`), `excore/docs/mmio_map.md`,
   and `do_list_grow` in `excore/fw/list_grow.s`.

---

## 0. Revalidation (do first)

This plan's [V] facts were checked on `f5a8eb92`. If your `HEAD` differs,
list what changed with
`git log --oneline f5a8eb92..HEAD -- pycore/rtl pycore/tools excore Makefile`,
re-verify every [V] row below that those commits touch, and re-verify every
`file:line` you rely on by symbol. Record discrepancies in the ledger and
update this plan in the same commit. If you rebase onto a newer `main` during
the work, redo this section and recapture the baseline (G0) from the new
merge base.

Revalidation results on `f5a8eb92`:

| Fact | Result |
| --- | --- |
| Multicycle, nonpipelined, one instruction in flight; a container handler can suspend and run Python via CALL/RETURN | **[V]** `pycore_core.sv:2143-2255` FSM; suspension via `container_call_pending_r` → `S_CALL`, resume via `S_RETURN` → `S_CONTAINER` (`:2198-2200`, `:2225-2226`) |
| 132-bit entries; heap tagged pairs occupy two 16 B slots (value then tag); no universal header | **[V]** `pycore_defs.svh` tag map; list/tuple/dict layouts in `pycore/docs/architecture.md:582-895`; TUPLE and every buffer are headerless |
| Heap `[0x440, 0xF0000)`, exc arena `0xF0000`, frames `0xF1000`, RF spill `0x100000`; some prose still says `0x1B000` | **[V]** `pycore_defs.svh:3117-3129`; stale map in `pycore/docs/architecture.md:566-569` and `:580` (`0x1BFE0`), `pycore/docs/object_model.md:112`, `planning/memory_system_plan.md:121-128` |
| Allocation split across core handlers, STRACC, excore; `heap_ptr_r` handed to both and adopted back; BUILD_TUPLE advances per slot write | **[V]** 35 write sites of `heap_ptr_r` (§1.3); STRACC `pycore_core.sv:997`, `:2923`, `:2979`; excore `:1826`, `:3470`; BUILD_TUPLE `pycore_cont_list.svh:1558,1569` |
| Placement helper packs `<64 B`, line-aligns `>=64 B`; not every firmware allocation follows it | **[V]** `pycore_defs.svh:86-93`; excore bumps raw from `MB_HEAP_PTR` with no alignment (`excore/fw/list_grow.s:288-295`) |
| Lists/dicts/sets: stable object, replaceable storage; growth in excore and PyCore bulk; old storage leaked | **[V]** `list_grow.s:25-33` ("intentionally leak"); PyCore bulk grow `pycore_cont_bulk.svh:186-199, 738-759` |
| Live memory path = 8 KB L1I / 8 KB L1D / 128 KB L2; excore at L2 via 32→128 adapter; L1D wb+inv before excore, inv before resume | **[V]** `pycore_mem_hier.sv:129-192`; `pycore_excore_system.sv:282-337`; `excore_mmio.sv:148-160` |
| Port contract: variable latency, one outstanding per master | **[V]** `pycore/docs/memory_hierarchy.md:22-25`; `pycore_cache.sv:4-8` |
| Bare `CODE_OBJECT` callables coexist with `OBK_FUNCTION` + `OBK_CELL` | **[V]** `pycore_cont_closure.svh`; `PY_OBK_CELL=7`, `PY_OBK_FUNCTION=8` (`pycore_defs.svh:166-167`); the `pycore_defs.svh:3507` comment "closures are future work" is stale |
| `_bi_heap_release` rewinds a cursor with bounds checks; code RAM has its own allocator | **[V]** `pycore_call_fsm.svh:1701-1749` (heap), `:1815-1841` (`_bi_code_alloc`), `:1751-1774` (code release) |

Additional discrepancies found: `pycore_code_mem.sv` / `pycore_code_ram.sv` /
`pycore_dmem.sv` / `pycore_mem_bank.sv` / `pycore_imem.sv` are in
`PYCORE_RTL_SRCS` (`Makefile:51-56`) but **not instantiated** under either
system top **[V]**; the live path is `pycore_mem_hier` → `pycore_ram`.
`pycore/docs/memory_hierarchy.md:44` calls L2 "inclusive" but the RTL has no
back-invalidation; inclusivity holds only by construction after the L1D
handoff writeback **[V]**.

Historical context (not on `main`): branch `cursor/memory-manager-a7b3` once
carried an excore free-list `excore/fw/mm.s`, and
`cursor/pycore-owned-allocator-plan-a7b3` proposed "PyCore allocates, excore
only fills pre-granted buffers". Neither merged. This plan adopts the
grant idea in a different form (§3.6).

---

## 1. Current implementation (assessment)

### 1.1 Memory map and capacities **[V]**

```
0x0000_03E0  boot record (96 B): module CODE_OBJECT, globals DICT, builtins DICT
0x0000_0440  PYCORE_HEAP_BASE      static image objects, then HEAP_INIT_PTR
                                   (image.meta), then runtime bump (heap_ptr_r)
0x000F_0000  PYCORE_HEAP_LIMIT     = exc-arena base (4 KB; 32 B nodes, max 128;
                                   native-method table 0xF0DE0; StopIteration
                                   sidecar 0xF0FE0)
0x000F_1000  frame stack (32 KB, 1024 x 32 B descriptors)
0x000F_9000  ---- unused (28 KB) ----
0x0010_0000  RF spill LIFO (256 KB, 8192 entries x 32 B)
0x0014_0000  ---- unused (768 KB) ----            <- GC metadata goes here [P]
0x0020_0000  DATA_LIMIT (PYCORE_DMEM_BYTES = 512 << 12)
0x0100_0000  code namespace in the unified L2 (ROM 8192 slots, RAM 65536 slots)
```

Heap capacity `0xF0000 - 0x440 = 981,952 B`. For the compiler-resident image
`img_compile_eval_expr` the static image occupies **350,464 B**, leaving
**631,488 B** of dynamic heap (`make pycore-size-report`, run on this
checkout). Code RAM: compiler package 50,028 of 65,536 slots, 15,508 free.

The 768 KB above the RF spill region is addressable (`pycore_ram.sv:28,123`
faults only at `DATA_LIMIT`) and referenced by nothing **[V]**.

### 1.2 Cache and coherence facts that constrain the design **[V]**

- L1D is write-back/write-allocate, 4-way, true LRU; L2 write-back 8-way;
  both 64 B lines (`pycore_mem_hier.sv:129-192`, `pycore_cache.sv:466-554`).
- `PYCORE_CACHE_EN=0` (`+CACHE_EN=0`) makes every cache a combinational
  pass-through (`pycore_cache.sv:273-290`) and forces CODC/GIC miss
  (`pycore_core.sv:380-388`). Any new master must obey req/ack with arbitrary
  latency.
- CODC (4 entries) caches `entry_slot, co_consts, co_names, metadata,
  co_defaults` keyed by code-object address (`pycore_codc.sv:2-17`). GIC (16)
  caches a resolved `{tag,val}` keyed by `{code_addr, namei}`
  (`pycore_gic.sv:2-16`). Both hold heap handles; both have `flush_i`
  (`pycore_core.sv:1362-1370`, `:1416-1429`).
- Excore attaches at the xbar excore port straight into L2, never L1D
  (`pycore_mem_hier.sv:5-8`). Handoff: `l1d_flush_req` (writeback+invalidate,
  walks 128 lines) before the mailbox accepts `trap_req`; `l1d_inv_req`
  (one-cycle clear) before PyCore sees `trap_res`
  (`pycore_excore_system.sv:282-337`).
- No DMA/memset/memcpy engine exists. `flush_all_i`/`inv_all_i` exist on
  `pycore_cache` but are only sequenced for L1D.

### 1.3 Allocation-site inventory **[V]**

Only two bump cursors exist: `heap_ptr_r` in the core (`pycore_core.sv:359`)
and STRACC's private copy (`pycore_str_accel.sv:102`, loaded from
`cmd_heap_ptr_i` at `:369`). OOM everywhere is `... > PYCORE_HEAP_LIMIT` →
`container_mem_fault_r` → fatal `PY_TRAP_MEM_FAULT`. No `MemoryError` is ever
raised. "Precommit" = the recoverable-trap discipline (nothing written before
the trap). "Bump-first" = cursor advanced in an early phase, RF/tos published
later; restart is only safe if nothing was committed before the bump.

| # | Producer (phase) | Site | Blocks | Size / alignment | Pointer produced | Commit point | Failure today | Restart | GC integration [P] |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Image boot | `heap_image.py:146-177`, `image_from_source.py:2849-2905` | all static objects | same `heap_place` policy as RTL (`heap_image.py:166-177`) | tagged handles in boot record, dicts, tuples | image build | build error | n/a | pinned-but-traced (§5.1) |
| 2 | `BUILD_LIST` CP_INIT | `pycore_cont_list.svh:12-43` | list obj 32 B + buf `count*32` (buf omitted when 0) | `pycore_list_place_*`; buf line-aligned | `MUT_LIST` handle; **raw** `ob_item` at obj+16 | bump at CP_INIT; RF at end | mem_fault | bump-first, no prior commit | alloc-phase abort → GC → re-dispatch (§3.4) |
| 3 | `BUILD_TUPLE` | `pycore_cont_list.svh:1514-1591` | 1 headerless array `count*32` | `heap_place`; then `+16` per slot write (`:1558,1569`) | `TUPLE{size,addr}`; **empty: addr = current `heap_ptr_r`, no bump** (`:1515-1527`) | RF at end | mem_fault | bump-first | same; canonicalise empty addr to 0 |
| 4 | `BUILD_MAP` CP_INIT | `pycore_cont_dict.svh:8-29` | obj 48 + order `slots*32` + table `slots*64` in one `pycore_dict_place_end` | order and table line-aligned | `MUT_DICT`; raw `order_ptr`,`table_ptr` at obj+32 | bump at CP_INIT | mem_fault | bump-first | same |
| 5 | `BUILD_SET` CP_INIT | `pycore_cont_dict.svh:1371-1388` | obj 32 + table `slots*32` | `pycore_set_place_*` | `MUT_SET`; raw `table_ptr` | bump at CP_INIT | mem_fault | bump-first | same |
| 6 | `BUILD_STRING`/`FORMAT_SIMPLE`/`CONVERT_VALUE` | `pycore_cont_str.svh:143-266` | 0 (SHORT_STR only, else TYPE) | — | — | — | TYPE | n/a | none |
| 7 | `LIST_APPEND` grow | `pycore_cont_list.svh:1303-1353` | 0 on PyCore | excore `new_cap*32`, `new_cap = cap?2cap:4`, **unaligned** (`list_grow.s:280-295`) | excore rewrites raw `ob_item` after copy+append (`:389-417`) | excore `RES_GO`; PyCore adopts `RES_HEAP_PTR` | excore `FATAL(MEM_FAULT)`; EXCORE_EN=0 fatal | precommit trap | grant protocol (§3.6) |
| 8 | `LIST_EXTEND` non-empty | `pycore_cont_list.svh:1488-1497`; `list_grow.s:436-771` | 0 on PyCore; excore 0 or 1 buffer | grow-to-fit doubling | same | same; self-extend snapshots `old_buf` | same | precommit trap | grant protocol |
| 9 | `LIST_TO_TUPLE` | `pycore_cont_list.svh:1626-1651` | tuple array (or empty handle, no bump) | `heap_place` | `TUPLE` | bump at CP_HDR after header read | mem_fault | bump-first | alloc-phase abort |
| 10 | `SEQ_REPEAT` / `SEQ_CONCAT` | `pycore_cont_list.svh:1823-1905`, `:2248-2285` | list obj+buf or tuple array | place helpers | `MUT_LIST` / `TUPLE` | bump before copy | mem_fault / overflow | bump-first | alloc-phase abort |
| 11 | `UNPACK_EX` starred rest | `pycore_cont_list.svh:2908-2945` | list obj+buf | `pycore_list_place_end` | `MUT_LIST` | **tos adjusted at `:2913` before bump at `:2943`** | mem_fault | **not restartable** | reorder: reserve before tos change (§3.4) |
| 12 | `GET_ITER` on SHORT_STR | `pycore_cont_list.svh:321-343` | one raw 16 B spill word | packs | `ITER` kind 3, `aux[0]=1`, `addr` → spill word | bump before ITER writeback | mem_fault | bump-first | alloc-phase abort; traversal rule in §4 |
| 13 | `GET_ITER` LIST/TUPLE/LONG_STR/DICT/SET/RANGE | `pycore_cont_list.svh:271-415` | 0 (inline hybrid) | — | `ITER` retains source | — | — | n/a | traversal only |
| 14 | `STORE_SUBSCR`/`MAP_ADD`/`STORE_ATTR` dict grow | `pycore_cont_dict.svh` ~583, ~2144; `pycore_cont_object.svh:1981-2095` | 0 on PyCore | excore order `slots*32` + table `slots*64` contiguous (`list_grow.s:1087-1116`) | excore publishes `table_ptr`,`order_ptr` after rehash (`:1301-1327`) | excore | fatal | precommit trap | grant protocol |
| 15 | `SET_ADD` grow | `pycore_cont_dict.svh:1677+`; `list_grow.s:1990-2136` | 0 on PyCore | excore table `slots*32` | excore publishes `table_ptr` **before** inserting the element (`:2121-2136`) | excore | fatal | precommit trap | grant protocol |
| 16 | `SET_UPDATE` contaminated/TUPLE (PyCore bulk) | `pycore_cont_bulk.svh:186-199` | 1 table | `heap_place(new_slots<<5)` | raw `table_ptr` | bump, then rehash into new table, then publish | mem_fault | bump-first (verify no pop before alloc) | alloc-phase abort |
| 17 | `DICT_UPDATE` contaminated (bulk) | `pycore_cont_bulk.svh:738-759` | order + table | nested `heap_end` | raw ptrs | bump then rehash | mem_fault | bump-first | alloc-phase abort |
| 18 | `DICT_MERGE` contaminated (bulk) | `pycore_cont_bulk.svh:1268-1280` | fresh dict C | `pycore_dict_place_end` | `MUT_DICT` | bump then fill | mem_fault | bump-first | alloc-phase abort |
| 19 | Uncontaminated `SET_UPDATE`/`DICT_UPDATE`/`DICT_MERGE` (kwargs shape) | `pycore_cont_bulk.svh:40+`; `list_grow.s:2246-2631` | excore: 0/1 table, or fresh dict C (obj+order+table at grant) | excore sizing `dict_calc_slots` | excore | `dict_writeback_all` | fatal | precommit trap | grant protocol |
| 20 | `MAKE_CELL` | `pycore_cont_closure.svh:7-17` | 64 B `OBK_CELL` | `heap_place` | `OBJECT` | bump at CP_INIT | mem_fault | bump-first | alloc-phase abort |
| 21 | `SET_FUNCTION_ATTRIBUTE 8` | `pycore_cont_closure.svh:283-295` | 96 B `OBK_FUNCTION` | `heap_place` | `OBJECT` | bump then fields | mem_fault | bump-first | alloc-phase abort |
| 22 | `MAKE_FUNCTION` | `pycore_core.sv:790-794` | 0 (identity) | — | `CODE_OBJECT` | — | TYPE | n/a | none |
| 23 | `RAISE` type → exception | `pycore_cont_raise.svh:75-85` | 96 B `OBK_EXCEPTION` | `heap_place` | `OBJECT` | bump before head write | mem_fault | bump-first | alloc-phase abort |
| 24 | `LOAD_ATTR` method-flag 0 bind | `pycore_cont_object.svh:1594-1616` | 96 B `OBK_BOUND_METHOD` | `heap_place` | `OBJECT` | bump then fields then RF | mem_fault | bump-first | alloc-phase abort |
| 25 | CALL `range` wide | `pycore_call_fsm.svh:1101-1109` | 96 B 3-tuple array | raw `heap_place(96)` | `RANGE` mode 1 | bump then 6 slot writes | mem_fault | bump-first | CALL budget reservation (§3.5) |
| 26 | CALL `set(...)` | `pycore_call_fsm.svh:1246-1261` | set obj + table | `pycore_set_place_*` | `MUT_SET` | bump then insert loop | mem_fault | bump-first | CALL budget |
| 27 | CALL user TYPE → INSTANCE | `pycore_call_fsm.svh:2262-2289` | dict(4 slots)+INSTANCE 64 B, one `alloc_end` | `dict_place_*` then `heap_place` | `OBJECT`; dict in field0 | single bump `:2289`; `__init__` frame after | mem_fault | bump-first | CALL budget |
| 28 | CALL exception TYPE | `pycore_call_fsm.svh:2591-2619` | EXCEPTION 96 + args tuple `argc*32` | combined | `OBJECT` + `TUPLE` | combined `alloc_end` | mem_fault | bump-first | CALL budget |
| 29 | CALL `*args` packing | `pycore_call_fsm.svh:3008-3042` | tuple `extra*32`; **empty: no bump, addr = cursor** | `heap_place` | `TUPLE` into frame local | bump when `extra>0` | mem_fault | inside binder | CALL budget |
| 30 | CALL `**kwargs` leftover dict | `pycore_call_fsm.svh:3841-3857` | full dict | `pycore_dict_place_end` | dict handle in `call_varkw_dict_r` | bump then header init | mem_fault | inside binder | CALL budget |
| 31 | `_bi_code_new` | `pycore_call_fsm.svh:2071-2085` | 256 B `CODE_OBJECT` | `heap_place` | `CODE_OBJECT` | bump then field copy | mem_fault | bump-first | CALL budget (fixed 256) |
| 32 | `_bi_heap_mark`/`_bi_heap_release` | `pycore_call_fsm.svh:1701-1749` | shrinks cursor | — | INT mark | `heap_ptr_r <= mark` | bad mark → mem_fault | n/a | epoch semantics (§5.4) |
| 33 | STRACC LONG_STR results (concat, slice, join, replace, ...) | `pycore_str_accel.sv:1036-1047`, commit `:951-966` | 1 string object `16 + pad16(nbytes)` | `pycore_heap_place` | `LONG_STR` packed handle | local bump → `res_heap_ptr_o`; core adopts on success only | `PY_TRAP_MEM_FAULT`, heap unmoved | abort semantics already | grant + NEED_HEAP abort (§3.6) |
| 34 | STRACC `partition`/`rpartition` | `pycore_str_accel.sv:2316-2359` | 3-tuple array + piece strings | `pycore_tuple_alloc_bytes(3)` | `TUPLE` | `set_res` | same | same | same |
| 35 | STRACC `split`/`rsplit`/`splitlines` | `pycore_str_accel.sv:2518-2541`, `:2724` | list obj + buf + N piece strings, allocated progressively | list place helpers; pieces via `prep_copy` | `MUT_LIST` | `set_res` at end | same | same | same |
| 36 | Exception-stack nodes | `pycore_exc_stack.sv:7-26`; `pycore_cont_exc.svh:7-17` | 32 B nodes in the 0xF0000 arena | arena SP | packed `{valid, tag, addr}` | push | `exc_push_fault` | n/a | root range, not heap |
| 37 | Frames / RF spill | `pycore_frame.sv`; `pycore_core.sv:3360-3409` | not heap | — | packed raw addresses | — | frame OOM = CALL_FILTER | n/a | root ranges |
| 38 | `bytearray` | `heap_image.py:643-684` only | image-time only; `PY_BI_BYTEARRAY` unreachable in CALL FSM (`compiler_design.md:223`) | — | `MUT_BYTEARRAY`, buffer address in **INT-tagged field1** | image | image build fails today (`Makefile:572-575`) | n/a | traversal rule only |
| 39 | TYPE objects | image only (`PYCORE_OBJ_TYPE_BYTES` unused at runtime) | — | — | `OBJECT`/`OBK_TYPE` | image | — | n/a | pinned, traced |

The excore's sizing constants live only in firmware (`list_grow.s:1087-1116`,
`:1990-2016`); PyCore does not mirror them **[V]**.

### 1.4 Firmware retention **[V]**

`compile()` (`pycore_firmware/builtins/compile.py:21-44`) sets
`_PYC_G["_busy"]`, stores `_in_src/_in_file/_in_mode`, runs
`_pyc_codegen_main` under `_bi_exec_globals`, and clears only `_busy` in
`finally`. Every compiler arena is a `_PYC_G` key (`image_from_source.py:
1428-1474`, `PACKAGE_RUNTIME_SEEDS`): `tk_*`, `nd_*`, `kids`, `opnd`, `ops`,
`ops_obj`, `stmts`, `sc_*`. Each pass **re-binds** them to fresh lists (lexer
`lexer.py:406-408`, parser `parser.py:2221-2233`, symtab `symtab.py:305-315`,
codegen `codegen.py:1389-1397`). After a compile the *latest* arrays and the
source string stay reachable through `_PYC_G`; the previous ones are garbage.
Neither a collector nor mark/release can free the latest ones.

### 1.5 Existing reclamation primitives **[V]**

`_bi_heap_mark/_bi_heap_release` (`PY_BI_*` 12/13) and `_bi_code_mark/
_bi_code_release` (14/15) are cursor rewinds with bounds checks; release
flushes CODC+GIC (`pycore_core.sv:1362-1370`, `:1416-1429`). Fixtures:
`img_heap_mark_release` (expects the same address to be handed back after a
release), `img_heap_release_stale_trap`, `img_heap_release_below_base_trap`,
`img_code_mark_release`, `img_code_release_stale_trap`, `img_compile_repeat`
(bump delta `<= 400000` after 8 compiles), `img_compile_release_realloc`. No
host stand-ins exist for the heap/code marks; those fixtures use
`# pycore-expect:`.

---

## 2. Architecture choice

### 2.1 Recommendation

**Precise, stop-the-world, non-moving mark-and-sweep**, implemented as an RTL
engine (`pycore_gc.sv` **[P]**) that is a core-side dmem master, with:

- **Extent marking**: the mark bitmap has one bit per 16 B granule and marking
  sets **every granule of a live allocation**, so the sweep needs no
  allocation headers and no block-start table: runs of zero bits are free.
- **Bump-into-runs allocation** (Immix-style holes): the existing
  `heap_ptr_r` bump stays as the common path, bounded by a new
  `heap_limit_r`; when the current run is exhausted the allocator pops the
  next free run from a list built by the sweep. Common-path cost is unchanged.
- **Grants** for the two external allocators (STRACC, excore): they bump
  inside `[heap_ptr_r, heap_limit_r)` and report `NEED_HEAP(n)` instead of
  faulting.
- **Collection only at instruction boundaries**, entered by aborting the
  allocating instruction before its first architectural commit and
  re-dispatching it after the collection (the existing `RETRY` redirect).
  CALL reserves its whole budget up front instead of aborting mid-binder.

### 2.2 Alternatives

| Property | Non-moving mark-sweep (recommended) | Copying / compacting | Reference counting + cycle collector |
| --- | --- | --- | --- |
| Stable handles (LIST/DICT/SET/OBJECT addresses are identity; `ob_item`, `table_ptr`, `order_ptr`, frame `cur_code`/`globals`/`saved_instance`, exc-node `addr`, STRACC handle `addr`, CODC/GIC keys, `cur_code_r`, `globals_base_r`, excore mailbox copies) | kept | every one must be rewritten; frame and exc packing are raw fields; excore mailbox copies and `SCR_*` scratch too | kept |
| Address-based OBJECT hashing (identity keys, `tags.md:39-42`) | unaffected | every contaminated dict/set must be rehashed | unaffected |
| Untagged pointer fields (`ob_item`, dict/set ptrs, bytearray INT field, frame slots) | read only | read and rewritten | read only |
| Heap space | 981,952 B total; static image pins up to ~350 KB; no reserve needed | needs a to-space reserve: halves the ~631 KB dynamic region | none extra, but counts need a header: +16 B per object (≥ +50% for 32 B list/set objects, +100% for 16 B spill words) |
| Fragmentation | yes (§4.6 scenarios) | none | yes, plus header overhead |
| Metadata traffic | 1 bitmap RMW per pushed object + 1 per 2 KB of extent; sweep reads 8 KB | copy every live byte | RMW on **every** reference copy: RF push/pop, spill/fill, container writes, excore copies; on a 128-bit port that doubles the memory traffic of most opcodes |
| Pause | full mark+sweep, [A] §6.5 | full copy | incremental, but cycle collection is still a full trace |
| Mutator overhead | zero on the common path (compare against `heap_limit_r` instead of a constant) | zero, but every pointer load must tolerate relocation between GCs | audit of every reference copy/removal including borrowed loads (`LOAD_FAST_BORROW`, `COPY`, `SWAP`), RF ring stale slots, spill, `container_call_saved_*`; still needs the tracer for cycles (closures, instance ↔ dict, self-referential lists) |
| Verdict | **choose** | reject: needs every raw pointer site and both external allocators to be relocation-aware | reject: CPython's model is not appropriate here just because the ISA is CPython bytecode |

### 2.3 Where each function runs

| Function | Where | Why |
| --- | --- | --- |
| Allocation (common path) | core RTL, unchanged bump | 0 added cycles |
| Allocation (run switch) | core RTL (`S_GC_ALLOC` sub-FSM **[P]**) | one 16 B free-header read per candidate run |
| Root enumeration | core RTL streams register roots and RF ring; engine reads spill/frames/exc/boot/native table from dmem | RF is not memory-mapped; only the core knows `rf_wm_r`/`tos_r` and the suspended-container set |
| Graph traversal | `pycore_gc.sv` engine | see excore cost below |
| Sweep | `pycore_gc.sv` engine | linear over the 8 KB bitmap |
| Excore / STRACC | clients: bump inside a grant, report `NEED_HEAP` | no size-formula mirroring in RTL; no firmware allocator |

Excore as a marker was rejected on cost **[A]**: one 128-bit slot read from
firmware is `sw SP_ADDR; li; sw SP_CTRL; (lw SP_STATUS; andi; bne)×≥1; 4× lw`
≈ 11-13 RV32I instructions on a 5-stage multicycle hart (`riscv_multicycle.sv`)
≈ 60-90 cycles, versus ≈ 2-3 cycles for an RTL master on an L1D/L2 hit. A live
heap of 600 KB is ~38k slots: ≈ 2.5-3.5 M cycles per collection in firmware
versus ≈ 0.1-0.3 M in RTL, and firmware marking would leave `EXCORE_EN=0`
(the `pycore-img` production path) without a collector. Firmware capacity
would have allowed it (9,168 of 16,384 B IMEM used; 1 KB scratch; RV32I only,
no MUL, no `.data` — `asm_rv32.py`) **[V]**.

PyCore firmware (Python) never allocates during a collection: the collector is
RTL, and the mutator is frozen in `S_GC`. The only firmware that runs *near*
collection is the `compile()` cleanup (§5.2), which is written to be
allocation-free.

### 2.4 Configuration boundary

- `GC_EN` parameter + `+GC_EN=` plusarg **[P]**, default 0 until Phase 3 flips
  it. `GC_EN=0` is byte-for-byte today's behaviour (bump, constant
  `PYCORE_HEAP_LIMIT`, exact mark/release).
- `EXCORE_EN=0`: fully supported from Phase 2 (all PyCore + STRACC sites).
- `EXCORE_EN=1`: supported from Phase 3 (grant protocol). Between Phase 2 and
  3 the two-core simulator runs with `+GC_EN=0`; the Makefile arm enforces it
  and a directed test asserts the firmware still sees the constant limit.

### 2.5 Prior art: full-hardware mark-sweep collectors, and what to adopt

The design in §3-§5 was drafted from first principles. A great implementation
must be checked against the collectors that have actually been built in
hardware. Phase R (§6.3) requires you to read the sources below and record a
decision for every row of the adoption table.

**Sources** (all verified to exist; PDFs are public):

| System | What it is | Mechanisms that matter here |
| --- | --- | --- |
| Bacon, Cheng, Shukla, *And Then There Were None: A Stall-Free Real-Time Garbage Collector for Reconfigurable Hardware*, PLDI 2012; extended in CACM 56(12), 2013 | First complete GC in hardware: Verilog on an FPGA, in both stop-the-world and concurrent (snapshot-at-the-beginning, Yuasa write barrier) variants, over on-chip BRAM heaps of fixed-shape objects | Mark Map (one bit per object) in BRAM; mark queue; the **sweep is a linear scan that clears mark bits as it goes**, so there is no separate clear phase; a free stack; a root snapshot engine. Their concurrent collector beat stop-the-world on every axis, but that depended on the heap living in the collector's own BRAMs, where read-before-write ports make the write barrier nearly free |
| Maas, Asanović, Kubiatowicz, *A Hardware Accelerator for Tracing Garbage Collection*, ISCA 2018 (IEEE Micro Top Picks 2019; Maas PhD thesis UCB/EECS-2018-152) | RTL mark and sweep units in a RocketChip RISC-V SoC doing stop-the-world GC for JikesRVM on an FPGA; mark phase 4.2x an in-order CPU at 18.5% of its area | **Marker and Tracer decoupled by queues**; **on-chip mark queue that spills to and refills from memory** (`inQ`/`outQ`) only when full; **mark-bit cache**; compression of queue entries to 32 bits; software writes roots into a memory region that the unit reads; order-free ("untagged") reference fetches to keep many requests in flight; parallel block sweepers |
| Ramsay, Stewart, *Cloaca: A Concurrent Hardware Garbage Collector for Non-strict Functional Languages*, Haskell Symposium 2024 | FPGA concurrent mark-sweep plus one-bit reference counting for a graph-reduction machine, written in Clash | Two-stage read/write pipelines at one address per cycle; **verified with property-based tests of three invariants checked every cycle**: free-list consistency, free set disjoint from the reachable set, and every dead address reclaimed within a bounded number of passes |
| SHAP Java processor (Zabel, Preußer, Reichel, Spallek; TU Dresden, 2007-2010) | Embedded bytecode processor with a hardware GC module; exact and concurrent; mark-and-sweep in the early design, mark-and-copy on segmented memory later | Per-core root-scan units that collect register and stack references into a mark table: the same "the core enumerates its own roots" split as §3.3 |
| Blackburn, McKinley, *Immix*, PLDI 2008 | Software mark-region collector | Bump allocation into holes; lazy sweeping |
| Jones, Hosking, Moss, *The Garbage Collection Handbook*, 2nd ed., 2023 | Reference text | Bitmap marking, mark-stack overflow handling, lazy sweeping, heap verification |

The Maas RTL is not public, and Reduceron (open Verilog) uses a copying
collector, so no directly reusable mark-sweep RTL exists. Adapt the ideas,
not code.

**Adoption table.** "Default" is what you implement if a measurement is
inconclusive. "Evaluate" rows are decided by the G13 micro-benchmarks at the
end of Phase 2, with numbers recorded in `pycore/docs/gc.md`.

| Idea | Source | Fit with PyCore | Default |
| --- | --- | --- | --- |
| Small on-chip mark stack (for example 64 entries of 36 bits: tag plus 32-bit address) that spills to and refills from the 512 KB region in §4.3 only on overflow or underflow | Maas (mark-queue spilling, entry compression) | §4.5 as drafted makes every push and pop a dmem transaction, roughly doubling mark-phase traffic | **adopt** |
| Bitmap-slot cache: keep the current 128-bit bitmap slot in a register and write it back only when the slot changes or the phase ends | Maas (mark-bit cache) | Extent marks of adjacent objects hit the same slot, which turns most read-modify-writes into register updates | **adopt** |
| Sweep clears the bitmap as it scans, which removes the `CLEAR` phase | Bacon | The sweep reads every bitmap slot anyway; it writes zero back only for nonzero slots, including the pinned static range below `heap_dyn_base`. The first collection after reset still needs a clear, because RAM contents are not guaranteed. With this adopted, the oracle checks the run list (the sweep's output), not a post-sweep bitmap | **adopt** |
| Whole bitmap (7.5 KB) in on-chip SRAM instead of dmem | Bacon (Mark Map in BRAM) | Single-cycle marks and no cache pollution, at the cost of area and a TB-side dump path for the oracle | **evaluate**; default is dmem plus the slot cache |
| Decoupled marker and tracer | Maas | Our port contract allows one outstanding request per master (`pycore/docs/memory_hierarchy.md`), so the win is limited to overlapping next-address work with the in-flight request. G13 P3 requires the engine to issue its next request in the cycle after each ack | **adopt the issue discipline**; full decoupling is out of scope |
| Lazy sweeping: the allocator scans the bitmap for the next hole on demand, so the pause is mark-only | Immix | Shorter pauses, but it moves bitmap scanning into `ensure_run` and complicates the oracle | **evaluate**; default is an eager sweep |
| Root region in memory that the unit reads | Maas | This is `GC_ROOT_STASH` in §3.3 | already adopted |
| Concurrent collection with a snapshot write barrier | Bacon, Cloaca | Needs a barrier at every pointer-store site: dozens of RTL sites, STRACC, and excore firmware | **reject** for v1, and state why in `gc.md` |
| Bidirectional object layout (references on one side of the header) | Maas | Object layouts are fixed by the image format, `encoding.py`, and excore firmware | **reject** |
| Cloaca's three invariants as executable checks | Cloaca | They map directly onto G4, G5, G6, and G11 | **adopt** (§10) |

---

## 3. Roots and safe points

### 3.1 Root table

Validity is stated at the collection point (§3.3). "Derived" means reachable
from another root, so scanning it is optional.

| Root | Storage | Representation | Valid when | Enumeration | Owner | Scan? |
| --- | --- | --- | --- | --- | --- | --- |
| RF resident ring `[rf_wm_r, tos_r)` with wrap | `pycore_regfile.sv:37` (`rf[0:255]`) | tagged 132-bit | always; `tos==wm` empty (`pycore_core.sv:204-207`, `:1642-1673`) | core streams entries through the rs1 override port (`container_rf_addr_r` mechanism) one per cycle **[P]** | core | **must** |
| RF spill prefix `[0x100000, spill_sp_r)` | dmem | value slot then tag slot, 32 B per entry (`pycore_core.sv:3360-3383`) | always | engine range walk (2 slots/entry) | core (`spill_sp_r`) | **must**; nothing above `spill_sp_r` |
| Frame descriptors `[0xF1000, frame tail)` | dmem | slot1: `cur_code[31:0]`, `ret_discard_push_self[32]`, `saved_instance_addr[96:33]`, `globals_base[127:97]` (`pycore_frame.sv:7-21`) | depth = `frame_active_depth` | engine range walk, 1 slot/frame, decode packing | `pycore_frame` | **must**: caller code objects, caller globals dicts, constructor instance (trace when nonzero **[?]** verify push zeroes it) |
| `cur_code_r` | `pycore_core.sv:228` | raw CODE addr | after boot | register root | core | **must** (module code is also in boot record; callee code may be otherwise dead) |
| `globals_base_r`, `builtins_base_r` | `:243-244` | raw DICT addr | after boot | register roots | core | **must** (`_bi_exec_globals` can point at a heap dict) |
| `consts_base_r`, `names_base_r` | `:236-237` | TUPLE val | running | — | core | derived from `cur_code_r` |
| `cur_closure_r` | `:232` | TUPLE val | nonzero only between CALL of an `OBK_FUNCTION` and the callee's `COPY_FREE_VARS` (`pycore_call_fsm.svh:4580`, `:69`) | register root when nonzero | core | **must** (the FUNCTION object may already be popped) |
| Boot record `0x3E0` | dmem | 3 tagged handles | static | engine fixed range | image | static roots |
| Native-method sidecar `0xF0DE0` (16 × 32 B) | dmem | tagged CODE_OBJECT handles; STRACC sentinels `0xFFFF00xx` (`pycore_defs.svh:2113-2128`) | static | engine fixed range; skip `pycore_is_stracc_method_code` | image | static roots |
| StopIteration sidecar `0xF0FE0` / `iter_exhaust_type_r` | dmem / `:603` | tagged OBJECT | static | fixed range | image | derived from builtins dict; include (cheap) |
| `active_exc_r` | `:601-602` | tagged OBJECT | `active_exc_valid_r` | register root | core | **must** |
| Exception stack `[0xF0000, exc_sp)` | dmem | slot1 `{valid[127], tag[123:120], addr[63:0]}` (`pycore_exc_stack.sv:156-180`) | depth ≤ 128 | engine range walk | `pycore_exc_stack` | **must** |
| `call_exc_handle_r` | `:416` | tagged | `call_exc_pending_r` | register root | core | **must** when pending |
| `raise_type_entry_r` | `:427` | tagged | mid-`CONT_RAISE` only | — | core | dead at boundary |
| Suspended container call: `container_call_saved_rs1_r`, `saved_rs2_r`, `container_proto_iter_r` | `:404-425` | tagged | `container_call_active_r` | register roots | core | **must** when active (e.g. FOR_ITER over a `__next__` object: the outer iterator) |
| `container_call_result_r` | `:469` | tagged | `container_call_return_valid_r` (written as the protocol CALL deactivates) | register root | core | **must** until the resumed arm consumes it. **Superseded:** "root result while `active`". Evidence: G7 (b) `img_for_iter_object_nested` collection 60: `active=1` still held the previous `__iter__` list at a swept address → `wild_ptr` (`len=19156992`) |
| `container_call_saved_{op,phase,opcode,arg,pc,tos}` | `:406-411` | non-pointer | active | — | core | not pointers |
| `rs1_r`, `rs2_r`, `ex_entry_r`, `wb_entry_r` | `:195-201` | tagged | stale after retire | — | core | dead at boundary (re-decoded) |
| Binder scratch `call_*_r`, `call_varkw_dict_r`, partial objects `container_*_r` | `:272-546` | mixed | mid-CALL / mid-container | — | core | dead at boundary by construction (§3.4-3.5) |
| STRACC internal regs, `stracc_item_r`, `stracc_call_*_r` | `pycore_str_accel.sv:100-172`, core `:973-985` | mixed | `S_STRACC` | — | STRACC | dead at boundary (abort semantics) |
| `trap_marshal_entries_r`, `trap_res_entries_r2`, mailbox latches, excore GPRs/scratch | `:559,570`; `trap_mailbox.sv`; excore | tagged copies | trap in flight | — | core / excore | never collected while excore owns memory; on `NEED_HEAP` the entries are copies of RF operands that are re-marshalled on re-dispatch |
| CODC / GIC payloads | `pycore_codc.sv:52-54`, `pycore_gic.sv:49-51` | heap handles | cache valid | — | core | **flush** at every collection (existing `flush_i`) |
| `_PYC_G` and compiler arrays | heap | dict | always | via builtins dict | image | derived; retention fixed in firmware (§5.2) |
| GC metadata (bitmap, mark stack, free headers) | `[0x140000, 0x200000)` and inside free runs | raw | always | — | engine | outside the managed heap; never traced |

Stale physical RF slots below the watermark or above `tos_r` are not
architecturally live and are not scanned **[V]** (`pycore_core.sv:1655-1673`).

### 3.2 Why the instruction boundary is a real safe point **[V]**

- Every RF write pulse (`wb_we_r`, `container_wb_we_r`, `return_wb_we_r`,
  `rf_fill_we_r`) drives `rf_we` in the same cycle it is high and is
  default-cleared (`pycore_core.sv:1457-1467`, `:2533-2537`). Container work
  commits in the cycle that sets `CP_DONE`; `CP_DONE` itself is empty
  (`pycore_cont_defs.svh:79`). `S_TRAP_WAIT` finishes its push sequence before
  `trap_wait_ready`. So in the first `S_FETCH` cycle `rf_we == 0` and `tos_r`
  is final.
- No dmem master is active in `S_FETCH`: `container_dmem_active`,
  `frame_dmem_active`, `rf_spill_dmem_active`, `stracc_dmem_active`,
  `exc_dmem_active`, `ms_dmem_req` are all state-gated (`:1584-1606`). Only
  the fetch unit may have an **imem** request outstanding; it is frozen by
  `stall` while the core is elsewhere.
- A bytecode boundary inside a protocol callee (`__next__`, `__iter__`,
  `__init__`, `__len__`) still has the outer operation suspended in the
  `container_call_*` register bank; the roots above cover it. Suspension is
  single-level (one register bank), which the current RTL already requires.

### 3.3 Entry / drain / capture / collect / resume protocol **[P]**

New core states `S_GC_ENTER`, `S_GC_ROOTS`, `S_GC_RUN`, `S_GC_ALLOC` (values
after `S_CODE_WRITE`; `state_r` widens if needed).

1. **Request.** Any allocation site that cannot be satisfied sets
   `gc_req_r <= 1`, `gc_need_bytes_r <= n`, `gc_req_pc_r <= cur_pc_r`, and
   the owning FSM takes its **abort exit** (§3.4) instead of committing.
   Sites reached from `S_CONTAINER`, `S_CALL`, `S_STRACC`, `S_TRAP_WAIT` all
   converge on `state_next = S_GC_ENTER`.
2. **Drain.** `S_GC_ENTER` waits until no `*_dmem_pending_r` is set, STRACC is
   idle (`!stracc_dmem_active`), and (EXCORE_EN) `mem_owner == PYCORE` (always
   true when entered from `S_TRAP_WAIT` after the `trap_res` handshake, which
   already invalidated L1D). Then it clears the mark bitmap (480 slot writes)
   and resets the mark-stack pointer.
3. **Capture.** `S_GC_ROOTS` streams register roots into the engine's
   `root_valid/root_entry` port, in a fixed order: `cur_code_r`,
   `globals_base_r`, `builtins_base_r`, `cur_closure_r` (if nonzero),
   `active_exc_r` (if valid), `call_exc_handle_r` (if pending),
   `container_call_saved_rs1_r`/`rs2_r`/`result_r`/`proto_iter_r` (if
   `container_call_active_r`), `iter_exhaust_type_r`; then the RF ring one
   entry per cycle via the rs1 override port. Each entry is also written to
   `GC_ROOT_STASH` (16 KB at `0x142000`, preceded by a count word) so a host
   oracle can check the root set from a dmem dump. Size: at most 256 RF
   entries plus 12 register roots, 32 B each (value slot, tag slot), is
   8,576 B. A 1 KB stash (32 roots) would silently truncate the RF ring. The
   stash write is simulation-only work (`+GC_ROOT_STASH=1`, on in every gate
   run) so it does not count against the pause targets.
4. **Collect.** `S_GC_RUN` asserts `gc_start`; the engine (§4.5) walks the
   memory root ranges (spill, frames, exc stack, boot record, native table,
   StopIteration sidecar), marks, then sweeps and rebuilds the run list. The
   core meanwhile pulses `codc_flush`/`gic_flush`. The engine reports
   `gc_done`, `gc_live_bytes`, `gc_free_bytes`, `gc_largest_run`.
5. **Resume.** `S_GC_ALLOC` tries `ensure_run(gc_need_bytes_r)` (§4.4). On
   success: `redirect_pending_r <= 1; redirect_tgt_r <= gc_req_pc_r;
   fetch_skip_r <= 0;` → `S_FETCH` (same mechanism as `TRAP_RES_RETRY`,
   `pycore_core.sv:3491-3497`). **Superseded (implementation):** a redirect
   to `cur_pc_r` loses any `EXTENDED_ARG` prefix, because fetch reports the
   pc of the final opcode. Fetch is stalled for the whole instruction and
   still presents it, so re-dispatch is `fetch_skip_r <= 0` alone: the next
   `S_FETCH` cycle re-latches the held instruction with its folded argument
   (ledger, "Plan deviations"). On failure: raise `PY_TRAP_MEM_FAULT` in v1;
   Phase 5 seeds `MemoryError` and routes through the existing
   `container_raise_trap_r` path so `except MemoryError` works.
6. **Loop guard.** `gc_retry_count_r` counts consecutive re-dispatches of the
   same pc that request a collection; the second collection with
   `gc_largest_run` unchanged is an immediate OOM. No instruction can collect
   more than twice without making progress.
   **Superseded (implementation):** `+GC_EVERY_N_RUNS=1` collects at every
   run switch, including each NEED_HEAP grant of a multi-allocation
   instruction (STRACC `split`). The second collection at the same pc with
   unchanged largest is not true OOM when `gc_largest_run >= need + 64` —
   `ensure_run` can still install a fitting run and the instruction makes
   progress. The guard fires only when the largest run still cannot satisfy
   the request. Evidence: `img_gc_stracc_split` at `HEAP_DYN_BYTES=40960` +
   `EVERY_N_RUNS=1` collected twice at pc 162 with largest 35728 and trapped
   7 before the refinement; after, 5 collections and PASS `0x60e`.

An explicit collection (`_bi_gc_collect()`, §4.7) uses the same path with
`gc_need_bytes_r = 0`, resuming at the **next** pc (it is a completed CALL,
not an aborted one).

### 3.4 Collection point choice and per-site discipline

Chosen: **verified instruction boundaries only**, reached by aborting the
allocating instruction before any commit. Rejected alternatives: collecting
at allocation suspension points would require rooting every mid-instruction
temporary (binder scratch, half-built objects, STRACC engine registers, excore
scratch) — dozens of registers across four modules with no uniform encoding;
reserving budgets everywhere is impossible for STRACC `split` (piece count
unknown until scanned) and for excore's data-dependent sizing without
mirroring firmware formulas in RTL.

Per-site rule **[P]**: every RTL allocation must occur in a phase that has
issued no RF write, no `tos_r` change, no dmem write, no frame push, and no
`heap_ptr_r` advance. The inventory shows this already holds for #2-5, 9-10,
12, 16-18 (verify no pop before the bump), 20-21, 23-24. Required fixes:

- **#11 `UNPACK_EX`** (as built: the capacity check at `CP_SRC_HDR` already
  precedes the `tos` change, so the abort exits from the check; no reorder):
  move the list allocation ahead of the `tos` adjustment
  at `pycore_cont_list.svh:2913`.
- **Multi-allocation instructions** (#4, 27, 28, 35) already allocate one
  contiguous extent, so one `ensure_run` covers them. STRACC `split` (#35)
  allocates progressively; it keeps its abort semantics (heap unmoved on
  failure, `tb_str_accel.sv` OOM test) and reports how much it needed.
- **Unexpectedly large requests** (e.g. `[0] * 100000` = 3.2 MB) exceed the
  heap: `ensure_run` fails before and after collection → OOM, no loop.

### 3.5 CALL: reserve the budget before the frame push

CALL mutates early (RF spill in phase 7, frame push, binder writes above
`tos`), so it cannot abort late. Instead, a new binder phase before phase 7
computes an **upper bound** from already-decoded operands and calls
`ensure_run(budget)` **[P]**:

| Callable shape | Budget |
| --- | --- |
| `CODE_OBJECT` / `OBK_FUNCTION` with `CO_VARARGS` | `argc*32 + 64` (pad) |
| ... with `CO_VARKEYWORDS` | `+ dict_bytes(next_pow2(max(4, 2*nkw)))` = `48+16+slots*32+slots*64` |
| user `OBK_TYPE` (INSTANCE) | `48+16+128+256+64 = 512` |
| exception `OBK_TYPE` | `96 + argc*32 + 64` |
| `BI_RANGE` | `96`; `BI_SET(iterable)` | `32 + 64 + next_pow2(max(4,2*len))*32` (len from the source header, read-only) |
| `_bi_code_new` | `256 + 64` |
| others | 0 |

If the budget cannot be reserved, CALL aborts at that phase (nothing committed
yet) via §3.3. Later allocations inside the same CALL then bump inside the
reserved run and cannot fail. The reservation is an upper bound; unused bytes
are simply not consumed.

**As built (implementation; ledger "Plan deviations").** CALL's prelude
commits before phase 6 (bound-method unwrap writes `self` over the NULL slot,
`KW_NAMES` pops the names tuple, `CALL_FUNCTION_EX` pops its operands), and
several allocations happen there (instance, exception, `range`, `set`,
`_bi_code_new`). So each pre-binder allocation aborts on its own:
`CALL_PHASE_GC_UNWIND` replays an undo record (restore the NULL slot,
re-push the names tuple, rewrite the `*args`/`**kwargs` operands), then takes
the common abort path. Phase 6 reserves only the binder's allocations
(`*args` tuple `+64`, `**kwargs` dict `+64`, `n_kw` of a `**` dict from its
`order_len`, read only when the current run is below 17,408 bytes). A binder
allocation that fails after the reservation is a `[GC-INV]` fatal. A CALL
launched by a container protocol call cannot be undone and stays
`PY_TRAP_MEM_FAULT` on allocation failure (known ceiling).

### 3.6 STRACC and excore: grants and `NEED_HEAP`

**STRACC [P]**: add `cmd_heap_limit_i` (= `heap_limit_r`) next to
`cmd_heap_ptr_i`; every internal OOM check compares against it instead of
`PYCORE_HEAP_LIMIT`. On overflow the accelerator finishes with a new result
`res_need_heap_o = 1`, `res_need_bytes_o = bytes it had bumped + bytes for the
failing piece`, heap unmoved (today's abort path). The core converts that
into a GC request with `gc_need_bytes_r = res_need_bytes_o` (at least the
bytes bumped so far) and re-dispatches the instruction. Since STRACC results
are published only in `set_res`, no partially published object exists.

**Excore [P]**: mailbox gains `MB_HEAP_LIMIT` (offset `0x1C`, currently free
in `excore/docs/mmio_map.md`) driven from `heap_limit_r`; `trap_mailbox.sv`
and `excore_mmio.sv` add the word. Firmware replaces the five
`li t1, HEAP_LIMIT` checks (`list_grow.s:293, 550, 1119, 2019, 2395`) with
`lw t1, MB_HEAP_LIMIT(s11)` and, on failure, jumps to a new `res_need_heap`
routine: `RES_CODE = 3 (NEED_HEAP)`, `RES_HEAP_PTR = bytes needed`,
`pop=push=0`, `RES_GO`. All five checks precede the handler's first slot
write **[V]** (`do_list_grow` first write `:325`, `do_list_extend` `:579`;
`dgr_alloc`/`sgr_alloc` run before their rehash loops; `do_dict_merge`
allocates C first), so nothing is mutated. PyCore's `S_TRAP_WAIT` handles code
3 like `RETRY` but goes through `S_GC_ENTER` with
`gc_need_bytes_r = trap_res_heap_ptr_i`. After re-dispatch the container op
re-detects the condition and re-marshals with the new grant. Old buffers are
**not** freed eagerly; they are unreachable after the pointer rewrite and are
reclaimed by the next collection. This preserves the self-extend alias case
(`ext_src_self`, `list_grow.s:516`) without firmware changes.

`RES_HEAP_PTR` on `COMPLETED` keeps its meaning (new `heap_ptr_r`), and PyCore
additionally asserts `RES_HEAP_PTR <= heap_limit_r` (`$fatal` in simulation,
`MEM_FAULT` in hardware) to catch firmware sizing bugs.

Note **[V]**: current firmware returns only `COMPLETED` or `FATAL`; no handler
emits `RETRY` (no `RES_RETRY` symbol exists in `excore/`). PyCore's
same-pc re-dispatch (`pycore_core.sv:3491-3497`) is therefore unexercised by
real firmware today, and `NEED_HEAP` will be the first result code to use it.
Phase 3 must include a mocked-mailbox test of the re-dispatch path itself
(operands re-marshalled identically, `tos_r` unchanged, no double pop) before
the firmware change lands.

Excore does not line-align inside the grant (`list_grow.s:288`). Because the
collector works in 16 B granules, this is a cache-line performance nit, not a
correctness issue; leave it.

---

## 4. Allocation metadata and traversal

### 4.1 Layout / traversal table

Pointer-bearing tags and where the address lives **[V]** (`pycore_defs.svh`,
`encoding.py`, `heap_image.py`):

| Handle | Address bits | Heap object | Extent (bytes) | Children to trace | Validity / exclusions |
| --- | --- | --- | --- | --- | --- |
| CONTROL, INT, FLOAT, COMPLEX, BOOL, SHORT_STR, TOMBSTONE, BYTES, FROZENSET | none | — | — | — | non-pointers; BYTES/FROZENSET reserved → treat as non-pointer, count in `gc_reserved_tag_seen` |
| LONG_STR | `v[31:0]` | header 16 B + payload | `16 + pad16(nbytes)`, `nbytes = v[119:96]` | none (raw code units) | leaf: mark extent, never push, never scan bytes |
| TUPLE | `v[63:0]` iff `size = v[127:64] > 0` | headerless array | `size*32` | elements `0..size-1` (tag slot at `+32i+16`) | `size==0`: no allocation, addr ignored |
| MUT_LIST | `v[63:0]` | 32 B object | 32 | none directly; raw `ob_item` at obj+16 → buffer extent `capacity*32`, trace elements `0..length-1` only | `ob_item==0` when `cap==0` |
| MUT_DICT | `v[63:0]` | 48 B object | 48 | raw `order_ptr`/`table_ptr` at obj+32; order extent `slot_count*32`, trace `0..order_len-1`; table extent `slot_count*64`; for each slot read key tag: skip if key tag word is `0` (UNINIT-empty) or `TOMBSTONE`; else trace key and value | `None` key is `CONTROL` with ctl nibble `NONE` in the tag word — **not** empty; deleted values are excluded because the whole slot is skipped |
| MUT_SET | `v[63:0]` | 32 B object | 32 | raw `table_ptr` at obj+16; table extent `slot_count*32`; skip empty/tombstone | |
| MUT_BYTEARRAY | `v[63:0]` | 128 B object (legacy `OBK_BYTEARRAY` fields) | 128 | field1 is INT-tagged `buf_addr`, field2 INT `capacity`: mark raw `[buf_addr, buf_addr+pad16(capacity))`, no scan | only this field is treated as a pointer; arbitrary INT values elsewhere never are |
| OBJECT | `v[63:0]` | header at +0 (`ob_kind[127:96]`, `ob_flags`, `ob_type[63:0]`), self-tag at +16, fields at `+32+32i` | by kind: INSTANCE 64, TYPE 128, BOUND_METHOD 96, BUILTIN 96, BYTEARRAY 128, EXCEPTION 96, CELL 64, FUNCTION 96 | `ob_type` if nonzero (as OBJECT); INSTANCE f0 `__dict__`; TYPE f0 `tp_dict`, f1 `tp_base`, f2 `tp_name`; BOUND_METHOD f0/f1; BUILTIN f1 `bound_self`; EXCEPTION f0 `exc_type`, f1 `args`; CELL f0; FUNCTION f0 code, f1 closure tuple | unknown `ob_kind` → `gc_bad_kind` counter + fatal in simulation |
| CODE_OBJECT | `v[63:0]` | 256 B, 8 tagged fields | 256 | fields 1,2,4,5,6,7 (tuples/dict); fields 0 (`entry_slot`) and 3 (metadata) are INT, never dereferenced | skip if `pycore_is_stracc_method_code(addr)` (`0xFFFF00xx`) |
| RANGE | mode `v[127]`: 1 → `v[63:0]` | 3-element tuple array | 96 | as TUPLE{3, addr} | mode 0 inline |
| ITER (`magic 0xA5`, kind `v[119:116]`) | `v[31:0]` | kind 0 LIST → list object; 1 TUPLE → element array with `size=v[63:32]`; 2 RANGE → none (`addr` must be 0); 3 STR → `addr==0`: empty SHORT_STR, no heap object (G7 (b) `img_for_iter_str_empty` wild_ptr); `aux[0]=1`: raw 16 B spill word, else LONG_STR object (size from its header); 4 HEAP_ITER → OBJECT; 5 DICT / 6 SET → object | per target | per target | unknown kind → counter + fatal in simulation |
| Frame slot1 (raw) | `[31:0]` code, `[96:33]` instance, `[127:97]` globals | — | — | as CODE_OBJECT / OBJECT / MUT_DICT | root range only |
| Exc node slot1 (raw) | `{valid[127], tag[123:120], addr[63:0]}` | — | — | as tagged | root range only |

Everything that is *not* in this table is bytes: string payloads, bytearray
buffers, spill words, list capacity beyond `length`, dict/set empty slots,
INT/FLOAT payloads, `entry_slot`, LONG_STR `nchars/hash/nbytes`, ITER
`index/size/aux`, MUT kind/contamination bits.

### 4.2 Metadata: external bitmap versus intrusive headers

| | External extent bitmap (chosen) | Intrusive 16 B header before every block |
| --- | --- | --- |
| Space | 61,372 granules → 7,672 B (round to 8 KB) | +16 B per allocation: 32 B list/set objects → +50%; 16 B spill words → +100%; image grows accordingly |
| Allocation cost | none (no metadata write) | one extra slot write per allocation, in RTL, STRACC, excore and the image builder |
| Layout impact | none; image byte-identical; `heap_image.py` untouched | every `*_place_*` helper, `encoding.py` mirror, image builder, `list_grow.s`, STRACC, and every fixture golden that depends on addresses |
| Extent recovery for headerless buffers | from the owning object (`capacity`, `slot_count`, handle `size`, `nbytes`) — verified derivable for every kind (§4.1; order buffer = `slot_count*32` in `heap_image.py:315`, `pycore_dict_place_table`, `list_grow.s:1114-1116`) | header carries size |
| Sweep | linear over 8 KB of bits | linear over headers |
| Failure mode | a wrong extent formula under-marks → later reuse corrupts; caught by the host oracle differential (§6.3) | header corruption by a stray write |

Bitmap semantics: bit `g` set ⇔ granule `g` (address `0x440 + 16g`) belongs to
a live allocation at the end of marking. Bits for `[0x440, HEAP_INIT_PTR)`
are set during marking like any other but the sweep treats that range as
permanently live (§5.1).

### 4.3 Metadata map **[P]** (`pycore_defs.svh` + `encoding.py` mirror)

```
PYCORE_GC_META_BASE      0x0014_0000
PYCORE_GC_MARK_BITMAP    0x0014_0000 .. 0x0014_1FFF   8 KB   (61,372 bits used)
PYCORE_GC_ROOT_STASH     0x0014_2000 .. 0x0014_5FFF   16 KB  (count word + up to 511 tagged roots, value/tag pairs; RF ring alone can be 256)
PYCORE_GC_STATS          0x0014_6000 .. 0x0014_63FF   1 KB   (live, free, largest, count, max pause)
PYCORE_GC_STATIC_MAP     0x0014_6400 .. 0x0014_83FF   8 KB   (static prune map)
PYCORE_GC_RUN_TABLE      0x0014_8400 .. 0x0017_FFFF   227 KB (sequential free-run headers)
PYCORE_GC_MARK_STACK     0x0018_0000 .. 0x001F_FFFF   512 KB (32,768 x 16 B entries)
```

Mark-stack entry: 16 B = `{tag[127:124], payload}`; only pushable kinds are
stored (MUT_LIST/DICT/SET, OBJECT, CODE_OBJECT, TUPLE with `size<2^32` so bits
`[127:124]` are free, RANGE mode 1 pushed as TUPLE{3}). LONG_STR, spill
words and bytearray buffers are leaves: their extent is marked at the parent
and they are never pushed.

**Overflow bound [A, provable]**: mark-before-push (the first-granule bit is
set when an object is pushed) means every pushable object is pushed at most
once; the smallest pushable object is 32 B; the heap is 981,952 B; so the
pending count never exceeds 30,686 < 32,768. The engine still checks the
stack pointer and reports `gc_stack_overflow` (fatal in simulation, treated as
OOM in hardware). A directed test shrinks the stack via a parameter to prove
the guard fires and the core halts cleanly rather than corrupting memory.

Total metadata ≈ 537 KB of the 768 KB hole; the managed heap does not shrink.
Free-run headers (`{FREE_MAGIC=0x46524545, size_bytes, next_run, 0}` in the
first 16 B of each free run) live in free memory and cost nothing.
Collector bookkeeping is therefore always available when the heap is full.
**Superseded (implementation):** sweep headers live in the sequential table
at `PYCORE_GC_RUN_TABLE` as `{FREE_MAGIC, size, next, base}` (`next` is the
next table slot; `base` is the heap run). In-place headers (allocator
leftover / skip rewrite of a leftover) keep `base=0` and mean "run starts
at the header address". `S_GC_ALLOC` installs `base ? base : addr`.
`bench_full` sweep 30872 → 7784 after this move (562 listed runs); P4 cap
is still 5292 because first-touch fills of the table cost ~50 cyc/line.
**Superseded (implementation):** the first 1024 listed runs stay in an
on-chip array (peeked by `S_GC_ALLOC`); overflow continues in the table
starting at `PYCORE_GC_RUN_TABLE + 1024*16`. Dumps serialize the on-chip
words at the virtual table slots. `bench_full` sweep 7784 → 2172 (cap
5292); P4 passes. P5 is still mark-bound (`max_pause` 425208 after
folding single-word mark into `M_DEC`; grant-on-ack is unsafe on miss
acks because L1D is not yet IDLE).
**Superseded (implementation):** a word read returns the full L1D line
(`rdata_line`); `T_LINE_W` decodes two PLAIN pairs or one dict slot, and
`T_HDR_LINE_W` decodes a 32 B list/set header. `T_POP` issues the first
aligned tuple line; `T_LINE_W` goes to `T_POP` when the scan is empty.
Do not set `line_i` on the read (a hit would return `wline` zeros).
`bench_full` max_pause 425208 → 399009 (cap 400000). Dumps stay exact.

### 4.4 Allocator **[P]**

Registers: `heap_ptr_r` (unchanged), `heap_limit_r` (new; reset to
`PYCORE_HEAP_LIMIT`), `run_list_head_r`, `run_skipped_head_r`,
`gc_largest_run_base/size_r`, `gc_epoch_r`.

- **Fast path**: every existing site replaces `> PYCORE_HEAP_LIMIT` with
  `> heap_limit_r`. Identical cycle count.
- **`ensure_run(n)`** (sub-FSM in `S_GC_ALLOC`, also invoked inline from
  `S_CONTAINER`/`S_CALL` via a shared phase): if
  `pycore_heap_end(heap_ptr_r, n) <= heap_limit_r` → done. Else pop runs from
  `run_list_head_r` (one 16 B header read each, ~2-4 cycles); the first run
  with `size >= n + 64` (alignment slack) becomes the current run
  (`heap_ptr_r <= base; heap_limit_r <= base + size`); popped runs that do not
  fit are pushed on `run_skipped_head_r` (header rewrite, 1 slot write); the
  abandoned remainder of the previous current run, if ≥ 16 B, is pushed on
  `run_skipped_head_r` too. If the list empties → GC request. After a
  collection both lists are rebuilt from scratch, so skipped runs are never
  lost.
  **Superseded (implementation):** the sweep omits maximal free runs shorter
  than 64 B. They cannot satisfy `size >= need + 64`, and listing each
  alignment pad was ~55 cycles of a scattered header write (`bench_full`:
  844 → 562 listed runs). The oracle's listed-run check matches; `free` /
  `live` still count every unmarked granule.
  **Superseded (P8):** "After a collection both lists are rebuilt" no
  longer resets the current run for boundary and at-exit collections, which
  have no allocation to satisfy (explicit collections still re-select). The engine premarks the unallocated
  current run `[heap_ptr, heap_limit)` before the sweep, counts it free and
  lists the free memory on either side as separate runs; the core keeps
  `heap_limit_r`. Evidence: G8 single-core at 10b2ba8 popped 6-10 runs after
  every collection (1.43 pops per site allocation in measure runs) because
  the next allocation re-scanned the list from its small head runs. After
  any non-explicit collection the next search starts at the first run at or
  above the old bump pointer and wraps (next-fit): G8 seeds 0-9 single-core,
  0.084 → 0.011 pops per allocation.
- **Alignment**: `pycore_heap_place` is applied inside runs exactly as today;
  the line-alignment pad is free space and will be swept back.
- **Size classes**: none in v1. Allocation sizes are already regular and the
  run list is address-ordered by the sweep. Phase 6 may add a 32 B/48 B/64 B
  quick list if `gc_run_pops` per allocation becomes measurable.
- **Splitting/coalescing**: splitting is the bump itself; coalescing is
  implicit in the sweep (adjacent dead granules form one run).
- **Metadata exhaustion**: impossible by construction (bitmap and stack are
  sized for the whole heap).
- **True OOM**: `ensure_run` fails after a collection whose `gc_largest_run`
  did not grow → `PY_TRAP_MEM_FAULT` (v1) / `MemoryError` (Phase 5).

### 4.5 Engine (`pycore_gc.sv`) **[P]**

**Phase R revision (adopted structure; the draft below is superseded where
it differs; decisions in `pycore/docs/gc.md` §"Prior art and design
decisions"):**

- Mark stack: 64-entry on-chip LIFO of compressed entries
  `{kind[2:0], size[31:0], addr[31:0]}`; when full, the oldest 32 spill to
  `PYCORE_GC_MARK_STACK` (one 16 B slot each), and an empty on-chip part
  refills 32 from memory. Entry kinds: LIST, DICT, SET, OBJECT, CODE,
  TUPLE(size), STR_HDR (a LONG_STR reached from a STR iterator, whose extent
  needs its header).
  **Superseded:** 256 entries. Evidence: at 64, `bench_churn` (stack
  high-water 202) spilled 320 slots per collection, about a third of its
  mark transactions; P6b 0.283 → 0.266 with this change alone.
- Bitmap: one 128-bit word cached in a register with a dirty bit, written
  back only on a word change or at phase end. Backing store selected by
  `GC_BITMAP_ONCHIP` (480 × 128-bit array, or dmem at
  `PYCORE_GC_MARK_BITMAP`), decided by G13. Bit index is `addr >> 4`
  (absolute granule number, word `addr >> 11`), not `(addr - 0x440) >> 4`:
  no subtraction on the mark path, 61,440 bits = 480 words cover
  `[0, 0xF0000)`.
- Phases: `CLEAR` (first collection after reset only) → `ROOTS_REG` →
  `ROOTS_MEM` → `MARK` → `SWEEP` (clears every non-zero word as it scans) →
  `DONE`.
- Issue discipline: every mark-phase request is issued in the cycle after
  the previous ack; addresses are computed from the ack data.

Draft (first principles, pre-Phase R):

Ports: `clk, rst_n, start, done, need_abort`; dmem master (`req, we, addr,
wdata, wstrb, rdata, ack, fault`) muxed into the core's dmem port beside
STRACC (`stracc_dmem_active` pattern, `pycore_core.sv:1584-1606`);
`root_valid, root_entry[131:0]`; config `heap_dyn_base` (=`HEAP_INIT_PTR`),
`spill_sp, frame_tail, exc_sp`; results `live_bytes, free_bytes,
largest_run_base/size, run_list_head, stack_overflow, bad_kind`.

Phases:

1. `CLEAR`: zero the bitmap (480 slot writes).
2. `ROOTS_REG`: consume streamed register/RF roots (§3.3).
3. `ROOTS_MEM`: walk spill, frames (decode slot1), exc nodes (decode slot1),
   boot record, native table, StopIteration sidecar.
4. `MARK`: pop entry → set extent bits (one 128-bit RMW per 128 granules) →
   read header → for each child tag slot: if pointer tag, read value slot,
   check first-granule bit (RMW), push if unmarked. Leaves are extent-marked
   inline.
5. `SWEEP`: scan bitmap slots from the granule of `heap_dyn_base` upward;
   for each maximal zero run write a free header, link it (address order),
   accumulate `free_bytes`, track `largest_run`. Bits below `heap_dyn_base`
   are ignored (pinned). `live_bytes = heap - free`.
6. `DONE`.

All accesses are 16 B slot transactions with the existing one-outstanding
req/ack contract, so the engine is correct under `CACHE_EN=0` and any
`MEM_LATENCY`.

### 4.6 Fragmentation scenarios **[A]**

Dynamic region D = 631,488 B for a compiler-resident image; 981,952 − static
for others.

| Scenario | Total free after GC | Largest usable extent | Comment |
| --- | --- | --- | --- |
| Append-built list of 16,384 elements: buffers 4→8→…→16,384 elements | old buffers `(16384−4)*32 = 524,160 B` contiguous and adjacent (each grow bumps right after the previous) | one run of 524,160 B + wilderness | doubling growth coalesces perfectly; the live 524,288 B buffer fits only because the run exists — bump-only would need 1,048,448 B and fail |
| 8× `compile("1 + 2")` with §5.2 cleanup: each compile ≤ 50 KB scratch (from the 400,000 B / 8 golden), survivors = 256 B code object + small tuples | ≈ 7 × 50 KB | runs of ≈ 45-50 KB each, interrupted by survivors | repeated compile is sustainable indefinitely in heap terms (code RAM is the remaining ceiling, §5.3) |
| Pathological: 10,000 alternating live/dead 32 B list objects | 320,000 B | 32 B | a 64 B request fails despite 50% free; non-moving limitation; mitigation is size-aware placement (Phase 6), not compaction |
| Dict growth 4→8→…→4096 slots: dead tables 64 B slots → `(4096−4)*64 + orders` ≈ 393 KB | ≈ 393 KB contiguous | one run | same as list growth |

### 4.7 Compound blocks, publish ordering, partial failure

- A container and its initial buffers are **one contiguous extent** at
  allocation time but **separate allocations** to the collector: the sweep
  frees any granule that no live object claims. A grown-away buffer becomes
  free while its stable header stays live because the header's extent is 32
  or 48 B only; the old buffer is not reachable through `ob_item`/`table_ptr`.
- "Buffer derivable by arithmetic from the object address" is currently
  assumed nowhere in RTL except **`BUILD_TUPLE`'s per-slot bump** and the
  **empty-tuple / empty-`*args` address** (#3, #29). Both are preserved as
  harmless: the collector never reads a zero-size extent, and the per-slot
  bump stays inside the reserved run. Recommended cleanup **[P]**: emit
  `addr=0` for empty tuples in `BUILD_TUPLE`, `LIST_TO_TUPLE`, `*args`
  packing and STRACC results, and update `heap_image.py:271-279` to match;
  an empty tuple must never appear to alias a later allocation in `is`
  comparisons or debugging output.
- **Zeroed allocation (added in implementation).** RTL dict/set table
  allocations (`BUILD_MAP`, `BUILD_SET`, CALL `set()`, instance dicts,
  `**kwargs`, bulk rehash) never clear their tables; they rely on the bump
  allocator handing out never-written, zero memory. Reuse would expose stale
  key tag words. The allocator therefore keeps "the current run is zero":
  `S_GC_ALLOC` zeroes a free run when it becomes current (full-line writes
  with `CACHE_EN=1`, 16 B writes with `CACHE_EN=0`, whose hierarchy carries
  words only; skipping memory above the `heap_zero_r` high-water mark), and
  poison never writes above `heap_zero_r`.
- Allocate → initialize → publish ordering is unchanged: objects are written
  into fresh memory and published by the final RF write or pointer rewrite.
  A collection can only start at a boundary, so a half-initialised object is
  never traced. If a compound allocation fails halfway (STRACC `split`,
  excore dict grow), nothing was published; the bumped bytes are simply free
  space to the next sweep.
- Freeing old growth buffers is deferred to the sweep (no eager free), which
  makes alias-sensitive operations (`a.extend(a)`, `d.update(d)`) safe by
  construction.

New builtins **[P]** (`PY_BI_*` 22-24, CALL subs after 64; `call_sub_r` is 7
bits): `_bi_gc_collect() -> INT live_bytes`, `_bi_heap_free() -> INT`
(free bytes incl. current run remainder), `_bi_gc_stats(k) -> INT`
(0 collections, 1 max pause cycles, 2 largest run, 3 reclaimed bytes last
GC, 4 run pops). Seeded in the builtins dict by `image_from_source.py`; host
stand-ins in `run_image_test.py` return `0` / `gc.collect()`-derived values
so differential programs must not branch on them (use `# pycore-expect:`).

---

## 5. Static objects, compiler retention, code RAM, marks, caches

### 5.1 Static image objects: pinned-but-traced **[P]**

Everything in `[0x440, HEAP_INIT_PTR)` is never freed but is fully traced:
the sweep starts at `heap_dyn_base = HEAP_INIT_PTR` (plusarg already exists),
and marking treats static objects exactly like dynamic ones. Static-to-dynamic
edges are discovered by tracing, never by scanning static memory linearly.

**As built: static prune map.** Tracing the ≈380 KB static image cost about
190k cycles per collection (765 objects). The image builder
(`pycore/tools/gc_static.py`) now writes a map at `PYCORE_GC_STATIC_MAP`
(`0x146400`, one bit per heap granule) marking every static object whose
static subgraph holds no runtime-mutable object (list, set, cell, dict other
than a code object's `co_kwdefaults`, or any object pointing outside the
static image). The engine preloads the map into the bitmap at the start of
each collection (`P_PRELOAD`, bits at or above `dyn_base` masked), so pruned
objects test as marked and are never read. Such objects cannot lead to a
dynamic object, so the free set is unchanged; the oracle still judges it
against the unpruned trace. The containers below remain traced:

| Static container | How it acquires runtime references | Discovered via |
| --- | --- | --- |
| module globals dict (boot record) | `STORE_NAME`/`STORE_GLOBAL`, `exec` | boot record root → dict traversal |
| builtins dict | `_PYC_G` is a value in it | boot record root |
| `_PYC_G` | every compiler arena rebind, `_in_src` | builtins → `_PYC_G` → values |
| code objects' `co_defaults`/`co_kwdefaults` | image-time only today (non-literal defaults are `SyntaxError`) | CODE traversal |
| seeded types' `tp_dict` | `STORE_ATTR` on a type traps, but `C.__dict__` returns the dict and `STORE_SUBSCR` can mutate it | OBJECT/TYPE traversal |
| seeded lists/dicts in user modules | any mutation | traversal |
| native-method table, StopIteration sidecar | static | fixed root ranges |

Static dicts grown at runtime get a **dynamic** table/order (excore or bulk
grow); the static ones become dead granules below `heap_dyn_base` and stay
pinned (a known, bounded leak: at most the image's original tables).

### 5.2 Compiler retention **[P]**

Separate from allocation leaks: the *latest* compilation's arenas are reachable
through `_PYC_G`. Fix in `compile.py`'s `finally`, on both success and
`SyntaxError`, using only allocation-free operations (INT stores into an
existing dict key are value overwrites: no growth, no allocation):

```python
    finally:
        g["_busy"] = 0
        g["_in_src"] = 0          # drop the source string
        g["tk_a"] = 0; g["tk_b"] = 0; g["tk_s"] = 0
        g["nd_kind"] = 0; g["nd_pos"] = 0; g["nd_a"] = 0; g["nd_b"] = 0
        g["nd_c"] = 0; g["nd_obj"] = 0; g["kids"] = 0
        g["opnd"] = 0; g["ops"] = 0; g["ops_obj"] = 0; g["stmts"] = 0
        g["sc_kind"] = 0; g["sc_parent"] = 0; g["sc_node"] = 0
        g["sc_nlocals"] = 0; g["sc_argcount"] = 0; g["sc_varnames"] = 0
        g["sc_kwonly"] = 0; g["sc_flags"] = 0; g["sc_defaults"] = 0
        g["sc_kwdefaults"] = 0
```

Preconditions to verify **[?]**: every pass re-creates its arrays before
reading them (lexer/parser/symtab/codegen do today per §1.4; the
`_pyc_codegen_main` resets at `codegen.py:1389-1397` must move to the start
of the function or be tolerant of `0`). The returned `CODE_OBJECT`, nested
code objects (in `co_consts`), constants, defaults and closures are not in
`_PYC_G` and are unaffected. `test_compiler_differential.py` and the
`img_compile_*` fixtures gate this. The 7-bit `STORE_SUBSCR`-free form
(`g[k] = 0` is `BINARY_SUBSCR`-free) keeps the ROM body small; the exact key
list is generated from `PACKAGE_RUNTIME_SEEDS` so the two cannot drift
(`test_rom_firmware_seed.py`).

**Superseded (as built):** `compile()` is unchanged, because clearing the
slots in its `finally` changes the `GC_EN=0` cycles of every compile
fixture (G1). The engine clears them instead, at collection start, when
`_busy` is 0, from an image descriptor (`PYCORE_GC_COMPILER_CLEANUP`). The
builder omits the descriptor for programs that name `_PYC_G`.
Evidence: G7 (b) at 10b2ba8, `img_lexer_count`, `img_parser_tiny_expr`,
`img_compile_deep_nesting`, `img_symtab_locals`, `img_symtab_closure`
and `img_codegen_t1_expr` trapped code 1 on both tops. They run passes
directly with `_busy` 0, so a boundary collection cleared arrays they were
still using.

### 5.3 Code RAM: deferred, with the ceiling stated

v1 leaves `_bi_code_alloc` as a bump allocator with mark/release. After heap
GC, repeated `compile()` is bounded by code RAM, not heap: 15,508 free slots
after the compiler package; `compile("1 + 2", ..., "eval")` emits a handful of
slots, a 100-line function a few hundred. A program that compiles in a loop
without `_bi_code_mark/_release` still exhausts code RAM. This is documented
in `code_loading.md` §5 and `README.md`; heap GC must **not** be described as
making `compile/exec/eval` run indefinitely.

Phase 7 design (not v1): a code-RAM extent table `{base_slot, nslots}` in the
metadata hole written by `_bi_code_alloc` (`pycore_call_fsm.svh:1815-1841`);
roots = every marked `CODE_OBJECT` (the heap tracer records `entry_slot` when
it visits field 0), `cur_code_r`, frame `cur_code`, native table; pending
constructions are protected because `_bi_code_alloc` → `_bi_code_blit` →
`_bi_code_new` run inside one `compile()` whose intermediate `INT` base slot
is a live local (a **raw slot integer in RF is not a root** — so the extent
table entry must be born *marked* and only become collectible after the first
collection that finds no code object referencing it); `code_ram_floor_r`
protects the firmware package; sweep clears extents into a slot free list;
reuse requires L1I invalidate of the written lines (already done per write),
fetch-buffer drop (`code_write_i`), CODC flush. Nested code objects are
ordinary heap objects reachable from `co_consts`.

### 5.4 Compatibility with `_bi_heap_mark/_bi_heap_release` **[P]**

- `GC_EN=0`: unchanged.
- `GC_EN=1`: `_bi_heap_mark()` returns `INT {gc_epoch_r[31:0], heap_ptr_r[31:0]}`
  (epoch in bits 63:32, widened from 16 bits in review round 3 so it cannot
  wrap; a rewinding release zeroes `[mark, old ptr)`, B26; a mark that is
  not 16-byte aligned → `MEM_FAULT`; arithmetic between two marks of the same epoch still
  works when no collection ran). `_bi_heap_release(m)`: if `ptr(m)` is below
  `heap_init_ptr` → `MEM_FAULT` even when the epoch field is 0 and
  `gc_epoch_r` has advanced (INT 0 is not a mark; G7 (b)
  `img_heap_release_below_base_trap` at f326e22 returned cleanly before this
  check moved ahead of the superseded test). If `epoch(m) == gc_epoch_r` and
  `run_base_r <= ptr(m) <= heap_ptr_r` → rewind; if the epoch differs, or
  the mark lies in a different run → **no-op** and `gc_stats[5]++`; if the
  epoch matches but the mark is above `heap_ptr_r` → `MEM_FAULT`.
  **Superseded:** "stale-trap goldens unchanged under G7 (b) K=1". Evidence:
  `img_heap_release_stale_trap` (`release(mark+64)`) with a collection
  between the two builtins is an epoch-stale no-op, not trap 7. G7 therefore
  does not force `GC_AT_BOUNDARY_EVERY` on bump-cursor identity / above-cursor
  trap fixtures; they still run `GC_EN=1` and G7 (a)/(c) heap pressure.
  `img_heap_release_below_base_trap` keeps its golden.
- Code marks are unchanged in v1.
- **Superseded:** `img_compile_repeat` mark subtraction. Evidence: G7 (b)
  expected 1 got `0x3200001440` (epoch 0x32 in bits 47:32). The fixture now
  returns 1 after eight successful `compile`s; Phase 4 still adds
  `_bi_heap_free()` after `_bi_gc_collect()` for leak measurement.

### 5.5 Cache maintenance **[P]**

| Concern | Handling |
| --- | --- |
| Data coherence for the collector's own traffic | the engine is a core-side dmem master behind L1D like STRACC; no flush needed; `CACHE_EN=0` pass-through works because it obeys req/ack |
| Excore ownership | collections run only in PyCore-owned windows; the `$fatal` owner check in `pycore_excore_system.sv:370-377` stays |
| Result caches (CODC, GIC) holding addresses of dead objects that may be reused | pulse both `flush_i` during `S_GC_RUN`; add a row to the invalidation matrix in `memory_hierarchy.md` |
| Code cache (L1I, fetch line buffer) | untouched in v1 (code RAM not reclaimed) |
| Pending fills | none can be pending at `S_FETCH`; the engine starts after drain |
| Stale L1D lines over freed-then-reallocated heap | same cache, same address: no incoherence; reallocation writes through L1D normally |

---

## 6. Executable implementation plan

### 6.1 Interfaces (all new, **[P]**)

```
pycore_core.sv
  heap_limit_r[31:0]          run end (reset PYCORE_HEAP_LIMIT)
  run_list_head_r, run_skipped_head_r, gc_epoch_r[31:0]
  gc_req_r, gc_need_bytes_r[31:0], gc_req_pc_r[31:0], gc_retry_count_r[1:0]
  S_GC_ENTER / S_GC_ROOTS / S_GC_RUN / S_GC_ALLOC
  gc_root_valid, gc_root_entry[131:0]  -> pycore_gc
  gc_start, gc_done, gc_codc_flush, gc_gic_flush
  trap_req_heap_limit_o[31:0]          -> mailbox MB_HEAP_LIMIT
  TRAP_RES_NEED_HEAP = 4'd3            handled in S_TRAP_WAIT

pycore_gc.sv (new)
  dmem master ports; root port; heap_dyn_base_i, spill_sp_i, frame_tail_i,
  exc_sp_i; live_bytes_o, free_bytes_o, largest_run_base_o/size_o,
  run_list_head_o, stack_overflow_o, bad_kind_o, pause_cycles_o

pycore_str_accel.sv
  cmd_heap_limit_i; res_need_heap_o, res_need_bytes_o

trap_mailbox.sv / excore_mmio.sv
  MB_HEAP_LIMIT @0x1C; RES_CODE value 3 = NEED_HEAP

excore/fw/list_grow.s
  res_need_heap: RES_CODE=3, RES_HEAP_PTR=need, RES_GO; five check sites use lw MB_HEAP_LIMIT

builtins: _bi_gc_collect (22), _bi_heap_free (23), _bi_gc_stats (24)
plusargs: +GC_EN= +HEAP_LIMIT= (shrink the heap) +GC_EVERY_N_RUNS= (force a
          collection on every N-th ensure_run for deterministic stress)

verification plusargs (simulation only; every default = off / today's behaviour)
  +GC_AT_BOUNDARY_EVERY=K  collect at every K-th instruction boundary (S_FETCH),
                           resuming at the same pc; stresses root completeness
                           at points where nothing allocates (G7)
  +GC_AT_EXIT=1            one collection when managed_entry returns, before the
                           result check (G4 on the existing suite)
  +GC_ROOT_STASH=1         write the captured root set to GC_ROOT_STASH (§3.3)
  +GC_DUMP_EACH=<dir>      after every collection write a coherent dump (below):
                           heap, metadata, root stash, run list, engine counters
  +DUMP_DMEM=<file>        coherent dump at the end of the run
  +GC_SHADOW=1             shadow-heap use-after-free checker (G5); forced on
                           whenever GC_EN=1 in the gate runs
  +GC_POISON=1             sweep overwrites every freed granule with a poison
                           pattern (value slot 0xDEAD_6C00_...; tag slot uses
                           the reserved FROZENSET tag plus a magic) so a missed
                           use-after-free also corrupts results visibly
  +GC_SITE_STATS=1         print per-allocation-site counters at exit:
                           allocations, abort->collect->re-dispatch count, bytes
                           (one row per §1.3 inventory number) (G9)
  +GC_MUTANT=<n>           enable deliberate collector bug n (§10.2 G10); 0 = none
  +MAX_CYCLES_SCALE=<n>    multiply MAX_CYCLES; honoured only when a torture
                           plusarg above is present, so normal caps never move

counter line (printed by tb_container at exit when GC_EN=1; parsed by the runner)
  GC collections=<n> live=<B> free=<B> largest=<B> max_pause=<cyc>
     total_pause=<cyc> mark_cyc=<cyc> sweep_cyc=<cyc> port_busy_mark=<cyc>
     stack_hw=<n> stack_spills=<n> run_pops=<n> need_heap=<n> reclaimed=<B>

coherent dump: dmem contents as the program sees them. With CACHE_EN=1 the
  RAM model is stale (L1D and L2 are write-back), so the TB must read each
  slot through L1D, then L2, then RAM using hierarchical references (or the
  core must flush L1D and L2 before the dump in simulation). A self-test dumps
  the same fixture at CACHE_EN=0 and CACHE_EN=1 and requires identical heap
  and metadata bytes.

make variable: PYCORE_GC_PLUSARGS ?= (empty) appended by every image-run macro
  after $(PYCORE_MEM_PLUSARGS), so a whole suite can run under a torture mode:
  make -j pycore-img PYCORE_GC_PLUSARGS="+GC_EN=1 +GC_EVERY_N_RUNS=1"
```

### 6.2 File-by-file change map

| Area | Files | Change |
| --- | --- | --- |
| RTL core | `pycore/rtl/pycore_core.sv` | states, allocator registers, root streaming, re-dispatch, `NEED_HEAP`, flushes, perf counters, GC builtins dispatch |
| RTL includes | `pycore_cont_list.svh`, `pycore_cont_dict.svh`, `pycore_cont_object.svh`, `pycore_cont_bulk.svh`, `pycore_cont_closure.svh`, `pycore_cont_raise.svh`, `pycore_call_fsm.svh` | `heap_limit_r` at all 35 sites; abort exits; `UNPACK_EX` reorder; CALL budget phase; empty-tuple `addr=0`; mark/release epoch |
| RTL new | `pycore/rtl/pycore_gc.sv`, `pycore/tb/tb_gc.sv` | engine + unit TB over a `heap_image.py`-built dmem |
| Defs / mirrors | `pycore_defs.svh`, `pycore/tools/encoding.py`, `pycore/tests/test_heap_image_and_constants.py` | metadata map, BI ids, `NEED_HEAP`, FREE_MAGIC, extent helpers `pycore_gc_extent_*` |
| STRACC | `pycore_str_accel.sv`, `pycore/tb/tb_str_accel.sv` | grant limit, `NEED_HEAP` result, test |
| System tops / TB | `pycore_system.sv`, `pycore_excore_system.sv`, `pycore/tb/tb_container.sv` | `GC_EN`, plusargs, counter printout `GC collections=… live=… free=… largest=… max_pause=…` |
| Excore | `excore/rtl/trap_mailbox.sv`, `excore/rtl/excore_mmio.sv`, `excore/fw/list_grow.s`, `excore/tb/tb_excore.sv`, `excore/docs/mmio_map.md`, `excore/docs/adding_a_trap_handler.md` | `MB_HEAP_LIMIT`, code 3, `res_need_heap`, mocked-mailbox test |
| Image / host | `pycore/tools/image_from_source.py` (seed builtins), `run_image_test.py` (stand-ins, `GC_EN` passthrough), `heap_image.py` (empty tuple addr 0), `size_report.py` (metadata row), new `pycore/tools/gc_model.py` (host mark/sweep over a dmem dump + root stash: oracle for live bytes and reachability) | |
| Firmware | `pycore_firmware/builtins/compile.py`, `compile.md`, `builtins.md`, new `gc.md` | cleanup, docs |
| Verification (new) | `pycore/tb/gc_shadow_check.sv` (G5, bound into both tops), TB coherent dump and counter line in `tb_container.sv`, `pycore/tools/gc_fuzz.py` (G8), `pycore/tools/gc_bench.py` (G13), `tools/gc_acceptance.py` (§10.3), `pycore/tests/test_gc_model.py`, `pycore/tests/test_gc_fuzz.py` (generator emits lint-clean programs), `pycore/tests/data/gc_baseline_cycles.tsv` (G0) | see §10 |
| Makefile | `pycore-gc` (unit), `pycore-img-gc-*`, `pycore-img-gc-all`, two-core variants, `PYCORE_GC_PLUSARGS` appended in every image-run macro, `pycore-gc-mutants`, `pycore-gc-fuzz`, `pycore-gc-bench`, `pycore-gc-acceptance`; include GC fixtures in `pycore-img` so transparency/latency sweeps cover them | |
| Docs | `pycore/docs/gc.md` (new, as-built), `memory_hierarchy.md` (map + matrix row), `architecture.md` (stale `0x1B000` map, bump-allocator section), `code_loading.md` §5, `object_model.md` (`0x1BFE0` → `0xF0FE0`), `README.md`, `planning/master_plan.md`, `planning/architecture_plan.md` A4 | |

### 6.3 Phases

Every phase keeps both tops green, ends with its exit gates (IDs from §10.2),
and ends with `make pycore-gc-acceptance MODE=quick`. Phases R through 6 are
**required**; Phase 7 is out of scope. Relative risk is noted; calendar
estimates from the planning session are dropped because they do not apply to
an agent.

**Phase R: prior-art design review (required before any RTL).** Read Bacon
et al. 2012 §3, Maas et al. 2018 §V (including mark-queue spilling and the
mark-bit cache), and Cloaca §6. Write `pycore/docs/gc.md` §"Prior art and
design decisions" with one entry per row of the §2.5 adoption table:
decision, reason, expected cycle and area effect, and the G13 measurement
that will confirm it. Update §4.5 of this plan to the adopted engine
structure (on-chip mark stack with spill, bitmap-slot cache, sweep-clears).
Exit: the doc section is committed and every §2.5 row has a decision.

**Phase 0: verification infrastructure, then the engine in verify-only mode
(low risk, but the foundation of everything).** Build the checkers before the
thing they check:

1. G0 baseline (§10.2) on the unmodified design target.
2. `tools/gc_acceptance.py` and `make pycore-gc-acceptance` (§10.3), with
   every gate wired in and failing closed, so progress is measurable from day
   one.
3. `gc_model.py` (host oracle) and `test_gc_model.py`, including the
   independent Python-level reachability check (G2).
4. TB coherent dump, `+GC_DUMP_EACH`, `+GC_ROOT_STASH`, the counter line, and
   the CACHE_EN=0 vs 1 dump self-test.
5. `gc_shadow_check.sv` (G5). It has nothing to catch until Phase 1 frees
   memory, but it must exist and pass its self-test now.
6. `PYCORE_GC_PLUSARGS` in every image-run macro; `+MAX_CYCLES_SCALE`.
7. `pycore_gc.sv` marks and sweeps into the metadata region, but the core
   does **not** consume the run list; `_bi_gc_collect()` returns live bytes.
   `tb_gc.sv` unit TB (G3). Fixtures `img_gc_verify_containers`,
   `img_gc_verify_cycles`, `img_gc_verify_closures`.

Exit: G0, G1, G2, G3, and G4 in verify-only form (oracle-exact free set and
counters) on **every** existing `img_*` fixture with `+GC_AT_EXIT=1`, both
tops, both `CACHE_EN`. Main risk: extent formulas.

**Phase 1: the allocator uses runs; explicit collection (medium).**
`heap_limit_r` replaces the constant at all sites; `ensure_run`; the sweep
rebuilds runs; `_bi_gc_collect()` reclaims; mark/release epoch semantics;
empty-tuple `addr=0` (§9 decision 4). Automatic collection stays **off**
(`ensure_run` failure = `MEM_FAULT`). Fixtures: `img_gc_reuse_after_collect`
(allocate garbage, collect, allocate again, assert `_bi_heap_free()` grew and
the return value is right). All mark/release fixtures and the
`img_compile_repeat` golden unchanged. EXCORE_EN=1 runs with `+GC_EN=0`.
Exit: G1, G2, G3, G4, G5, G6 on the GC fixture set and the existing suite
with `+GC_AT_EXIT=1`; the root, extent, and sweep mutants (G10 numbers 1-30)
killed.

**Phase 2: automatic collection at PyCore and STRACC sites (high).** Abort
exits for every inventory row marked "alloc-phase abort", the CALL budget
phase, the `UNPACK_EX` reorder, STRACC grant and `NEED_HEAP`, re-dispatch,
and the loop guard. `+GC_AT_BOUNDARY_EVERY`. `gc_fuzz.py`. Then build
`gc_bench.py` and decide the §2.5 "evaluate" rows by measurement. Exit on
EXCORE_EN=0: G4-G11 (G10 without mutant 33, which needs Phase 3) and G13
P1-P5, plus G12 on the single-core top;
`MODE=full` acceptance run with the two-core-only gates recorded as
`pending-phase-3` (the runner reports them failing; that is expected until
Phase 3).

**Phase 3: excore grant protocol (medium).** `MB_HEAP_LIMIT`, `RES_CODE=3`,
firmware, the mocked-mailbox re-dispatch test (§3.6), and two-core fixtures
for every growth path. Flip the `GC_EN` default to 1 (§9 decision 1).
`EXPECTED_TRAP_REQ_COUNT` goldens change only where a `NEED_HEAP` round trip
is expected, and each change is listed in the ledger with the reason. Exit:
G1-G12 on both tops; `MODE=full` run.

**Phase 4: compiler cleanup and metrics (low).** `compile.py` `finally`
cleanup (§5.2); `img_compile_repeat` already returns 1 after eight compiles
without mark subtraction (G7 (b) at f326e22); Phase 4 still adds
`_bi_heap_free()` after `_bi_gc_collect()` for leak measurement. New
`img_gc_compile_loop` (compile 64 times without
marks; retain selected earlier functions, closures, and namespaces; assert
live bytes plateau and code-RAM use grows linearly) and
`img_gc_compile_syntaxerror`. Measures heap and code-RAM retention
separately. Exit: G11 compile rows; G13 P6a.

**Phase 5: `MemoryError` (low).** Seed the type; route allocator failure
through the raise path so `except MemoryError` works. Fixtures
`img_gc_memoryerror_caught` and `img_gc_memoryerror_recover` (catch it, drop
the big structure, allocate again successfully). `img_gc_fragmented_alloc`
and `img_gc_live_exceeds_heap` switch from `MEM_FAULT` to `MemoryError`
goldens. Exit: G4-G11 on both tops.

**Phase 6: performance to target (required).** Implement the remaining
adopted §2.5 items and whatever G13 profiling shows is needed: small-object
quick lists, eager free of old buffers when PyCore knows `old_buf`,
`heap_end` alignment for excore. Exit: G13 all targets; then the full DONE
sequence (G14 `make all-tests`, G15 review, G16 docs and CI, and a final
`MODE=full` run).

**Phase 7: code-RAM reclamation (out of scope; §5.3).** Document the ceiling
only.

### 6.4 Tests

Directed image fixtures (each has `EXCORE_EN=0` and, from Phase 3, a two-core
target; each runs in `pycore-img` so `pycore-cache-transparency` and
`pycore-mem-latency-sweep` cover both cache modes and latencies). Each checks
**both** the Python result and reclamation. Prefer programs whose return
value host CPython can compute (a checksum over the surviving data), with the
reclamation assertions made by the acceptance runner from the counter line
and the oracle, so the golden stays independent of the device. Use
`_bi_heap_free()` / `_bi_gc_stats()` plus `# pycore-expect:` only when the
assertion must happen inside the program. Every fixture also runs under G4
(oracle), G5 (shadow checker), and G7 (torture), which is where most
root-completeness bugs will surface. The table is the minimum; add fixtures
freely.

| Fixture | Exercises |
| --- | --- |
| `img_gc_cycle_self`, `img_gc_cycle_mutual` | unreachable self/mutual cycles (list ∋ itself; two instances pointing at each other) reclaimed |
| `img_gc_alias_identity_key` | live aliases; OBJECT keys in a contaminated dict keep identity hash after collection |
| `img_gc_root_spill` | value reachable only from a spilled RF slot (deep recursion forces `S_RF_SPILL`) survives |
| `img_gc_root_caller_frame`, `img_gc_root_saved_globals`, `img_gc_root_ctor_instance` | caller-frame code, `_bi_exec_globals` dict, `__init__` instance |
| `img_gc_root_closure` | cell reachable only via `cur_closure_r` between CALL and `COPY_FREE_VARS` (collection forced by the callee's first allocation) and via a FUNCTION's closure tuple |
| `img_gc_root_iterators` | list/tuple/dict/set/str(long, short-spill)/range iterators as sole owners |
| `img_gc_root_exception` | object reachable only from `active_exc_r` / an exc-stack node / `e.args` |
| `img_gc_suspended_next` | collection inside `__next__` while FOR_ITER holds the outer iterator only in `container_call_saved_rs1_r` |
| `img_gc_static_to_dynamic` | module global and seeded dict pointing at fresh allocations survive |
| `img_gc_overwrite_locals_globals`, `img_gc_stale_rf_pop` | overwritten bindings and popped slots are reclaimed |
| `img_gc_list_capacity`, `img_gc_dict_deleted`, `img_gc_empty_tuple`, `img_gc_int_looks_like_addr` | precision: unused capacity, tombstoned values, zero-size tuples, INT/FLOAT/str payloads equal to live addresses are not retained |
| `img_gc_growth_paths` | every growth path (list grow/extend/delete, dict/set grow, update/merge, contaminated bulk) under a heap small enough that each grow needs a collection first |
| `img_gc_stracc_split` | `split` producing many objects; `NEED_HEAP` mid-split; result correct and pieces reclaimed |
| `img_gc_fragmented_alloc` | allocate/free pattern leaving runs; large request fails with `MEM_FAULT` (v1) / `MemoryError` (Phase 5) while small ones succeed |
| `img_gc_live_exceeds_heap` | genuinely live data > heap → clean OOM, not a hang or corruption |
| `img_gc_stack_overflow_guard` | `-GGC_STACK_ENTRIES=16` build: guard fires |
| `img_gc_boot_reset` | collection immediately after boot (only static roots); metadata reset |
| `img_gc_partial_construction` | force `NEED_HEAP` inside CALL budget, STRACC concat, excore dict grow: no partially published object; retry works |
| `img_gc_compile_loop`, `img_gc_compile_syntaxerror` | §6.3 Phase 4; success and `SyntaxError` cleanup |
| `img_gc_mark_release_epoch` | `_bi_heap_release` with a same-epoch mark rewinds; with a stale mark it is a no-op and bumps `gc_stats[5]`; stale-trap goldens unchanged (§5.4) |
| `img_gc_steady_{list,dict,set,str,exc,closure,compile}` | G11 steady state: 1,000 iterations of build, grow, and drop; free bytes plateau |
| `img_gc_bench_full`, `img_gc_bench_churn`, `img_gc_bench_deep`, `img_gc_bench_wide` | G13 benchmarks: about 600 KB live over about 20k objects; allocation churn at heap ≈ 3× live; a 10k-deep linked chain (mark-stack depth and spill); one 16k-element list of small objects (mark-stack breadth) |
| `img_gc_memoryerror_caught`, `img_gc_memoryerror_recover` | Phase 5 |
| `img_gc_fuzz_<seed>` | one per G8 failure, added before the fix |
| `img_gc_mutant_<n>` | a fixture written specifically because the suite failed to kill mutant `n` (G10) |

Unit / host tests: `tb_gc.sv` (synthetic heaps from `heap_image.py`: each kind,
empty/tombstone slots, order sidecar, nested tuples, cycles; at least 200
seeded random heaps; asserts the run list and counters against `gc_model.py`
at every `CACHE_EN` and `MEM_LATENCY` setting); `tb_str_accel.sv`
`NEED_HEAP`; `tb_excore.sv` mocked `MB_HEAP_LIMIT` too small → code 3;
`test_gc_model.py` (oracle vs hand-built images and vs Python-level
reachability, G2); `test_gc_fuzz.py` (generated programs are lint-clean and
deterministic per seed); `test_heap_image_and_constants.py` (metadata
mirrors, `NEED_HEAP`, BI ids); `excore-asm-tests` for the new routine; a
shadow-checker self-test (a TB-forced access to a freed granule must
`$fatal`).

Tests actually executed during planning: none beyond `make pycore-size-report`
(read-only occupancy numbers quoted in §1.1).

### 6.5 Estimates **[A]**

Costs assume 2 cycles per 16 B slot on an L1D hit (issue + ack), ~3-4 on an L2
hit, `+MEM_LATENCY` beats on a miss; the 128-bit port moves one slot per
transaction.

| Quantity | Estimate |
| --- | --- |
| Metadata | 8 KB bitmap + 512 KB stack spill area + 16 KB root stash + 1 KB stats = 537 KB of an unused 768 KB hole; 0 bytes per object |
| Common allocation latency | unchanged (compare against a register) |
| Run switch | 2-4 cycles per candidate run header; typically 1-2 candidates |
| Root scan | RF ≤ 256 cycles; spill 4 cycles/entry (≤ 33k worst, typically < 1k); frames 3 cycles/frame; exc ≤ 400 |
| Mark | per pushed object ≈ 6 cycles (RMW) + 2-6 header + 2 per child tag + 2 per pointer child; per 2 KB of extent one RMW. Live heap of 600 KB with ~20k objects ≈ 0.2-0.4 M cycles at L1D/L2 hit rates; ×10-15 with `CACHE_EN=0 MEM_LATENCY=30` |
| Sweep | 480 bitmap slots ≈ 1.5k cycles + 2 cycles per free run (≤ 30k) |
| Total pause | ≈ 0.25-0.5 M cycles per collection for a full 600 KB live heap; a nearly empty live heap (typical after `compile()` cleanup: ~350 KB static + tens of KB dynamic) ≈ 0.15-0.3 M. Reference points: `img_recursion` ≈ 52k cycles total; `img_allocator_list` ≈ 2.96 M |
| Frequency | one collection per D bytes of allocation (≈ 631 KB for the compiler image); `img_compile_repeat` (8 × ≤ 50 KB) would collect at most once |
| Reclaimed bytes | scenario table §4.6 |
| Excore grant cost | one extra `lw` per handler; a `NEED_HEAP` round trip costs one L1D handoff pair (flush ≤ 128 line writebacks + 1-cycle invalidate) plus re-dispatch |

Measurements to add: the counter line in §6.1, parsed by `gc_bench.py` and the
acceptance runner. These estimates predate the §2.5 review; the on-chip mark
stack and bitmap-slot cache should remove most of the per-object RMW and
push/pop traffic counted above. G13 replaces these estimates with
measurements.

---

## 7. Smallest end-to-end milestone

`img_gc_cycle_reuse` on `EXCORE_EN=0`, `CACHE_EN=1`: a loop that builds a
self-referential list of tuples each iteration and drops it, with
`+HEAP_LIMIT=` shrunk so the wilderness holds ~3 iterations. Passes only if
(a) the program returns the right value, (b) `_bi_gc_stats(0) >= 3`, (c)
`_bi_heap_free()` after the loop is within 10% of its value after the first
collection, (d) `gc_model.py` agrees with the RTL free set granule for granule
at **every** collection (`+GC_DUMP_EACH`), not just the live-byte count at
exit, and (e) the shadow checker (G5) stays silent with `+GC_POISON=1`.
That requires Phases 0-2 for `BUILD_LIST`/`BUILD_TUPLE` only, with the other
abort sites stubbed to `MEM_FAULT`, and proves safe reclamation and reuse.
Reaching this milestone is a checkpoint, not completion: it exercises two of
the 35 allocation sites.

## 8. Highest-risk assumptions (experiments first)

1. **Abort safety of every allocation phase** (§3.4). Experiment: a
   simulation-only `+GC_EVERY_N_RUNS=1` mode that forces a collection on every
   `ensure_run` across the whole `pycore-img` list; any divergence from the
   host golden points at a site that committed before allocating.
2. **Extent formulas** (§4.1). Experiment: Phase 0 oracle differential on
   every existing fixture before any reclamation is enabled.
3. **Pause cost under `CACHE_EN=0`, `MEM_LATENCY=30`** may blow `MAX_CYCLES`
   on fixtures that collect. Experiment: measure Phase 0 forced collections.
   This is the **only** case in which a cap may be raised, and only for a
   fixture that collects in its default configuration: new cap = measured
   cycles × 1.5, with a ledger entry quoting the counter line. Never raise the
   default cap, and never raise a cap for a fixture that does not collect.
4. **CALL budget bounds** (§3.5): an under-estimate turns into a mid-binder
   `MEM_FAULT`. Experiment: assert in simulation that no CALL-internal
   allocation ever fails after a successful reservation.
5. **Excore `NEED_HEAP` re-marshal**: the re-dispatched container op must
   reach the same trap with the same operands; `EXPECTED_TRAP_REQ_COUNT`
   goldens change. Experiment: two-core `img_gc_growth_paths` with a tiny heap.
6. **Coherent dumps under `CACHE_EN=1`.** An oracle that reads a stale RAM
   model will report phantom bugs or, worse, miss real ones. Experiment: the
   CACHE_EN=0 vs 1 dump self-test in §6.1, before any G4 result is trusted.
7. **Shadow-checker false positives** from STRACC and excore writing inside a
   grant before the core adopts the new cursor. Rule: accesses inside the
   current run `[heap_ptr_r, heap_limit_r)` are always legal; only accesses to
   granules in *other* free runs are use-after-free.

## 9. Decisions (resolved; do not stop to ask)

The planning session left these open with recommendations. The
recommendations are adopted as settled defaults so implementation never
blocks on them; the human may override any of them by editing this section
before kickoff. Reopen one only with evidence that it is unworkable, recorded
in the ledger.

1. **Default `GC_EN=1` timing:** flip at the end of Phase 3, so both tops are
   covered first.
2. **`_bi_heap_release` on a stale (post-collection) mark:** no-op plus a
   counter (§5.4), so caller code written for the bump heap keeps running.
3. **Code-RAM reclamation:** deferred (Phase 7, out of scope). Document the
   compile-loop ceiling.
4. **Empty-tuple `addr=0` canonicalisation:** do it in Phase 1, while
   addresses are already changing under test.

Resolution rules for the [?] items:

- **§3.1: is the frame's `saved_instance` field zeroed on push?** Read the
  push path in `pycore_frame.sv`. If it is not always zeroed, make the push
  zero it (a stale nonzero value would be traced as an OBJECT after its
  memory was reused, which is either a leak or a `gc_bad_kind` fatal) and add
  an assertion. Either way add `img_gc_root_ctor_instance` coverage.
- **§3.4 / §1.3 #16-18: "verify no pop before the bump".** Read each
  contaminated bulk path. Confirm with G7 torture plus a G9 counter showing
  the site was aborted and re-dispatched at least once with a correct result.
- **§5.2 preconditions for the compiler cleanup.** Every pass must create its
  arrays before reading them. Gate: `test_compiler_differential.py`, all
  `img_compile_*` fixtures, and `img_gc_compile_syntaxerror`.

Routine choices made here without asking: 16 B granule; extent bitmap over
headers; bump-into-runs over segregated free lists; boundary-only collection
with re-dispatch; CALL up-front budget; excore/STRACC grants with
`NEED_HEAP`; deferred (sweep-time) freeing of old growth buffers; pinned static
image; `MemoryError` in Phase 5 rather than v1.

---

## 10. Verification and acceptance (the definition of done)

### 10.1 What "working" means

A collector fails in four ways, and each gate below targets at least one:

1. **It frees something reachable** (a missed root, a short extent, a skipped
   child, a stale CODC/GIC entry). The damage is usually silent until the
   memory is reused, so output-only tests catch it late or never.
2. **It keeps something unreachable** (imprecision, a leak).
3. **It corrupts the mutator** on the abort, collect, and re-dispatch path (a
   site that committed before allocating, a double pop, a lost operand).
4. **It is slow**, or slows down code that never collects.

Two principles apply to every check. A check must be **independent** of the
RTL it checks. And a check only counts once it has been **shown to fail**
when the RTL is wrong; that is what mutation testing (G10) is for.

The previous draft of this plan fell short of both principles in four ways.
It compared live-byte *counts*, so a freed-live error and a leaked-dead error
of equal size cancelled out. Its oracle took the root set from the RTL's own
stash, so a missed register root was invisible to it. It had no direct
use-after-free detection. And it had no pass/fail performance bar and no
stopping rule. G4, G5, G10, and G13 close those gaps.

### 10.2 Gates

Each gate lists how it is run and what counts as a pass. The first phase
that requires a gate is in §6.3; all 17 must pass together for DONE.

**G0: baseline.** Before any RTL change, on the design-target commit (or the
merge base after a rebase), run `make all-tests TEST_JOBS=<cores>` and parse
every `PASS:` line into `pycore/tests/data/gc_baseline_cycles.tsv` with
columns `target, top, cache_en, mem_latency, kind (return|trap),
tag_or_trap_code, value, cycles`. Also save the Verilator warning list of
both shared simulator builds. Pass: the file is committed and covers every
fixture of `pycore-img`, `pycore-img-two-core`, `pycore-excore-system`, and
every cache-transparency and latency-sweep configuration. If the baseline
run has failures, they predate this work: list them in the ledger under "Pre-
existing failures at G0". Only that explicit list is excluded from G1.

**G1: `GC_EN=0` transparency.** `make all-tests` with `GC_EN=0` (the default
until Phase 3; afterwards `PYCORE_GC_PLUSARGS=+GC_EN=0`). Pass: every result
and every `cycles=` value is identical to G0. No tolerance: `GC_EN=0`
promises today's hardware.

**G2: oracle self-validation.** `test_gc_model.py` in `make
pycore-python-tests`. The oracle `gc_model.py` is trusted only after it
agrees with a second, independent computation. For at least 500 seeded random
Python object graphs covering every row of §4.1 (lists with spare capacity;
dicts with tombstones, deleted values, and `None` keys; sets; tuples,
including empty and nested; instances with `__dict__`; types; bound methods;
cells; functions with closures; exceptions with args; code objects; ranges
in both modes; LONG_STR; bytearray; iterator values of every kind; cycles),
build a heap with `heap_image.py`, pick a random root subset, and compute the
expected live extents from **Python-level** reachability plus the builder's
placement records (extend `heap_image.py` to return an
`{object: (addr, extent)}` map if it does not already). Compare that with
`gc_model.py`'s traversal of the raw dmem image. Pass: identical live granule
sets for every seed, plus one directed case per row of §4.1.

**G3: engine unit testbench.** `make pycore-gc` runs `tb_gc.sv`: the RTL
engine alone over dmem images from G2's generator, at least 200 seeds plus
the directed cases, at every `CACHE_EN` and `MEM_LATENCY` setting the unit
memory model supports. Pass: the run list, `live`/`free`/`largest`, and the
mark-stack high-water mark equal `gc_model.py` for every seed; the overflow
guard fires with `GC_STACK_ENTRIES=16`; with the on-chip stack shrunk to two
entries, the spill and refill path runs and still matches.

**G4: oracle differential at every collection.** Every fixture in
`pycore-img-gc-all` runs with `+GC_DUMP_EACH`. Every existing fixture in
`pycore-img` and `pycore-img-two-core` runs with `+GC_AT_EXIT=1
+GC_DUMP_EACH`, so each gets at least one collection over a realistic heap.
For every dump, `gc_model.py --check` verifies:

- **Exact free set.** The free granules of the dynamic heap equal the
  complement of the oracle's reachable extents. A freed granule the oracle
  says is reachable is a safety bug; a retained granule it says is garbage is
  a precision bug. Both fail. This is Cloaca's "free set disjoint from
  reachable" plus its bounded-reclamation property, with a bound of one
  collection because the collector is precise and stop-the-world.
- **Independent roots.** The TB records the register and RF roots itself at
  `S_GC_ENTER`, by reading the RF ring and the §3.1 registers through
  hierarchical references, and writes them next to the dump. The oracle
  compares that set with `GC_ROOT_STASH`; any difference fails. It re-derives
  the memory-range roots (spill, frames, exception stack, boot record, native
  table, StopIteration sidecar) from the dump and the TB-read `spill_sp_r`,
  frame depth, and exception SP.
- **Counters.** `live`, `free`, `largest`, and `reclaimed` equal the oracle's
  values.
- **Run list well-formed.** Address-ordered; non-overlapping; maximal (no
  two runs adjacent); `FREE_MAGIC` and sizes correct; terminates; inside the
  dynamic heap.

Pass: zero discrepancies over all dumps, both tops, `CACHE_EN` 0 and 1.

**G5: shadow-heap use-after-free checker.** `gc_shadow_check.sv` is bound
into both tops and is on in every `GC_EN=1` gate run. It keeps one state per
dynamic-heap granule: `LIVE` (allocated since last freed), `FREE` (in a run
that is not the current run), or `FRESH` (in the current run, at or above
`heap_ptr_r`). The engine reports each freed range on a
`free_range_valid/base/len` debug port during the sweep. The checker also
tracks run switches and every `heap_ptr_r` advance or adoption (core, STRACC
`res_heap_ptr`, excore `RES_HEAP_PTR`). Any mutator access to a `FREE`
granule is a `$fatal` reporting address, master, pc, and opcode. Mutator
accesses are those on the core dmem port before L1D, the STRACC port, and the
excore slot port. The engine and the allocator's run-header accesses are
exempt. Pass: no fatal in any gate run, and the self-test (a TB-forced read
of a freed granule) does fire. `+GC_POISON=1` is on in every G7 mode (c) and
G8 run.

**G6: in-RTL invariants.** Simulation-only `$fatal` checks, always compiled
in. They must never fire:

- the engine writes only inside `[PYCORE_GC_META_BASE, DATA_LIMIT)` or into
  granules the sweep is freeing (run headers, poison);
- the engine never has more than one request outstanding;
- the mark-stack pointer stays within bounds, and the stack is empty when
  MARK ends;
- CODC and GIC hold no valid entry when `S_GC_ALLOC` exits;
- `gc_epoch_r` increments exactly once per collection;
- `heap_ptr_r <= heap_limit_r`, and `heap_limit_r` is either
  `PYCORE_HEAP_LIMIT` or the end of a run from the latest sweep;
  **Superseded:** a boundary or exit collection keeps the current run, so
  its end can come from an earlier sweep (§4.4 P8 note); the checked
  invariant is `heap_ptr_r <= heap_limit_r`;
- no `rf_we`, no `tos_r` change, and no mutator dmem write between
  `S_GC_ENTER` and the re-dispatch;
- once a CALL budget reservation succeeds, no allocation inside that CALL
  fails (§8 risk 4);
- `gc_bad_kind` and `gc_reserved_tag_seen` stay zero.

**G7: torture.** The whole `pycore-img` and `pycore-img-two-core` lists run
under each mode below. Results must equal the G0 goldens, and trap fixtures
must trap with the same code. G4 checks run on the first 20 collections of
every run; G5 and G6 are always on.

- (a) `+GC_EN=1 +GC_EVERY_N_RUNS=1 +HEAP_LIMIT=<small>`: a collection at
  every run switch, with the heap shrunk to static image + **2.5 ×** the
  fixture's peak live bytes (measured by the oracle in G4; the runner
  computes it per fixture). **Superseded:** 1.25 × packed peak, then 2 ×.
  Evidence: G8 seed 0 at 1.25 × ended with 14 KB free in 148 runs, largest
  hole 544 B, trap 7; 2 × PASSES that seed (largest 5056 B). G8 seed 2 at
  2 ×: live 63 KB, free 67 KB in 183 runs, largest 11 KB, trap 7; 2.25 ×
  PASSES (14 collections). Address-ordered first-fit after every run
  switch fills every death gap. Non-moving collection cannot recover that.
- (b) `+GC_AT_BOUNDARY_EVERY=K`: K=1 for every fixture in
  `pycore-img-gc-all`. For the rest, the runner picks a prime K per fixture
  so that each gets at least 50 boundary collections, or one at every
  boundary if it executes fewer than 50 instructions.
  **Superseded:** G7 (b) K=1 on bump-cursor identity fixtures. Evidence:
  `img_heap_mark_release` 0x2b67 vs 0x271b and `img_heap_release_stale_trap`
  expected trap 7 vs clean return under K=1 at f326e22 (§5.4). Those two
  run `GC_EN=1` without `GC_AT_BOUNDARY_EVERY`. Same for
  `img_gc_root_closure`: AT_BOUNDARY first-fit during the fill loop left a
  64 B hole while the junk chain was live (G7_b trap 7, G7 (a)/(c) pass).
  **Superseded membership:** 1000-iter `img_gc_steady_*`, the G13
  `img_gc_bench_*`, the G9 site-churn loops, the long rooting fixtures
  `img_gc_verify_closures`, `img_gc_root_closure`, `img_gc_root_frames`,
  and the fill-until-OOM loop `img_gc_live_exceeds_heap` are in
  `pycore-img-gc-sites` (still under `pycore-img`) rather than `gc-all`.
  Evidence: G7 (b) K=1 on `steady_list` ran 95 minutes at
  `MAX_CYCLES_SCALE=4980` without finishing; the three rooting fixtures were
  still running at 75–90 min on f326e22. `img_gc_live_exceeds_heap` at
  f50c813 ran 47+ minutes at `MAX_CYCLES_SCALE=11461` with
  `GC_AT_BOUNDARY_EVERY=1` (a collection of the growing live chain on every
  instruction) without reaching the expected trap 7.
  **Superseded:** 2.5× peak on `img_gc_fragmented_alloc`. Evidence: G7 (a)
  at 10b2ba8 set `HEAP_DYN_BYTES=67200` (first plusarg wins over the
  recipe's 40960). After the explicit collect the largest hole was 43648, so
  `[9] * 800` succeeded and the program returned 0. The recipe's 40 KB heap
  is what leaves the dropped 3.2 KB buffers as holes too small for that
  list (G7 (b) returned 1, largest hole 17600). Modes (a) and (c) still
  collect on every run; they keep the recipe heap.
- (c) mode (a) plus `+GC_POISON=1`.

The runner may set `+MAX_CYCLES_SCALE` for torture runs only.

**G8: randomized differential fuzzing.** `make pycore-gc-fuzz SEEDS=a..b`.
`gc_fuzz.py` generates programs that `make lint-file` accepts (README "What
programs are allowed"). They build, mutate, alias, and drop object graphs
across every pointer kind in §4.1 and every allocation site in §1.3: lists,
tuples, dicts with deletes and re-inserts, sets, instances and attributes,
closures and cells, bound methods, raised and caught exceptions with args,
LONG_STR and STRACC `split`/`join`/`replace`, iterators held across calls
and inside `__next__`, `*args` and `**kwargs`, recursion deep enough to
spill the RF, and `compile()`/`exec` of small snippets. Each program returns
a checksum of the surviving data, and host CPython provides the golden. Each
seed runs on both tops with the heap shrunk as in G7 (a), alternating G7
modes (a) and (b) by seed parity. Pass: in `MODE=full`, 1,000 consecutive
seeds per top with zero failures (`MODE=quick`: 50). The corpus coverage
report must show every §4.1 kind traced and every §1.3 row with a GC
integration allocated at least 100 times. On a failure: shrink the program
(delete statements while it still fails), commit it as `img_gc_fuzz_<seed>`
in its failing state, then fix.
  **Superseded:** row 18 (`DICT_MERGE` contaminated allocator) is not required
  on the two-core top. Evidence: `CONT_DICT_MERGE` in `pycore_cont_bulk.svh`
  states that valid programs emit `DICT_MERGE` only for call `**kwargs`,
  whose keys are strings, so the contamination bit is never set. With
  excore enabled that merge is row 19. CPython raises `TypeError: keywords
  must be strings` on `**{object: ...}`, so no host-runnable program can
  take the pycore allocator. Single-core still counts row 18, because
  `EXCORE_EN=0` runs the same string-key merge on PyCore.
  **Superseded:** unbounded `Q+Q` join / `replace("-","+-")`. Evidence: G8
  seed 67 measure at bea6135, live=311 KB, largest hole 148 KB, trap 7;
  seed 92 shrunk largest hole 36 KB with 336 KB free. Generator now slices
  those results to 48 characters. Seed 129's 3600 s AT_BOUNDARY timeout was
  the same doubling (marking 300 KB strings every 101 instructions); with
  the cap that seed finishes. Shrunk heap is at least 64 KB so a failed
  measure (peak=0) cannot shrink to 8 KB.

**G9: allocation-site abort coverage.** Using the `+GC_SITE_STATS=1`
counters aggregated over G7 and G8, every §1.3 row whose integration is
"alloc-phase abort", "CALL budget", or "grant protocol" shows at least 10
abort, collect, and re-dispatch events inside passing runs, on each top where
the site exists. Rows #1, #6, #13, #22, #32, and #36-39 do not allocate at
run time and are exempt (#32 is covered by `img_gc_mark_release_epoch`). The
runner prints the per-site table. Pass: no row below 10.

**G10: mutation testing.** Every mutant below is compiled into the RTL
(simulation only), selected with `+GC_MUTANT=<n>`, and inert at 0. `make
pycore-gc-mutants` runs the quick subset (§10.3) against each mutant and
records which gate killed it. Pass: 100% killed. A surviving mutant means
the suite is too weak. Write a fixture that kills it (`img_gc_mutant_<n>`);
never delete the mutant. After G1-G9 first pass, add at least 5 mutants of
your own, modelled on real bugs from the ledger's bug log, and kill those
too. If you believe a mutant cannot change behaviour, argue it in the ledger
and replace it with one that can.

| n | Deliberate bug | n | Deliberate bug |
| --- | --- | --- | --- |
| 1 | skip the RF resident ring | 20 | CODE_OBJECT: skip `co_consts` |
| 2 | skip the RF spill range | 21 | ITER kind 3: spill word not marked |
| 3 | skip frame descriptors | 22 | RANGE mode 1: tuple not marked |
| 4 | skip only the frame `globals_base` field | 23 | MUT_BYTEARRAY: buffer not marked (killed by G3) |
| 5 | skip exception-stack nodes | 24 | sweep: each free run swallows the first granule of the next live object |
| 6 | skip `active_exc_r` | 25 | bitmap not cleared between collections |
| 7 | skip the `container_call_saved_*` roots | 26 | `heap_limit_r` not updated on a run switch |
| 8 | skip `cur_closure_r` | 27 | run switch ignores the 64 B alignment slack |
| 9 | skip the boot record | 28 | skipped runs dropped instead of rebuilt |
| 10 | skip the native-method sidecar | 29 | no CODC/GIC flush |
| 11 | skip `cur_code_r` and `globals_base_r` | 30 | epoch not incremented |
| 12 | LONG_STR extent 16 B short | 31 | re-dispatch at the next instruction instead of the aborted one |
| 13 | list: trace elements `0..length-2` | 32 | STRACC `NEED_HEAP` treated as success |
| 14 | list buffer extent `length*32` instead of `capacity*32` | 33 | excore `MB_HEAP_LIMIT` stuck at `PYCORE_HEAP_LIMIT` |
| 15 | dict: order buffer not marked | 34 | CALL budget for the `**kwargs` dict one slot short |
| 16 | dict: TOMBSTONE-key slots traced as live | 35 | `UNPACK_EX` reorder reverted |
| 17 | dict: slots with a `None` key skipped | 36 | OOM loop guard and empty-list MEM_FAULT disabled |
| 18 | set: table not marked | 37 | mark-stack refill drops one entry |
| 19 | OBJECT: `ob_type` not traced | | |

**G11: steady state, no leaks.** The `img_gc_steady_*` fixtures (1,000
iterations each) and `img_gc_compile_loop` (64 compiles, retaining nothing)
run on both tops with at least 10 collections each. From the per-collection
log: over the last half of the collections, max `live` minus min `live` is
at most 1 KB for `steady_*` and at most 16 KB for the compile loop; and free
bytes after the last collection are at least free bytes after the first,
minus 1 KB.

**G12: architectural configurations.** With `GC_EN=1` (the default after
Phase 3): `make pycore-cache-transparency pycore-mem-latency-sweep` is green,
and G4 and G5 pass on `pycore-img-gc-all` at every (`CACHE_EN`,
`MEM_LATENCY`) in {0, 1} × {1, 4, 30} on both tops.

**G13: performance.** `make pycore-gc-bench` runs the `img_gc_bench_*`
fixtures and prints this table from the counter line. Measurements are at
`CACHE_EN=1 MEM_LATENCY=4` unless noted.

| ID | Metric | Target |
| --- | --- | --- |
| P1 | cycles of every existing fixture that does not collect, `GC_EN=1` vs G0 | identical (revised for fixtures that rewind with `_bi_heap_release`: identical with release zeroing disabled, and mutator cycles at most G0 + max(0.5%, 64 per zeroed line), zeroing at most 16 cycles per line + 64; `gc_progress.md` plan deviations) |
| P2 | fixtures that do collect: total cycles minus `total_pause`, vs G0 | at most G0 + 0.5% |
| P3 | mark-phase port utilisation `port_busy_mark / mark_cyc` on `bench_full` | at least 0.80 |
| P4 | sweep cost | at most 4 cycles per bitmap slot + 6 per free run |
| P5 | max pause on `bench_full` (about 600 KB live, about 20k objects) | at most 400k cycles; the `CACHE_EN=0 MEM_LATENCY=30` value is reported and must finish within the fixture cap |
| P6a | GC share of total cycles on `img_gc_compile_loop` | at most 2% |
| P6b | GC share on `bench_churn` (heap ≈ 3× live) | at most 25% |
| P7 | mark-stack spill traffic on `bench_full` and `bench_deep` | at most 5% of mark-phase transactions |
| P8 | run-list pops per allocation over the G8 corpus | at most 0.05 on average |

A target may be revised only when all three hold: (1) the counters show the
phase is memory-bound, meaning measured cycles are at most 1.10 × (the slot
transactions the algorithm must perform × the measured mean transaction
latency in that run); (2) at least one further optimisation was implemented
and measured after the target was first missed; (3) the ledger, this plan,
and `gc.md` record the numbers. Otherwise keep optimising. Also report the
engine's flop count and any on-chip SRAM bits in `gc.md` (Verilator
`--stats`, or Yosys `stat` if you can install it), and justify any on-chip
storage above 16 KB.

**G14: full regression and hygiene.** `make all-tests TEST_JOBS=<cores>` is
green with default settings (`GC_EN=1`). The shared simulator builds produce
no Verilator warnings beyond G0's list. Default runs print nothing new except
the one GC counter line.

**G15: independent review.** After G0-G14 pass, have a reviewer with no
context review `git diff origin/main...HEAD` against this plan. In Cursor,
launch the `bugbot` subagent (the human explicitly requests this review) with
`Diff: branch changes` and these custom instructions: "Review the GC
implementation against planning/gc_plan.md. Focus on missed roots, extent
formulas, abort-before-commit at every allocation site, cache coherence, and
weak tests." Any fresh agent will do if that subagent is unavailable. Answer
each finding with a fix plus a regression fixture, or a rebuttal with
evidence, in the ledger. Repeat until a full round produces zero correctness
findings. Record each round with `tools/gc_acceptance.py --record-review
<file>`, which appends to `planning/gc_reviews.md`: the reviewed commit, the
findings, and their resolutions. G15 passes when the latest round reported
zero correctness findings and reviewed a commit whose diff to the run's
`head` touches only `planning/gc_progress.md` and `planning/gc_reviews.md`.

**G16: docs and CI.** `pycore/docs/gc.md` covers: architecture and
interfaces, the root and traversal tables, the invariants, the prior-art
decisions with numbers, the G13 table, and a debugging guide (dumps, shadow
checker, mutants, torture plusargs). The companion docs listed at the top of
this plan are updated. The "Garbage collection" line in `README.md` "Still
open" is replaced with the as-built status and the code-RAM ceiling.
`planning/README.md` moves this plan to "Graduated". The new Makefile
targets are part of `all-tests`, and `.github/workflows/all-tests.yml` runs
the GC gates that fit CI budgets (add a `gc` job of at most 180 minutes if
needed). If `gh` is authenticated and a remote exists, open a PR and get CI
`all-tests` green; otherwise record that the local G14 run is the evidence.
The runner checks what it can mechanically: files and section headings
exist, the README line changed, and `all-tests` depends on the GC targets.

### 10.3 The acceptance runner

`tools/gc_acceptance.py`, run as `make pycore-gc-acceptance MODE=quick|full`:

- Runs G0-G16 in order. G0 validates the committed baseline file instead of
  re-running it.
- **Fails closed**: a missing target, missing file, unparsable output, or
  crash is `fail`.
- Has no skip flags in `full` mode. `--only G4,G5` exists for iteration and
  writes `"mode": "partial"`. Only `full` can satisfy the stop hook.
- Records `head` (`git rev-parse HEAD`) and `dirty` at the start. `dirty` is
  true if any tracked file is modified, or any untracked `.sv`, `.svh`, `.py`,
  `.s`, `.md`, `.json`, or `.yml` file or `Makefile` exists outside ignored
  paths. If `HEAD` moves during the run, the run is invalid.
- Writes `build/gc_acceptance/status.json`, one log per gate
  (`build/gc_acceptance/G<n>.log`), and a human-readable
  `build/gc_acceptance/report.md`. At start it deletes `runs/` and `dumps/`
  so G5/G6 only see this run (leftover G7_b INV logs from a killed
  MODE=full made MODE=quick G6 fail).
- `--record-review <file>` appends the G15 evidence to
  `planning/gc_reviews.md`.
- Order of the final steps: commit everything, run `MODE=full`, then commit
  only the ledger (and review log) with the result. Any other change after
  the run makes it stale.

```json
{
  "schema": 1,
  "mode": "full",
  "head": "<40-hex sha>",
  "dirty": false,
  "started": "<ISO-8601>",
  "finished": "<ISO-8601>",
  "gates": {
    "G0": {"status": "pass", "log": "build/gc_acceptance/G0.log", "summary": "..."}
  }
}
```

`status` is `pass`, `fail`, or `pending-phase-3`; only `pass` counts. The
`gates` object must contain all of `G0`..`G16`.

`MODE=quick` (the inner loop and the G10 per-mutant suite) runs: G1 on
`pycore-img` at the default configuration only; G2; G3; G4 and G5 on
`pycore-img-gc-all` on the single-core top; G6; G7 (a) on
`pycore-img-gc-all`; and G8 with 50 seeds on the single-core top.

`MODE=full` takes hours. Run it in the background with `TEST_JOBS` equal to
the core count and poll it. If it is too slow, parallelise it; never subset
it.

### 10.4 What the stop hook checks

`.cursor/hooks/gc_stop_gate.py` does nothing unless `.cursor/gc_task_active`
exists. When it does, and the agent stops with status `completed`, the hook
allows the stop only if `.cursor/gc_blocked.md` exists, or if all of these
hold: `status.json` has `mode` `full`; its `head` is `HEAD`, or an ancestor
of `HEAD` whose later commits touch only `planning/gc_progress.md` and
`planning/gc_reviews.md`; it has `dirty` false; the working tree is clean now
(no tracked changes and no untracked source files); and every gate
`G0`..`G16` is `pass` with a non-empty log file. Otherwise it sends a
follow-up message that lists the failures, and the agent continues. A stop
with status `aborted` or `error` (the human pressed stop, or the harness
failed) is always allowed.

### 10.5 Ledger template (`planning/gc_progress.md`)

```markdown
# GC implementation progress

Status: IN PROGRESS            <!-- IN PROGRESS | DONE | BLOCKED -->
Branch: gc/implementation
Current phase: R               <!-- R, 0, 1, 2, 3, 4, 5, 6 -->
Last acceptance run: <sha> <mode> <date> <passing gates>/17

## Handoff (overwrite every session)
- Done this session:
- In flight:
- Next command to run:

## Phases
| Phase | Status | Exit gates | Evidence (commit, run) |
| --- | --- | --- | --- |

## Decisions (Phase R and later)
| Item | Decision | Measurement | Commit |
| --- | --- | --- | --- |

## Bugs
| ID | Found by (gate, seed, mutant, review) | Regression fixture | Fix commit |
| --- | --- | --- | --- |

## Mutants
| n | Description | Killed by | Fixture added |
| --- | --- | --- | --- |

## Plan deviations
| Section | Old claim | Evidence | Commit that updated the plan |
| --- | --- | --- | --- |

## Pre-existing failures at G0
```
