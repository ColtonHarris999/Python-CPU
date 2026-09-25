# Cleanup report

A backlog of ways to make this repository simpler, written so that another
agent can pick up **one item** and finish it without reading the rest.
Every item cites evidence that was checked against `main` @ `7134b6d`
plus PR #132 (`exec` / `shell`), 2026-09-25. Re-check the evidence before you start, because the tree moves.

This report covers engineering cleanup only. Language and feature work is in
[`master_plan.md`](master_plan.md).

## How to use this report

- Take one item per PR. Items marked **Depends** need the listed item first.
- Most items change RTL, tools, or the `Makefile`, so the full CI hardware
  suite runs. You need a green `all-tests`, including `gates`, before the
  item is done. No Verilator? Then CI is your only check. Say so in the PR.
- A pure move or rename should produce **byte-identical** images. Where an
  item says so, prove it by diffing `build/img_*/program.hex`, `dmem.hex`,
  and `code_ram.hex` before and after on a few fixtures.
- When an item lands, **delete its section from this file** in the same PR,
  and update any doc the item names.
- Size: **S** is under a day, **M** is a few days, **L** is a week or more.
  Risk is about how likely the change is to break CI or behavior.

## Summary

| ID | Item | Size | Risk | Payoff |
| --- | --- | --- | --- | --- |
| [A1](#a1-replace-per-fixture-makefile-targets-with-a-manifest-and-one-runner) | Fixture manifest + one suite runner instead of ~460 Makefile targets | L | M | Very high |
| [A2](#a2-remove-string_hex-leftovers-and-the-41-_strhex-placeholders) | Remove `STRING_HEX` leftovers and 41 `_str.hex` placeholders | S | Low | Medium |
| [A3](#a3-wire-up-or-delete-orphan-targets-and-programs) | Wire up or delete orphan targets and programs | S | Low | Low |
| [A4](#a4-retire-boot_en0-hand-built-hex-fixtures) | Retire `BOOT_EN=0` hand-built hex fixtures | M | M | Medium |
| [A5](#a5-one-simulator-driver-for-every-runner) | One simulator driver for every runner | M | Low | High |
| [B1](#b1-stop-committing-generated-fixtures) | Stop committing generated fixtures | M | Low | Medium |
| [B2](#b2-delete-singlecorezip) | Delete `singlecore.zip` | S | Low | Medium |
| [B3](#b3-delete-dead-files) | Delete dead files (tools, RTL, testbench) | S | Low | Medium |
| [C1](#c1-retire-preprocesspy) | Retire `preprocess.py` | M | Low | Medium |
| [C2](#c2-split-image_from_sourcepy) | Split `image_from_source.py` into modules | M | Low | High |
| [C3](#c3-one-source-of-truth-for-machine-constants) | One source of truth for machine constants | L | M | High |
| [C4](#c4-make-the-python-tooling-one-package) | Make the Python tooling one package | S | Low | Medium |
| [D1](#d1-one-simulation-top-and-one-simulator-binary) | One simulation top and one simulator binary | M | M | High |
| [D2](#d2-remove-dead-ports-and-dead-opcodes) | Remove dead ports and dead opcodes | S | Low | Low |
| [D3](#d3-remove-the-container_call_spike_en-test-knob) | Remove the `CONTAINER_CALL_SPIKE_EN` test knob | S | Low | Low |
| [D4](#d4-break-the-core-into-modules-with-real-interfaces) | Break `pycore_core.sv` into modules with real interfaces | L | High | Very high |
| [D5](#d5-share-one-scan--probe-engine-for-contains-and-hash-lookups) | One scan/probe engine for CONTAINS and hash lookups | M | M | Medium |
| [D6](#d6-give-the-core-a-perf-counter-port) | Give the core a perf-counter port | S | Low | Medium |
| [E1](#e1-restructure-the-excore-firmware) | Restructure the excore firmware | M | Low | Medium |
| [F1](#f1-keep-a-firmware-py-file-only-when-it-ships) | Keep a firmware `.py` file only when it ships | S | Low | Medium |
| [F2](#f2-remove-the-step-d-toy-package) | Remove the step-D toy package | S | Low | Low |
| [G1](#g1-deduplicate-the-docs) | Deduplicate the docs | M | Low | Medium |
| [H1](#h1-build-the-ci-image-and-simulators-once) | Build the CI image and simulators once | M | M | High |
| [H2](#h2-one-dockerfile) | One Dockerfile | S | Low | Low |

**Suggested order.** Do the quick deletions first (A2, A3, B2, B3, D2, D3,
F2, H2). Then do the harness work in sequence: C1, B1, A4, A5, A1, D1, H1.
C2, C3, and C4 can run in parallel with the harness work. Leave D4 and D5
for last, once CI is fast enough to iterate on RTL.

---

## A. Build and test harness

### A1. Replace per-fixture Makefile targets with a manifest and one runner

**Problem.** The `Makefile` is 3 252 lines (118 KB), and almost all of it
describes test fixtures:

- 461 `pycore-img-*` targets, each a one-line `$(call …)`. Of these, 279
  call `PYCORE_IMAGE_RUN`, 86 call `PYCORE_IMAGE_RUN_TWOCORE`, 60 call
  `PYCORE_IMAGE_TRAP_RUN`, 14 call `PYCORE_EXCORE_RUN`, and the rest use
  eight other variants.
- Twelve `define` recipes that are near copies of each other: build an
  image, then `awk` four fields out of `image.meta`, then run the simulator.
  The `awk` block is pasted 17 times.
- The suite lists (`pycore-img`, `pycore-img-two-core`, `pycore-container`,
  `pycore-excore-system`) and a 200-line `.PHONY` list are kept by hand.
  An earlier review already found two targets reachable from no suite
  (A3).
- The build-directory race fixed in `9018ea5` (two suites writing the same
  `build/img_<name>/`) was only possible because every fixture is hand-wired.

**Change.**

1. Describe each fixture with its program. Either use a header pragma in
   the `.py` file (the image builder already parses `# pycore-seed` pragmas,
   see `parse_seed_pragmas`), or add one manifest file,
   `pycore/programs/fixtures.toml`. A fixture record needs: program, suites
   (`img`, `two-core`), `max_cycles`, the expectation (host golden, trap
   code, or stdout file), and any extra plusargs.
2. Add `pycore/tools/run_suite.py --suite img --jobs N [--filter GLOB]`. It
   builds each image into `build/<suite>/<name>/`, runs the shared simulator
   binary (`tools/ensure_sim.py`) with plusargs, and prints a pass/fail
   table. It exits non-zero on any failure.
3. Keep the `make` entry points that CI and `README.md` use (`pycore-img`,
   `pycore-img-two-core`, `pycore-container`, `pycore-excore-system`,
   `pycore-cache-transparency`, `pycore-mem-latency-sweep`) as thin wrappers.
   Add `make pycore-fixture NAME=<name>` to run a single fixture.
4. Generate the manifest **mechanically** from the current `Makefile` with a
   throwaway script. Do not retype it.

**Depends.** Build the runner on A5's shared driver.

**Verify.** Before deleting any target, show that the runner executes the
same set of (program, topology, `max_cycles`, expectation, extra plusargs)
tuples as the old `Makefile`: dump both sets and diff them. Then CI
`all-tests` must be green, with the same number of fixtures per job.

**Risk.** Medium. CI job names and `README.md` depend on the wrapper target
names, so keep those names.

### A2. Remove `STRING_HEX` leftovers and the 41 `_str.hex` placeholders

**Problem.** `pycore_string_mem.sv` is gone, and so is the RTL `STRING_HEX`
parameter. What survives:

- `Makefile`: `PYCORE_STRING_HEX` and `--string-hex` on `pycore-preprocess`.
- 41 files `pycore/programs/*_str.hex`, each containing only `00`. They are
  written by `gen_excore_integration_fixtures.py`,
  `gen_list_append_fixtures.py`, and `gen_list_extend_fixtures.py`, and
  nothing reads them.

This is §4 of the archived `planning/old/p5_review_followup.md`.

**Change.** Delete the 41 files and the three generator lines that write
them. Remove `PYCORE_STRING_HEX`. If C1 lands first, the `--string-hex`
flag goes away with `preprocess.py`.

**Verify.** `grep -rn "_str.hex\|STRING_HEX"` returns nothing outside
`planning/old/`. CI `container` and `two-core` are green.

### A3. Wire up or delete orphan targets and programs

**Problem.**

- `pycore-img-allocator-bytes` is defined but in no suite. Its comment says
  the image build fails until `bytearray` / `int.from_bytes` exist
  (`planning/old/p5_review_followup.md` §5).
- `pycore-allocator-host` only runs from `docker-python-tests`, not from
  `make all-tests`.
- `pycore/programs/mixed_arith.py` is referenced by nothing.

**Change.** Delete `pycore-img-allocator-bytes` and keep
`allocator_bytes.py` as a host-only smoke test, or move it to a
`pending/` folder that the runner skips. Turn `pycore-allocator-host` into a
unittest under `pycore/tests/` so `pycore-python-tests` covers it. Delete
`mixed_arith.py`, or give it a fixture.

**Verify.** `make all-tests` covers the same fixtures as before, apart from
anything you deliberately deleted.

### A4. Retire `BOOT_EN=0` hand-built hex fixtures

**Problem.** Image boot is the only production path. Still, 6 fixtures run
through `PYCORE_CONTAINER_RUN` (`+BOOT_EN=0`, hand-built hex), and 4 through
`PYCORE_CONTAINER_BOOT_RUN` (committed hex plus a `.meta` file). The
`Makefile` comment says the `BOOT_EN=0` hex is "RF-ring-fragile", and says
`tuple_empty` and `list_oom` stay hex only because of how they were first
written. `BOOT_EN` is threaded as a parameter and plusarg through
`pycore_core.sv`, both system tops, and `tb_container.sv`.

**Change.** Rewrite each remaining hex fixture as an `img_*` program. For
`list_oom`, use a seed pragma or `+HEAP_INIT_PTR` to start the heap near
the limit. For `tuple_empty`, `()` as a constant already works through
image boot. Then delete the fixtures, and make `BOOT_EN=1` the only mode.

**Depends.** Easier after C1 (`preprocess.py` produced some of these
fixtures).

**Verify.** CI `container` green with the same expectations as before.

### A5. One simulator driver for every runner

**Problem.** Three separate pieces of code now build an image and drive the
shared `tb_container` binary, each with its own copy of the same plumbing:

| Runner | Where the plumbing lives |
| --- | --- |
| `make pycore-img-*` | 12 `define` recipes in the `Makefile`, which `awk` fields out of `image.meta` and spell out the plusargs |
| `pycore_cli.py run` | `ENSURE_SIM` / `SIM_TWOCORE_BIN` constants (lines 56–58), `_parse_meta` (354), its own plusarg list (around 408) |
| `pycore_exec.py` (`exec` / `shell`, PR #132) | The same two constants again (35–36), a second `_parse_meta` (204), and a second plusarg list (452–467) |

On top of that, `pycore_exec.py` reads results by matching free-form
`$display` text with regexes (`_PASS_RE`, `_TRAP_RE`, `_TIMEOUT_RE`,
`_PERF_RE`, `_MARK_RE`, …). Any wording change in `tb_container.sv`
silently breaks it.

**Change.** Add `pycore/tools/sim_driver.py` with three functions: build an
image into a work directory and return its paths and metadata; turn
metadata plus options into plusargs; run the binary and return a parsed
result (pass/trap/timeout, cycles, perf counters). Have
`tb_container.sv` print its end-of-run facts as one machine-readable
`RESULT key=value …` line, and parse only that. Port `pycore_cli.py run`
and `pycore_exec.py` to the driver. A1's suite runner is then the third
client instead of a third copy.

**Verify.** `test_pycore_exec.py` and `test_pycore_cli.py` green.
`make run-file` and `make exec-file RUN_SOURCE=pycore/programs/demo_exec.py`
give the same verdicts as before.

---

## B. Tree hygiene

### B1. Stop committing generated fixtures

**Problem.** `pycore/programs/` has 105 `.hex` and 20 `.meta` files,
generated by `gen_excore_integration_fixtures.py`,
`gen_list_append_fixtures.py`, `gen_list_extend_fixtures.py`, and
`gen_for_iter_fixtures.py`. The `Makefile` reruns those generators during a
test run (`pycore-excore-integration-fixtures`, and so on), which rewrites
tracked files in the source tree. This was Opt-7 in the archived
`optimization_plan.md`.

**Change.** Point every generator's output directory at
`build/fixtures/`, point the run recipes there, and delete the committed
outputs. Keep only the generator scripts.

**Verify.** `git status` is clean after `make all-tests`. CI green.

### B2. Delete `singlecore.zip`

**Problem.** `singlecore.zip` at the repo root is 467 KB and holds 467
entries, including two nested `.git/` directories (`singlecore/.git/` and
`singlecore/singlecore/.git/`). The seven files the excore actually uses
are already vendored in `excore/rtl/singlecore/`, and that folder's
`README.md` says they came from this zip.

**Change.** `git rm singlecore.zip`. In `excore/rtl/singlecore/README.md`,
record where to get the zip back: commit `e2b19bb`, "Add files via
upload".

**Verify.** Nothing references it (`grep -rn singlecore.zip`). CI `excore`
and `two-core` are green.

### B3. Delete dead files

Each file below was checked with `grep` for references across the repo,
excluding `planning/old/`.

| File | Why it is dead |
| --- | --- |
| `tools/dump_hex.py` | Referenced nowhere |
| `pycore/tools/cosim_trace.py` | Parses `opcode=` / `unit=` / `trap=` trace lines that no testbench or RTL prints |
| `pycore/tb/tb_pycore_runfile.sv` | No `make` target builds it. `run-file` uses `tb_container` |
| `pycore/rtl/pycore_code_mem.sv`, `pycore_code_ram.sv`, `pycore_imem.sv`, `pycore_dmem.sv` | Listed in `PYCORE_RTL_SRCS` but never instantiated. Only the first two instantiate the other two. The live path is `pycore_mem_hier` → `pycore_ram.sv` (see `pycore/rtl/attic/README.md`). Keep `pycore_mem_bank.sv` / `pycore_mem_block.sv`, which the excore and `tb_mem_bank` use |
| `pycore/rtl/attic/` | A design study superseded by the RF ring. Git history keeps it |

**Change.** Delete the files and remove them from `PYCORE_RTL_SRCS`.
Update the docs that mention them: `pycore/docs/architecture.md`
("Code memory regions"), `pycore/docs/code_loading.md`, and the P8 note in
`architecture.md` that points at the attic.

**Verify.** CI `rtl-unit` (runs `tb_mem_bank`), `img`, and `two-core` are
green.

---

## C. Host tooling

### C1. Retire `preprocess.py`

**Problem.** `pycore/tools/preprocess.py` (660 lines) is the pre-image-boot
flow. Every doc calls it deprecated. It is still carried by:

- `make pycore-preprocess`, which no suite runs, plus the
  `PYCORE_PROGRAM_HEX` / `PYCORE_TYPES` / `PYCORE_CACHE_MAP` variables.
- `test_preprocess_containers.py`, `test_preprocess_strings.py`, part of
  `test_heap_image_and_constants.py` (which uses `preprocess.tag_constant`,
  `emit_instruction_words`, and `infer_types`), and a drift check in
  `test_analyze_bytecode.py` (`preprocess.SUPPORTED_OPS`).
- The `allow_containers=False` branch and "legacy aliases" in
  `encoding.py`, and re-exports in `bytecode_common.py`.

**Change.** Move any helper a live test still needs (for example
`tag_constant`) into `heap_image.py` or `encoding.py`. Delete
`preprocess.py`, its two dedicated test files, the preprocess half of
`test_heap_image_and_constants.py`, and the `Makefile` target and
variables. Point the `test_analyze_bytecode.py` drift check at
`image_from_source._is_supported_opname`, which is the gate that matters.
Remove `encoding.py` code that only `preprocess.py` used.

**Verify.** `make pycore-python-tests` green. Then
`grep -rn preprocess pycore/tools pycore/tests Makefile` should hit only
the analyzer's docstring about "pre-preprocessing" bytecode (reword it).

### C2. Split `image_from_source.py`

**Problem.** `pycore/tools/image_from_source.py` is 3 786 lines with 82
top-level definitions, covering at least six jobs:

| Lines (approx.) | Job |
| --- | --- |
| 238–445 | Opcode gate and validation |
| 444–650 | `_ImageSerializer` |
| 646–870 | Seed specs and seed pragmas |
| 870–1250 | Host folds: slice constants, function defaults |
| 1250–1500 | Globals seeding, the `ROM_FIRMWARE_BUILTINS` table, the `_PYC_ENTRY` trampoline |
| 1500–2375 | Host stand-ins for the device runtime: `_bi_print`, `_bi_exec_globals`, `_HostEmittedCode`, `_HostCodeRam`, `_bi_code_*`. This is ~870 lines that exist so the firmware compiler can run under CPython |
| 2375–2840 | Firmware-package / ROM builtin / native-method seeding and the builtins dict |
| 2915–3255 | **Test-only** bytecode injection pragmas (LFAC, `SET_ADD` seq, `MAP_ADD` seq) that synthesize opcodes CPython will not emit |
| 3256–3634 | Module-level class folding |

**Change.** This is a pure move. Create `image_validate.py`,
`image_serialize.py`, `image_folds.py`, `image_seed.py`, `host_runtime.py`,
and `image_test_injects.py`. Keep `image_from_source.py` as the CLI and
orchestrator. It re-exports the old names so that tests and
`pycore_cli.py` keep working, and you can migrate their imports afterwards.

**Verify.** Host tests green, plus **byte-identical** `program.hex` /
`dmem.hex` / `code_ram.hex` for a sample of fixtures before and after
(for example `img_smoke`, `img_compile_grammar`, `img_class_*`,
`img_for_iter_all`).

### C3. One source of truth for machine constants

**Problem.** Shared constants are typed by hand in three places:

- `pycore/rtl/pycore_defs.svh` (3 713 lines),
- `pycore/tools/encoding.py` (15 "mirror …" comments: memory map, `BI_*`
  ids, `OBK_*` kinds, cache geometry, native-method table),
- the `.equ` lines at the top of the excore firmware. 72 of its 119
  `.equ`s mirror RTL values (mailbox and MMIO offsets, trap codes, tags,
  `MUT_*`, `OBK_BUILTIN`, `BI_PRINT`, `HEAP_LIMIT`). The other 47 are
  firmware scratch slots.

`test_memory_map_mirror.py` exists only to catch drift, and only for the
memory map. A fourth consumer arrived with PR #132: `pycore_exec.py`
(`trap_names`, `hardware_limits`) regex-parses `pycore_defs.svh` at run
time to get trap names, the code-RAM limit, and the heap limit. The repo already has the right pattern:
`gen_compiler_tables.py` generates `pycore_firmware/compiler/tables.py`
from `pycore.json`, and `test_compiler_tables_fresh.py` checks it is
current.

**Change.** Put the shared constants (memory map, trap codes, `BI_*`,
`OBK_*`, tags, object sizes) in one machine-readable file, for example
`pycore/targets/machine.json` or a new section of `pycore.json`. Generate a
`pycore_machine.svh` that `pycore_defs.svh` includes, a
`machine_constants.py` that `encoding.py` imports, and an excore `.equ`
include. Add a freshness test, and drop `test_memory_map_mirror.py` once
the generator covers it.

**Verify.** Byte-identical images. The generated `.svh` must elaborate to
the same values: CI `rtl-unit` and `img` green.

**Risk.** Medium, because it touches every consumer. Land it one constant
family at a time (memory map first).

### C4. Make the Python tooling one package

**Problem.** `pycore/tools/` has no `__init__.py`. Tests import it two ways:
14 test files use `from pycore.tools import X` (a namespace package), while
the rest rely on `PYTHONPATH=pycore/tools` flat imports or `sys.path`
edits. 37 separate Python 3.14 version checks are scattered across tools and
tests. Meanwhile `tools/` at the root holds one live script
(`ensure_sim.py`) and one dead one (B3).

**Change.** Add `pycore/__init__.py` and `pycore/tools/__init__.py`, and
switch every import to `from pycore.tools import …`. Put one
`require_python_3_14()` in a shared module and call it once per entry
point. Move `tools/ensure_sim.py` to `pycore/tools/`. `pycore_cli.py` and
`pycore_exec.py` each hard-code its path, so update both, or do A5 first so
there is one place. Drop `PYTHONPATH=`
from the `Makefile`.

**Verify.** `python3.14 -m unittest discover -s pycore/tests` passes with no
`PYTHONPATH` set.

---

## D. RTL

### D1. One simulation top and one simulator binary

**Problem.** There are two system tops. `pycore_system.sv` is the legacy
single-core top. `pycore_excore_system.sv` already has an `EXCORE_EN`
parameter that ties the mailbox off. `tb_container.sv` wraps both in a
`generate if (EXCORE_EN)` so that hierarchical references resolve under
`g_dut.dut.core.*`. CI therefore compiles two full Verilator binaries
(`build/sim_img`, `build/sim_img_twocore`) and runs the same fixtures on
each. The `Makefile` has parallel `_TWOCORE` copies of most recipes.

**Change.**

1. Delete `pycore_system.sv` and instantiate `pycore_excore_system` with
   `EXCORE_EN=0` for the single-core runs.
2. Then make excore enable a **plusarg** (`+EXCORE_EN=`) that holds the
   excore in reset and ties off the mailbox, so that one binary serves both
   topologies.

**Verify.** After step 1: CI green. After step 2: both suites green from
one binary, with a clearly shorter CI wall time. Report the numbers in the
PR.

A related wrinkle: the console capture and the PR #132 `+PHASE_MARKS`
handling in `tb_container.sv` live inside the two-core branch of the
`generate`, so `exec` / `shell` only work on the two-core binary. With one
top, they work everywhere.

**Depends.** Much simpler after A1, because the runner then picks the
topology per fixture.

### D2. Remove dead ports and dead opcodes

**Problem.**

- `pycore_decode.sv` drives `decoded_valid_o`, `push_stack_o`,
  `pop_stack_o`, and `decoded_pc_o`, and `pycore_core.sv` leaves all four
  unconnected (around line 720).
- `pycore_regfile.sv` still has `push_stack_i` / `pop_stack_i` and a
  `case` on them, while the core ties both to `1'b0` (around line 1489).
- `PY_OP_MEM_LOAD_PTR` / `PY_OP_MEM_STORE_PTR` (opcodes 200 and 201) are
  internal test opcodes "so test streams can exercise the dmem datapath".
  No testbench, program, or tool emits them any more, but they still have
  arms in `pycore_decode.sv` and `pycore_core.sv`.

These were Opt-3 and Opt-4 in the archived `optimization_plan.md`.

**Change.** Remove the ports, the `case`, and the two opcodes. Update
`tb_regfile.sv` and the "Execution fabric" section of `architecture.md`.

**Verify.** CI `rtl-unit` and `img` green.

### D3. Remove the `CONTAINER_CALL_SPIKE_EN` test knob

**Problem.** The core has a test-only parameter and plusarg,
`CONTAINER_CALL_SPIKE_EN`. It launches `S_CALL` from `S_CONTAINER` for a
one-off "§6.1 spike". It is threaded through `pycore_core.sv`, both system
tops, and `tb_container.sv`. Its only users are one fixture
(`img_container_call_spike`), one custom generator
(`gen_container_call_spike.py`), and one `Makefile` recipe.

**Change.** If the path it proves (container → CALL → container) is now
covered by real programs, such as the native `__len__` method via `BI_LEN`,
or comprehensions calling functions, delete the knob, the fixture, the
generator, and the recipe. If it is not covered, replace it with a real
program that exercises the path.

**Verify.** CI `img` green.

### D4. Break the core into modules with real interfaces

**Problem.** `pycore_core.sv` is 3 515 lines. It textually `include`s nine
fragments **inside one sequential block**:

| Fragment | Lines |
| --- | --- |
| `pycore_call_fsm.svh` | 4 849 |
| `pycore_cont_list.svh` | 3 187 |
| `pycore_cont_object.svh` | 2 680 |
| `pycore_cont_dict.svh` | 2 424 |
| `pycore_cont_bulk.svh` | 1 561 |
| `pycore_cont_raise.svh` | 498 |
| `pycore_cont_closure.svh` | 373 |
| `pycore_cont_exc.svh` | 293 |
| `pycore_cont_str.svh` | 266 |

That is about 20 000 lines of one process. The fragments read and write
core-local registers directly (146 distinct `call_*_r` / `container_*_r`
registers, over 500 `logic` declarations in the core), so none of them can
be linted, unit-tested, or reviewed alone. `container_op_r` is 6 bits wide
and 56 of its 64 codes are used. The archived review found a real bug
(§1 of `p5_review_followup.md`) that existed because two phases of the same
FSM needed the same string-equality escalation, and only one of them had
it.

**Change.** Do this incrementally, one PR per step, each with CI gates
green:

1. Define the interface the fragments actually use: an RF read/write port,
   the dmem request port, trap pulse and code, heap pointer, TOS/locals
   updates, and a done handshake. Write it down in `architecture.md`.
2. Move one small family (`cont_str` or `cont_closure`) into its own module
   behind that interface. Prove it with byte-identical retired results and
   unchanged cycle counts on the fixtures that use it.
3. Repeat for list, dict, object, bulk, raise, and exc. Do the CALL FSM
   last.
4. Once the families are modules, dispatch per family, so the 6-bit
   `container_op_r` does not have to grow.

**Risk.** High, which is why this is incremental. Run
`pycore-cache-transparency` and `pycore-mem-latency-sweep` on every step.

**Depends.** H1 (a faster CI loop), D2, and D6 first. D6 matters
because the testbench reads core internals by hierarchical name, and
moving logic into submodules would break those paths.

### D5. Share one scan / probe engine for CONTAINS and hash lookups

**Problem.** `CONT_CONTAINS_LIST` and `CONT_CONTAINS_TUPLE` sequence nearly
the same linear scan. The dict and set probe loops (`CP_DICT_CHK_VAL`,
etc.) duplicate open-addressing control, and the probe mask
(`hash & (slot_count - 1)`) is computed inline at several sites. The
three-tier string equality escalation (`container_stracc_*`) is gated per
phase, which caused the §1 bug in `p5_review_followup.md`. This was Opt-2
and Opt-9 in the archived `optimization_plan.md`.

**Change.** Write one parameterized scan/probe sub-FSM (base, length,
stride, equality mode, including the STRACC tier-3 escalation) and one
probe-index helper, and use them from list, tuple, dict, and set.

**Depends.** Best done as part of, or after, D4.

**Verify.** CI green, with no cycle regression on `img_str_dict_*`,
`img_*contains*`, and `img_dict_*`.

### D6. Give the core a perf-counter port

**Problem.** `tb_container.sv` reads 19 signals inside the core by
hierarchical path (`g_dut.dut.core.state_r`, `.latch_instr`,
`.rf_spill_count_r`, `.codc_hit_count_o`, `.fetch.mem_req_count_r`, …).
PR #132 added more, and it copies the core's state encodings into the
testbench by hand:

```systemverilog
localparam logic [4:0] CORE_S_TRAP_MARSHAL = 5'd10;   // tb_container.sv
localparam logic [4:0] CORE_S_TRAP_WAIT    = 5'd11;
```

These must match the `localparam`s in `pycore_core.sv`. If a state is
renumbered, or D4 moves logic into a submodule, the counters silently count
the wrong thing, or the build breaks.

**Change.** Add a `perf_o` struct output to `pycore_core` (instructions
issued, excore-wait cycles, RF spill count, fetch counters, CODC/GIC
counters) that is maintained inside the core, and route it out through
`pycore_excore_system`. The testbench then reads only ports. Delete the
copied state constants.

**Verify.** The `PERF` / `PHASE_MARK` numbers from
`make exec-file RUN_SOURCE=pycore/programs/demo_exec.py` are unchanged.
CI green.

---

## E. excore firmware

### E1. Restructure the excore firmware

**Problem.** `excore/fw/list_grow.s` is 2 953 lines of hand-written RV32
assembly. It holds **all** the firmware: list grow, extend, and delete;
dict grow, update, and merge; set grow and update; the builtin call; and
print. The file is named after the first handler. The handlers are written two
ways. The dict, set, and builtin handlers call shared `sp_read` /
`sp_write` helpers, 71 times in all. The three list handlers
(`do_list_grow`, `do_list_extend`, `do_list_delete`) instead open-code 72
`poll_*` busy-wait loops on the same MMIO handshake. The assembler (`excore/tools/asm_rv32.py`) supports `.equ` and
`.word`, but has no `.include` or `.macro`.

**Change.**

1. Rename the file to `excore/fw/excore_fw.s`, and update
   `EXCORE_FW_SRC` / `EXCORE_FW_HEX` and `excore/docs/`.
2. Add `.include` to `asm_rv32.py` and split the file into one file per
   handler plus a shared `mmio.s`.
3. Rewrite the three list handlers to use the existing `sp_read` /
   `sp_write` helpers instead of inline `poll_*` loops.

Steps 1 and 2 must produce a **byte-identical** hex. Step 3 changes code
size and cycle counts, but not results.

**Verify.** `make excore-asm-tests`, CI `excore` and `two-core` green, and
a hex diff for steps 1 and 2.

---

## F. Firmware and compiler

### F1. Keep a firmware `.py` file only when it ships

**Problem.** `pycore_firmware/builtins/` has 86 `.py` files, but the image
seeds only 32 stems (`ROM_FIRMWARE_BUILTINS`), plus the native-method
table. The rest:

- 27 stubs whose body is `return 1 % 0` (`open`, `super`, `hash`,
  `property`, …). They are **not seeded**, so calling one is a
  missing-name trap, not the trap 3 the stubs suggest.
- 14 non-stub files that are also not seeded: `callable`, `chr`, `float`,
  `int`, `iter`, `len`, `max`, `next`, `ord`, `range`, `repr`, `set`,
  `str`, `vars`. Several of these are hardware-native (`BI_*`), so the
  `.py` is a reference body that never runs.
- `native_method_retired.py`, a placeholder for retired native-method
  slots.

The status of every name is already recorded in `builtins.md`.

**Change.** Keep a `.py` only if it is seeded, or is on a stated near-term
path. Delete the 27 stubs, and keep their blocker notes in `builtins.md`
and the per-name `.md` files. For the unseeded reference bodies, either
seed them as the miss path, or delete them and say "native" in
`builtins.md`. Add a host test asserting that every `.py` in the folder is
seeded (or listed in an explicit allowlist).

**Verify.** Host tests green. Byte-identical images: nothing that was
seeded changes.

### F2. Remove the step-D toy package

**Problem.** `pycore_firmware/compiler/toy.py` (`_pyc_inc`, `_pyc_add`) and
the `_PYC_ENTRY` trampoline (`image_from_source._pyc_entry`, bound in every
boot builtins dict) are scaffolding from compiler step D. They are still
seeded into code RAM and the package dict of every image, and three tests
pin them (`test_firmware_package.py`, `test_compiler_compile.py`,
`img_pyc_package_call`).

**Change.** Delete `toy.py`, `_pyc_entry`, and the `_PYC_ENTRY` binding. Retarget
`img_pyc_package_call` at two real compiler helpers, or delete it:
`img_compile_*` already covers cross-helper calls inside `_PYC_G`.

**Verify.** Host tests green. `make pycore-size-report` shows a few slots
freed. CI `img` green.

---

## G. Documentation

### G1. Deduplicate the docs

**Problem.** The same facts are maintained in several places:

- The root `README.md` repeats the tag table (`pycore/docs/tags.md`), the
  trap table (`architecture.md`, `excore/docs/firmware_build.md`), and the
  container ownership split (`architecture.md`).
- `pycore/docs/architecture.md` (965 lines) repeats list/dict/set layout
  and excore details from `object_model.md`, `dict_excore.md`, and
  `set_excore.md`.
- `pycore/docs/preprocessing_breakdown.md` and the "CPython image fidelity
  boundary" section of `architecture.md` are the same text.

Each duplicate has drifted at least once. For example, the README trap
table listed six excore traps while the firmware handles more.

**Change.** Make the README a short overview that links to the docs. Give
each fact one home, and have other pages link to it. Merge
`preprocessing_breakdown.md` into a section of `code_loading.md` (or
rename it `image_build.md`). Split `architecture.md` into two-core
transport, core FSM, and heap/containers, if it stays over about 500 lines.

**Verify.** A markdown link check passes (see "Checking links" below).
Nothing in `pycore/docs/` contradicts `pycore.json`.

---

## H. CI

### H1. Build the CI image and simulators once

**Problem.** Every job in `.github/workflows/all-tests.yml` calls
`make docker-*`, and each of those starts with `docker build`. So seven
parallel jobs build the same image. The `container`, `img`, and `gates`
jobs each compile the single-core Verilator simulator from scratch, and
`two-core` compiles the other. `gates` runs five serial full `pycore-img`
passes (the `CACHE_EN` × `MEM_LATENCY` sweep) and needed its timeout raised
to 180 minutes in `4d62c75`.

**Change.**

1. Build the image once per run, using `docker/build-push-action` with the
   GHA cache, or publish it to GHCR keyed on the `Dockerfile` hash.
2. Build `sim_img` / `sim_img_twocore` once in a `build-sim` job, and hand
   them to the others with `actions/upload-artifact`.
3. Turn `gates` into a matrix of the five (`CACHE_EN`, `MEM_LATENCY`) arms.

**Verify.** Same jobs green. Wall time and total runner minutes go down.
Put before/after numbers in the PR.

**Depends.** D1 step 2 would remove the second simulator entirely.

### H2. One Dockerfile

**Problem.** `Dockerfile` and `.cursor/Dockerfile` both start from
`python:3.14-slim` and install Verilator, but they have drifted. Only the
`.cursor` copy installs `git`, `curl`, and `ca-certificates`, and only it
documents that Verilator **5.032** is required: the RTL slices
function-call return values, which Ubuntu's 5.020 package does not support.

**Change.** Keep one `Dockerfile` with the union of both package lists and
the version comment. Point `.cursor/environment.json` at it.

**Verify.** `make docker-build` works, and CI green.

---

## Checking links

The doc items (G1, and every item that moves or deletes a file) should
leave no broken relative links. This one-off check was used when this
report was written:

```bash
python3 - <<'EOF'
import re, pathlib
bad = 0
for md in pathlib.Path(".").rglob("*.md"):
    if any(p in md.parts for p in (".git", "vendor", "build")):
        continue
    for m in re.finditer(r"\]\(([^)\s#]+)(#[^)]*)?\)", md.read_text()):
        t = m.group(1)
        if re.match(r"^[a-z]+:", t):
            continue
        if not (md.parent / t).exists():
            bad += 1
            print(f"{md}: {t}")
print("broken:", bad)
EOF
```
