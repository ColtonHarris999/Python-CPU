# MicroPython microcontroller core

Status: **phase 0 and the phase 1 host image are in tree.** No `mpycore` RTL yet.
Pinned oracle: MicroPython `v1.29.0` (`0fd6c573`), `.mpy` version 6.3, object repr A.
Audit snapshot when this plan was written: `main` @ `371dc00`, 2026-10-13.

The product use case is changing from a CPython 3.14 bytecode research CPU
to **MicroPython on a microcontroller-style core**. This file is the
roadmap for that switch. The CPython hart stays in the tree and stays
green. New feature work happens in a sibling `mpycore/` tree. Nothing
in `pycore/rtl/` is retargeted in place.

[`master_plan.md`](master_plan.md) remains the leftover list for the
CPython hart. Do not start a track there unless this plan says the hart
still needs it.

## Where the truth lives

```text
planning/micropython_mcu_plan.md   this switch (product direction)
planning/master_plan.md            leftover CPython-hart work, frozen for features
        │
        ▼
mpycore/docs/*                     the new machine, written as each phase lands
mpycore/targets/mpycore.json       opcode / repr / memory-map catalog (phase 0)
vendor/micropython                 pinned oracle (phase 0 submodule)
        │
        ▼
pycore/docs/*                      the CPython hart as built; still accurate
```

Do not copy MicroPython opcode lists or object bit-masks into this file.
Phase 0 records them from the pinned release into
`mpycore/targets/mpycore.json`. On `v1.29.0` the opcode defines live in
`py/bc0.h`, the prelude layout in `py/bc.h`, the object-word masks in
`py/obj.h`, and the `.mpy` version in `py/persistentcode.h`.

## What is being built

A 32-bit core whose instruction stream is a pinned MicroPython bytecode,
whose data memory is a few hundred kilobytes of tightly coupled SRAM, and
whose peripherals are memory-mapped. Programs arrive as frozen `.mpy`
modules. The golden output is that release's unix port.

v1 is a single hart. Container growth is a command FSM on that hart. A
timer or UART interrupt is noticed at the next bytecode boundary and runs
a frozen callback. Float, long integers, an on-device compiler, and
generators are later decisions, each with its own exit test.

## Audit of the machine at `371dc00`

The hart that exists is a research CPU. Its ISA is a CPython 3.14
wordcode subset. These are the facts the switch has to account for.

### Datapath and instruction encoding

| Fact | Where |
| --- | --- |
| Value is 128 bits, tag is 4 bits, register entry is 132 bits | `PYCORE_VAL_WIDTH`, `PYCORE_TAG_WIDTH` in `pycore/rtl/pycore_defs.svh` |
| Register file is 256 entries, live window 240, spill to a 256 KB LIFO at `0xF40000` | `PYCORE_RF_DEPTH`, `memory_hierarchy.md` data map |
| One instruction is a 40-bit word in an 8-byte slot: `arg[31:0]` then `opcode[7:0]` | `format_imem_slot` in `pycore/tools/encoding.py` |
| Fetch folds `CACHE` and `EXTENDED_ARG` inside a 64-byte line | `pycore/docs/memory_hierarchy.md` |
| 95 catalogued opcodes: 70 `execute`, 8 `partial`, 13 `trap`, 3 `reject`, 1 `strip` | `pycore/targets/pycore.json`, `bytecode_support.md` |
| Documented synthesis of the hart: about 86.5k cells / 4.8k flops. The power unit alone is about 19.7k cells | `pycore/docs/limitations.md` L-ALU-4 |

### Memory

| Region | Size | Role |
| --- | ---: | --- |
| L1I / L1D | 8 KB, 4-way, 64 B lines | 1-cycle hit |
| L2 | 128 KB, 8-way | 8-cycle hit, unified |
| Data window | 16 MB | heap from `0x440` to `0xF00000` (~15 MB free after the boot image) |
| Code ROM | 8192 slots | firmware builtins |
| Code RAM | 131072 slots (1 MB of slot bytes) | on-device compiler and `exec` |
| Behavioral RAM | 16 MB | `+MEM_LATENCY=` model, CI default 4 |

GC is a precise mark-sweep collector, off unless `+GC_EN=1`. It collects
only at an instruction boundary, and only after the allocating instruction
has aborted before its first architectural commit (`pycore/docs/gc.md`).
The on-chip mark bitmap for the 16 MB heap is 120 KB.

### The rest of the system

- **Second hart.** `excore/` is an RV32 core. Recoverable traps cross
  `trap_mailbox.sv`. Fatal traps halt. The contract is "finish the
  semantic effect," and the trap fires before commit
  (`pycore/docs/architecture.md`).
- **Container accelerator.** `pycore_ca.sv` now performs list append /
  extend / delete and dict / set growth on the Python hart. Data-ready
  and container-ready are the same cycle, and the hart stays frozen for
  the command (`pycore/docs/container_accel.md`, landed in #154). The
  mailbox path is still the fallback and still owns console `print`.
- **On-device compiler.** `pycore_firmware/compiler/` is about 14,000
  lines of the Python subset. It tokenizes, parses, and emits CPython
  3.14 wordcode. `master_plan.md` recorded the resident package at
  56,469 code slots on an older snapshot. `compile()` keeps roughly
  10–16 KB of heap per source line.
- **Builtins.** 86 firmware modules under `pycore_firmware/builtins/`,
  about 4,000 lines, plus native `BI_*` ids in the CALL FSM. Many modules
  are unseeded stubs.
- **Objects.** Sixteen 4-bit tags. Heap objects under `PY_TAG_OBJECT`
  use a 16-byte header and 32-byte field stride (`pycore/docs/object_model.md`).
  Strings are a separate tag plus STRACC (`pycore_str_accel.sv`, about
  2,800 lines).
- **Language the hart actually runs.** Functions, closures, module-level
  classes folded at image build, containers, `try`/`except`/`finally` on
  the CPython 3.14 exception table, ROM `compile` / `exec` / `eval`.
  Missing for an MCU program: `import`, runtime `class`, `with`,
  generators, and catchable `TypeError` / `ZeroDivisionError` /
  `IndexError` / `KeyError` from hardware traps (`planning/master_plan.md`
  tracks 2 and 3).
- **Oracle and tests.** Host CPython 3.14 builds images and is the stdout
  oracle (`make run-file`, `make test-compiler-vs-cpython`). About 520
  programs live under `pycore/programs/`. RTL is about 82,000 lines of
  SystemVerilog including headers. `pycore_defs.svh` alone is about 3,800
  lines and is included across the core.
- **The only peripheral.** `CONSOLE_TX` at `0xF0` accepts one output byte
  (`excore/docs/mmio_map.md`). There is no GPIO, timer, UART RX, or IRQ
  line into the Python hart.

### What that shape costs

The research machine is large because each CPython value can be a 64-bit
int, a binary64, a complex, or a heap handle, and because the comparison
point is a desktop interpreter with a cache hierarchy. An MCU program
does not need that value width, that cache model, or opcode-for-opcode
identity with CPython 3.14. The pieces that match an MCU are smaller:
collect at a safe point before commit, finish a container command before
anyone observes the object, and treat MMIO as a store.

## MicroPython, as the target runtime

Phase 0 pins one stable release as a submodule at `vendor/micropython`.
The unix port of that tag is the oracle. `mpy-cross` from that tag emits
the bytecode. These properties are stable across recent releases; the
exact opcode numbers and bit-masks are not, so they are read from the tag
rather than written here.

- **Bytecode** is a variable-length byte stream. The first byte is the
  opcode. Small immediates are folded into the opcode by the multi-opcode
  scheme. Larger operands follow as trailing bytes. A function body starts
  with a prelude: state size, exception-stack size, flags, then the bytes.
  The persistent file is `.mpy`. There is no `CACHE` opcode and no
  `EXTENDED_ARG` word.
- **Names** are qstrs, integer indexes into a pool of interned strings.
  Globals and attributes key on qstr.
- **The object word** on a 32-bit port is `MICROPY_OBJ_REPR_A` in
  `py/obj.h`: a small int, a qstr, a handful of immediates (`None`,
  `False`, `True`), or a pointer to a heap object. v1 copies that encoding.
- **Small int** is 31 bits in a 32-bit word. With long integers disabled
  (`MICROPY_LONGINT_IMPL_NONE`), overflow raises `OverflowError`.
- **Float and complex** are compile-time options. v1 leaves both off.
  Strings are UTF-8. Identifiers are qstrs; other strings are heap objects.
- **GC is always on.** Allocation failure collects. The collector is
  mark-sweep over one heap, with a side table of per-block state. Roots
  are explicit on this core (the SRAM stack, globals, and the few live
  machine registers).
- **Libraries are frozen modules** in flash. `import` loads a frozen
  `.mpy`. The on-device compiler is a build option and is large; v1
  leaves it out. The host cross-compiler is the toolchain.
- **Peripherals** are the `machine` module: Pin, UART, SPI, I2C, Timer.
  v1 builds UART, GPIO, and one timer. SPI and I2C wait until a program
  needs them.
- **Interrupts** do not run arbitrary Python inside the latch. A pending
  IRQ is observed at a bytecode boundary. `micropython.schedule` runs a
  frozen callback there. The latch path does not allocate.
- **Concurrency** in the ecosystem is cooperative (`asyncio`). Threads are
  out of v1. Generators and `async` change the frame layout, so they are
  their own later phase.

## v1 locks

These are decided. Changing one is a revision of this plan, not a local
RTL tweak.

| Lock | Choice |
| --- | --- |
| Tree | `mpycore/`. No `ifdef` inside `pycore_core.sv` |
| Oracle | Pinned MicroPython unix port, stdout compare |
| Toolchain | That tag's `mpy-cross`. New flash-image tool. `image_from_source.py` stays on the CPython path |
| Object word | 32-bit `MICROPY_OBJ_REPR_A`, masks copied from the tag's `py/obj.h` |
| Integers | 31-bit small int. Overflow raises `OverflowError` |
| Float, complex, long int | Off |
| Code memory | Flash, byte-addressed, execute in place. PC is a byte address |
| Data memory | One SRAM. The Python stack is an array of object words inside it |
| GC | Always on. Safe point is a bytecode boundary, after an aborted opcode with no architectural commit |
| Harts | One. Slow container work is a command FSM on this hart |
| Interrupts | Latched in the peripheral block. Handled at dispatch. One schedule queue of frozen callbacks |
| Compiler on device | Absent |
| Success metric | Stdout matches the unix port. Cycle counts are recorded. They are not a ratio against CPython |

### Memory map

Addresses follow the split used by Cortex-M memory maps: code low, SRAM
at `0x2000_0000`, peripherals at `0x4000_0000`. Sizes are the v1 product
point. A smaller SRAM is a later parameter, after a program has run at
256 KB.

| Window | Base | Size | Contents |
| --- | --- | ---: | --- |
| Flash | `0x0000_0000` | 512 KB | frozen `.mpy`, qstr pool, builtin bytecode |
| SRAM | `0x2000_0000` | 256 KB | GC heap, value stack, exception stack |
| MMIO | `0x4000_0000` | 4 KB | UART TX/RX, GPIO, timer, IRQ pending and enable |
| Sim control | `0xE000_0000` | 256 B | halt reason, cycle counter. Simulation only |

SRAM is 1-cycle. Flash has a wait-state parameter defaulting to 1 in
simulation. There is no L2 and no 16 MB backing RAM in the programming
model. A one-line fetch buffer may be added later if flash wait states
show up in a measurement; it is not part of v1.

### Peripheral registers (v1)

Word offsets from `0x4000_0000`. Phase 5 is allowed to add registers. It
is not allowed to move these four.

| Offset | Name | Access |
| --- | --- | --- |
| `0x00` | `UART_TX` | write `[7:0]`; the simulator prints the byte |
| `0x04` | `UART_RX` | read `[7:0]`; bit 31 is data-valid |
| `0x08` | `GPIO_OUT` | write the output word |
| `0x0C` | `TIMER_COUNT` | read free-running counter; write reloads the compare |
| `0x10` | `IRQ_STATUS` | read pending, write-1-to-clear |
| `0x14` | `IRQ_ENABLE` | read/write mask. Bit 0 timer, bit 1 UART RX |

`CONSOLE_TX` at `0xF0` stays on the CPython hart. The new UART is a
different register on a different map.

## Disposition of the current tree

| Piece | Disposition |
| --- | --- |
| Verilator flow, one shared simulator, plusargs, program-vs-oracle tests | **Reuse the shape.** New target name, new oracle binary |
| Safe-point GC rule in `pycore/docs/gc.md` (abort, then collect, then re-dispatch) | **Reuse the rule.** New engine, new root set, 256 KB heap |
| CA command rule in `pycore/docs/container_accel.md` (finish the object before a reader sees it; hart frozen in v1) | **Reuse the rule.** New FSM over 32-bit object words |
| Integer add / sub / compare algorithms | **Rewrite at 31 bits.** The 64-bit units and the overflow-to-bigint trap do not come along |
| `CONSOLE_TX` as "a store is a printed byte" | **Reuse the idea** at `UART_TX` |
| `pycore.json`, 40-bit slots, 132-bit RF, frame descriptors, GIC, CODC | **Stay with the CPython hart** |
| L1/L2, 16 MB RAM model, STRACC, FPU, complex, `pycore_fp_pow.sv` | **Stay with the CPython hart** |
| `excore/` RV32, mailbox, container firmware | **Stay with the CPython hart.** v1 has no second ISA |
| On-device compiler, `image_from_source.py`, CPython exception tables | **Stay with the CPython hart** |
| `planning/accelerator_split_plan.md` | **CPython-hart design.** Its console-as-a-store idea is already extracted above. The container-accelerator follow-ons are not MCU work |
| `code_loading.md` §4 relocation format | **CPython code-object format.** Frozen `.mpy` is a different loader |
| Research cycle ratios vs CPython (`pycore/docs/research_comparison.md`) | **Historical for the CPython hart.** The new scoreboard is stdout against the unix port |

`pycore_core.sv` (about 4,900 lines), `pycore_defs.svh`, and the container
FSMs are opcode-specific. They are not a source base for `mpycore`. The
new core is a new fetch, decode, stack, and call FSM. Expected v1 RTL is
the integer subset plus GC plus three peripherals, which is a much smaller
machine than 82,000 lines.

## Phases

Each phase ends with a test that a later phase is not allowed to break.
Host tests do not need Verilator. Device tests share one `mpycore`
simulator.

### Phase 0 — Pin the release

Docs, catalog, submodule. No RTL.

- Add `vendor/micropython` at one stable tag. Record the tag, the `.mpy`
  version, and the sub-version from that tag's `py/persistentcode.h` in
  `mpycore/targets/mpycore.json`.
- Copy object-word masks from that tag's `py/obj.h` into the same JSON.
- List v1 opcode families by the names in that tag's bytecode header
  (`py/bc0.h` on v1.29.0): load and
  store of locals and globals, small-int const, jumps, unary and binary
  ops that v1 implements as small-int only, call, return, and the prelude
  fields the call path reads. Families that wait (import, class, yield,
  with) are listed as `later` with the phase number.
- Write `mpycore/docs/memory_map.md` with the table in "Memory map" above.
- Banner on `master_plan.md` is already in place once this plan merges.
  Phase 0 does not delete CPython tracks.

**Exit.** `mpycore.json` round-trips a unit test that checks the recorded
`.mpy` version against the submodule headers. `make` of the CPython hart
is untouched.

### Phase 1 — Flash image and oracle harness

- Host tool reads a `.mpy` from `mpy-cross` and lays out flash: qstr
  pool, const objects that are immediates or qstrs, raw bytecode.
- A diff harness runs the same source on the unix port and stores stdout.
- Prelude decoder: state size, exception-stack size, flags. Covered by a
  host test per function kind the v1 call path accepts (module body, plain
  function, function with defaults if the pinned emitter produces them).

**Exit.** A frozen function that returns `1 + 2` has a decoded prelude and
a const pool the host test can print. No simulator yet.

### Phase 2 — Integer core

New RTL: byte fetch, decode, SRAM stack pointer, small-int ALU, jumps,
call and return using the prelude, `print` of a small int via `UART_TX`.

In scope: load/store local, load const small int, binary arithmetic and
compare on small ints, unconditional and conditional jumps, call of a
frozen function with positional arguments, return.

Out of this phase: heap allocation, GC, globals beyond a single module
dict of immediates, closures, classes.

**Exit.** Frozen sources for `print(1 + 2)` and a counted loop match the
unix port's stdout on the simulator. Cycle count is printed and not
compared to CPython.

### Phase 3 — Heap, containers, GC

- Heap objects for `str`, `bytes`, `list`, `tuple`, `dict`, keyed the way
  the pinned runtime behaves. Layout may differ from CPython's 32-byte
  stride and from MicroPython's C structs; behavior is what the unix port
  checks.
- Mark-sweep, always on, over the 256 KB SRAM. An allocation that does not
  fit aborts the bytecode before commit, collects, and re-dispatches.
  Roots are the live stack slice, the module globals, and machine registers
  that hold object words. Document that root set in `mpycore/docs/gc.md`
  before writing the engine.
- List and dict growth is a command FSM on this hart: double, copy, finish
  the insert, then report the command done. The hart is frozen for the
  command, matching today's CA stage A0.

**Exit.** Appending in a loop grows the list and matches unix-port
stdout. A loop that allocates and drops references stays inside 256 KB
and matches stdout. A program that retains more than the heap raises
`MemoryError` the way the unix port does with a heap of the same size
(the unix port is run with a matching heap limit).

### Phase 4 — The language an MCU program uses

- Exceptions are values. `raise` and `except` work. Hardware results that
  are Python exceptions on the unix port are Python exceptions here:
  `TypeError`, `ZeroDivisionError`, `OverflowError`, `IndexError`,
  `KeyError`, `MemoryError`, `AttributeError`. Unhandled exception halts
  the simulator with a reason code and a traceback written to `UART_TX`.
- Runtime classes and bound methods, to the extent the pinned bytecode
  emits them.
- `import` of another frozen module in the same flash image.
- `with`, because drivers use it and the bytecode support is a small
  number of opcodes once exceptions exist.

**Exit.** One flash image with two modules: a class with a method, a
`try`/`except` around a divide by zero, and a `with` that calls `__enter__`
and `__exit__`. Stdout matches the unix port.

### Phase 5 — Microcontroller surface

- GPIO, UART RX, one timer, the IRQ registers in the table above.
- At bytecode dispatch, if an enabled IRQ is pending, the core runs the
  scheduled frozen callback to completion (v1 callbacks do not nest), then
  continues. The latch does not allocate. A callback that would allocate
  raises `MemoryError` at the first allocating opcode, which is a normal
  exception, not a halt inside the peripheral block.
- Simulator peripheral model: a testbench can push RX bytes and advance
  the timer.

**Exit.** A frozen blink program toggles `GPIO_OUT` on the timer IRQ and
the testbench observes the edges. An echo program copies UART RX to
UART TX. Both match a host model of the same registers driven by the
unix port's output where the program also `print`s.

### Phase 6 — Separate decisions

Each item is unstarted until a program needs it. Landing one does not
imply the next.

| Item | Trigger | Constraint |
| --- | --- | --- |
| Single-precision float | A frozen program contains a float const or a float opcode the emitter actually emits | New unit. The CPython binary64 FPU and `pycore_fp_pow.sv` stay where they are |
| Long integers | A program overflows 31 bits and the product requirement is "compute it" rather than `OverflowError` | Heap representation and software arithmetic. Small-int fast path stays |
| Generators and `async` | A program needs `uasyncio`-style concurrency beyond a timer callback | New frame state. Do this before promising a scheduler richer than phase 5 |
| On-device compiler | A REPL must accept source text | A MicroPython compiler frozen into flash, emitting the pinned bytecode. The 14,000-line CPython compiler is the wrong source |
| SPI, I2C, ADC | A driver needs the registers | Same MMIO window, new offsets, same IRQ rule |
| Fetch buffer | A measurement shows flash wait states dominating a real program | One line. This does not introduce an L2 |

## What stays frozen on the CPython hart

Bugfixes that keep `make test-hw` and `make test-compiler-vs-cpython`
green still land. The following feature work does not start:

- Self-hosting `compile()`, further grammar, and the module loader in
  `master_plan.md` track 1.
- Trap-to-exception tracks T6–T12 and new CPython opcodes in tracks 2 and 3.
  The same user-visible goals (catchable `TypeError`, classes, `import`,
  `with`) are phases 4 and 5 of this plan, on the new bytecode.
- Remaining accelerator-split phases aimed at the CPython hart.
- Turning the 16 MB collector on by default, and the bigint / complex-pow
  lifts in `pycore/docs/limitations.md`.
- New ROM builtins whose only purpose is CPython dict coverage.

`planning/cleanup_report.md` still applies to the CPython tree. It is not
a source of `mpycore` tasks.

## Non-goals

- Executing CPython 3.14 wordcode on `mpycore`.
- Bit-identical heap layouts with MicroPython's C structs. The unix port
  compares observable results.
- A second general-purpose core that runs the MicroPython C VM. `excore/`
  is already an RV32; the product is a bytecode hart with MCU memory and
  peripherals.
- Deleting the CPython hart, its tests, or `docs/paper/`. Those remain the
  record of the research machine.
- FPGA board bring-up. Simulation is the acceptance environment, the same
  rule as `pycore/docs/architecture.md`.
- Matching CPython cycle ratios, or keeping `make run-file`'s on-device
  `compile()` as the demo. The new demo is a frozen `.mpy` plus UART output.
- `match`, `except*`, format-spec f-strings, and the CPython descriptor
  protocol. If the pinned MicroPython accepts a program, v1 still only
  claims the phases above.

## Risks

- **Bytecode moves between releases.** Mitigation is the pin. A second
  release is a new JSON catalog and a new submodule commit, not a runtime
  flag.
- **The loader is the fragile host tool.** `.mpy` const encoding and the
  prelude have to match the tag's writer. Phase 1 tests decode against
  that writer before any RTL fetches a byte.
- **Roots.** MicroPython's C port scans a C stack. This core has an
  explicit root set. Writing that set down in phase 3, before the engine,
  is what keeps the collector from freeing an object the unix port still
  holds, and from retaining an object the unix port would free only when
  the test is a stdout test. Stdout tests do not catch a missed root that
  happens to survive until halt; phase 3 includes one test that allocates
  past a dropped reference and checks that a later allocation succeeds.
- **256 KB will not hold the current on-device compiler.** That is the
  point of leaving it on the CPython hart. Phase 6's compiler, if it
  happens, has to fit in flash and use the 256 KB heap.
- **Two roadmaps.** Agents will keep opening CPython opcode work. The
  banner on `master_plan.md` and the stop-list above are the constraint.
- **CA and excore both exist today.** v1 follows the CA's single-hart
  command shape. Porting `pycore_ca.sv` itself would drag in 132-bit
  entries and the 16 MB heap pointer. The new FSM is new RTL that follows
  the written rule.

## Test contract

- **Host.** Image tool and prelude decoder under `mpycore/`. No Verilator.
  The CPython `make test-host` job stays as it is. A docs-only change to
  this plan does not run it.
- **Device.** One shared `mpycore` simulator. Programs under
  `mpycore/programs/`. Each exit test in phases 2–5 is a named program
  whose stdout (and, in phase 5, peripheral trace) is checked.
- **Oracle binary.** The pinned unix port, invoked by the harness with a
  heap limit of 256 KB from phase 3 onward.
- **CPython suite.** `make test-hw`, `make test-compiler-vs-cpython`, and
  `make test-caching` remain the CPython hart's gates. `mpycore` work does
  not weaken them. v1 has no cache, so the CPython caching gate is not a
  `mpycore` gate. The `mpycore` memory gate is: SRAM latency fixed at 1,
  flash wait-state 1, and the phase exit programs match.
- **CI.** Follow the existing split: a PR that touches only `planning/`
  and markdown skips the hardware jobs. The first PR that adds
  `mpycore/rtl` or a simulator adds a job for the phase's exit test and
  does not rebuild the CPython simulators to do it.

## Doc contract

When a phase lands, add the as-built page under `mpycore/docs/` and point
this plan's phase row at it. Do not describe `mpycore` behavior in
`pycore/docs/`. Do not extend `pycore.json` with MicroPython opcodes.

The first pages, written with the phase that makes them true:

| Page | Phase |
| --- | --- |
| `mpycore/docs/memory_map.md` | 0 |
| `mpycore/docs/image.md` | 1 |
| `mpycore/docs/architecture.md` | 2 |
| `mpycore/docs/gc.md` | 3 |
| `mpycore/docs/peripherals.md` | 5 |
