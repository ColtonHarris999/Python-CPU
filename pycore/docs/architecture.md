# PyCore Architecture

PyCore is a research CPU whose native ISA is a small CPython 3.14 bytecode
subset. The prototype is written as portable SystemVerilog. FPGA use is only a
functional vehicle; FPGA-specific inference hints and resource pragmas are
intentionally absent.

Bytecode support status (fully supported / partially supported / unsupported) is
tracked separately in `pycore/docs/bytecode_support.md` so decode and
preprocessing changes can be reviewed against one explicit matrix.

## Two-core system: pycore + excore

The system is (as of Phase B) two cores: **pycore** (this document's
subject — the CPython-bytecode hart) and **excore**, an RV32 multicycle hart
under `excore/` that services *recoverable* traps in firmware instead of
halting. `pycore_trap.sv` still halts on every trap today; growing this
into a two-core system happens in three ordered phases:

- **Phase A** (done): the LIST layout became growable (stable
  object + relocatable buffer — see the LIST section below) and
  `LIST_APPEND` / `LIST_EXTEND` gained fast paths plus recoverable traps
  (`PY_TRAP_LIST_GROW` / `PY_TRAP_LIST_EXTEND`) that are *classified*
  recoverable (`pycore_trap_recoverable()`). Without `EXCORE_EN` they are
  still reported fatally.
- **Phase B** (done): the excore itself, standalone — `excore_cpu.sv`
  (wrapper around the vendored singlecore `riscv_multicycle` RV32 hart),
  `excore_mmio.sv` (the mailbox/result/slot-port MMIO peripheral), a
  self-contained RV32I assembler (`excore/tools/asm_rv32.py`, no external
  toolchain), and `excore/fw/list_grow.s` — the firmware that
  emulates-and-completes `LIST_GROW` and `LIST_EXTEND` traps (allocate a
  bigger buffer, copy, finish the append/extend, then tell pycore to
  resume). Unit-tested against a mocked mailbox (canned trap messages
  driven directly onto `excore_mmio`'s input ports) and a real
  `pycore_mem_bank` instance. See `excore/docs/` and
  `excore/rtl/singlecore/README.md` for excore-specific docs.
- **Phase C** (done): the mailbox transport (`excore/rtl/trap_mailbox.sv`),
  the memory-ownership grant mux in the new `pycore_excore_system.sv` top
  level, and pycore's `S_TRAP_MARSHAL` / `S_TRAP_WAIT` states that hand a
  recoverable trap to the excore instead of halting, then apply its result
  (resume, retry, or forward a fatal code into `pycore_trap` as today's
  ordinary halt). See "Two-core transport and integration" below.

### The excore contract: "complete the semantic effect"

The excore's job is not "retry the trapped instruction" but "finish what
it was trying to do." For `LIST_APPEND` this means the excore allocates a
bigger buffer, copies the old elements, **and appends the new one** —
because by the time the excore is invoked it already holds the element (in
the trap message) and is already looping over the buffer, so the append
itself is nearly free. For `LIST_EXTEND` the same rule applies with
grow-to-fit: double until `new_cap >= len + src_len`, copy the destination
prefix, then copy the source elements, and answer `COMPLETED` (pop 1).

A plain **RETRY** after resize-only would cost a second memory-ownership
handoff plus a second `S_CONTAINER` dispatch. In the eventual pipelined
pycore that handoff is the dominant cost (pipeline drain / grant /
refill). Grow-to-fit also matters: a single doubling can still undershoot
`src_len` (e.g. cap=1, src_len=10 → need=11), so RETRY would cascade into
multiple traps; COMPLETED finishes in one handoff. The protocol still
defines `RETRY` for handlers where pycore state genuinely did not advance
(e.g. emulating an unimplemented opcode from scratch) — but `LIST_GROW`
and `LIST_EXTEND` always answer `COMPLETED`.

This "complete, don't retry" contract is only safe because every
recoverable trap is raised **before any RF/heap/dmem commit** (see
`CONT_LIST_APPEND`'s `CP_HDR` / `CONT_LIST_EXTEND`'s capacity check) — a
property every future recoverable container-op trap must preserve, since
`RETRY` semantics depend on pycore state not having advanced when the trap
fired.

**Why pycore still owns the fast path when there is spare capacity:**
handing every extend to the excore would force a memory-ownership transfer
even when a short copy loop on pycore would suffice. In a future pipelined
design that transfer flushes in-flight work; keeping `len + src_len <= cap`
(and the empty-source no-op) on pycore is the low-latency path. Resizing
itself always stays on the excore — pycore never reallocates list buffers.

### Two-core transport and integration (Phase C)

#### Mailbox message formats

`trap_mailbox.sv` bridges two different handshake styles: pycore's
`trap_req`/`trap_res` are proper wide-parallel valid/ready handshakes;
`excore_mmio`'s mailbox is level-held (`MB_STATUS.trap_pending` stays
asserted until firmware reports a result via `RES_GO`) and its result is a
one-cycle pulse. Field widths (`MAX_TRAP_ENTRIES = 3`, `MAX_RES_ENTRIES =
2`) are module parameters on `pycore_core`, `trap_mailbox`, and
`excore_mmio` alike, so a future handler needing more operands widens them
in one place.

```text
trap_req_valid / trap_req_ready
  trap_code[3:0], pc[31:0], instr[39:0] ({arg[31:0], opcode[7:0]}),
  heap_ptr[31:0], entry_count[2:0], entries[3][131:0]
trap_res_valid / trap_res_ready
  res_code[3:0], fatal_code[3:0], pop_count[2:0], push_count[1:0],
  heap_ptr[31:0], entries[2][131:0]
```

Wide parallel buses are acceptable at this scale; single-beat ->
multi-beat serialization (to shrink the wire count for an ASIC target) is
future work, not needed for the current FPGA-class prototype.

#### Memory-ownership protocol

`pycore_excore_system.sv` owns a registered grant mux (`mem_owner_r ∈
{PYCORE, EXCORE}`, default `PYCORE`) over the one shared dmem bank
(`pycore_mem_bank`). Ownership flips to `EXCORE` exactly when the
`trap_req` handshake completes (pycore's `S_TRAP_MARSHAL` sees
`trap_req_ready_i`); back to `PYCORE` exactly when the `trap_res`
handshake completes (`S_TRAP_WAIT` sees `trap_wait_ready` / asserts
`trap_res_ready_o`). No cycle-level arbitration is needed: pycore is
frozen in `S_TRAP_MARSHAL`/`S_TRAP_WAIT` (no dmem or RF activity) exactly
while `EXCORE` owns memory, and the excore firmware is parked polling
`MB_STATUS` exactly while `PYCORE` owns it, so the two masters are never
both active. A `$fatal` check in `pycore_excore_system.sv` still verifies
in simulation that the non-owner never raises `req` while it doesn't hold
the grant.

Instruction memories are never shared — pycore's imem and the excore's
private firmware imem are each their own array (Harvard per core); only
the *data* heap is shared, and only because that's exactly the resource
whose ownership is being transferred.

#### Trap taxonomy

| Trap code | Name | Classification | Notes |
| --- | --- | --- | --- |
| 0 | `PY_TRAP_NONE` | n/a | no trap |
| 1 | `PY_TRAP_TYPE` | fatal | |
| 2 | `PY_TRAP_STACK` | fatal | |
| 3 | `PY_TRAP_DIV_ZERO` | fatal | |
| 4 | `PY_TRAP_FPU_EXCEPTION` | fatal | |
| 5 | `PY_TRAP_ILLEGAL_OPCODE` | fatal | also the excore's own dispatch-loop default for an unrecognized trap code |
| 6 | `PY_TRAP_CALL_FILTER` | fatal | |
| 7 | `PY_TRAP_MEM_FAULT` | fatal | also the excore's OOM report (`FATAL(MEM_FAULT)`) |
| 8 | `PY_TRAP_ADDR_ALIGN` | fatal | |
| 9 | `PY_TRAP_LIST_GROW` | **recoverable** | `LIST_APPEND` at capacity; excore doubles + completes append |
| 10 | `PY_TRAP_LIST_EXTEND` | **recoverable** | `LIST_EXTEND` when `len+src_len > cap`; excore grows-to-fit + completes extend |
| 11–15 | *(free)* | — | reserved for future recoverable / fatal codes |

`pycore_trap_recoverable(code)` (`pycore_defs.svh`) is the single source of
truth for the fatal/recoverable split (today: `LIST_GROW` and
`LIST_EXTEND`). `EXCORE_EN=1` intercepts a recoverable code in
`CONT_LIST_APPEND` / `CONT_LIST_EXTEND` (in general: in whichever
container-op phase first detects the condition) *before* it would have
reached `pycore_trap`, and routes it to `S_TRAP_MARSHAL` instead.
`EXCORE_EN=0`, or any non-recoverable code, is completely untouched —
`pycore_trap` sees exactly what it always has.

The excore's result (`RES_CODE`, `excore/docs/mmio_map.md`) has three
values, and the restartability requirement each implies:

- **`COMPLETED`** — the excore finished the trapped instruction's full
  semantic effect (see "The excore contract" above); pycore pops
  `pop_count`, pushes `push_count` entries, and resumes at the *next*
  instruction (normal fetch-skip handling, same as any other multi-cycle
  container op's terminal phase).
- **`RETRY`** — pycore state did not advance past the trap point; pycore
  re-dispatches the *same* pc (`redirect_pending_r`/`redirect_tgt_r ←
  cur_pc_r`, the same mechanism a taken branch uses). This is only
  semantically valid because the trap was raised before any commit — see
  the early-trap discipline above. No current handler returns `RETRY`
  (`LIST_GROW` and `LIST_EXTEND` always complete); the code path exists
  and is wired end to end (`S_TRAP_WAIT`'s `unique case` on
  `trap_res_code_r2`) for a future handler where the excore does *not*
  hold enough state to finish the semantic effect itself (e.g. an opcode
  requiring iteration protocol support pycore doesn't have).
- **`FATAL`** — forwarded into `pycore_trap` as an ordinary halt via a new
  `excore_fatal_i`/`excore_fatal_code_i` input pair (bypassing the fixed
  one-hot condition list, since the code is data from firmware, not a
  wired condition).

#### `S_TRAP_MARSHAL` / `S_TRAP_WAIT`

Two new `pycore_core` FSM states. `S_TRAP_MARSHAL` asserts `trap_req_valid_o`
with the operand entries the detecting container op already gathered
(e.g. `CONT_LIST_APPEND` / `CONT_LIST_EXTEND` reuse `rs1_r`/`rs2_r` — the
list handle and element/iterable already decoded for the fast path — so no
extra RF read port or extra cycles are needed to marshal). `S_TRAP_WAIT`
waits for `trap_res_valid_i`, applies `heap_ptr_r ← res.heap_ptr`, pops
`pop_count`, sequences `push_count` RF writes one per cycle (the RF write
port is single-slot), then branches on `res_code` as described above.

#### `pycore_excore_system.sv`

The two-core top level. `pycore_system.sv` remains the single-core top for
legacy testbenches (its `pycore_core` instantiation doesn't override
`EXCORE_EN`, so it defaults to 0 and ties the new trap_req/trap_res ports
off). `tb_container.sv` grows an `EXCORE_EN`/`FW_HEX` parameter pair and a
`generate if` that instantiates `pycore_excore_system` instead of
`pycore_system` when `EXCORE_EN=1`, wrapped in a fixed-name generate block
(`g_dut`) so every existing hierarchical debug reference
(`g_dut.dut.core.*`) resolves identically regardless of which top is
selected — every pre-existing image-boot test can therefore run unchanged
on the two-core system by simply adding `-GEXCORE_EN=1
-GFW_HEX=<assembled firmware>` (see `pycore-img-*-two-core` Makefile
targets).

## CPython image fidelity boundary

"Identical to what a CPython compiler would create" means: the image contains
the same object graph as `compile()` output -- same bytecode units in the same
order (including `CACHE` and `EXTENDED_ARG`), same `co_consts`/`co_names`, and
nested code objects -- lowered mechanically into tagged 128-bit-slot encoding.
No opcode is added, removed, reordered, rewritten, or argument-remapped.

Byte-exact CPython C-struct layout is out of scope because PyCore requires
tagged slots for hardware access. Matching CPython's in-memory C object layout
is future work.

## Tagged value invariant

Every architectural value is a 132-bit register-file entry:

```text
{ tag[3:0], value[127:0] }
```

The tag is co-located with the value and is read on every access. This avoids a
second tag SRAM lookup in silicon at the cost of a slightly wider entry. The
intended ASIC implementation can replace `pycore_regfile.sv` with a custom
multiport SRAM macro without changing datapath logic. Width constants and the
tag/value slice indices live in `pycore_defs.svh` (`PYCORE_VAL_WIDTH`,
`PYCORE_ENTRY_WIDTH`, `PYCORE_TAG_MSB/LSB`, `PYCORE_VAL_MSB/LSB`) with helper
functions (`pycore_get_tag`, `pycore_get_val`, `pycore_make_entry`,
`pycore_int_entry`) so no module hardcodes a bit range.

The tag encoding is:

| Tag | Meaning |
| --- | --- |
| `0000` | `UNINITIALIZED` |
| `0001` | signed `INT` (64-bit fast path, sign-extended to 128) |
| `0010` | IEEE 754 double `FLOAT` in `value[63:0]`, upper bits zero |
| `0011` | `BOOL`, with `value[0]` significant, upper bits zero |
| `0100` | raw `PTR`, 128-bit byte address for data memory |
| `0101` | `TUPLE`: `size[63:0]`, `addr[63:0]` |
| `0110` | `SHORT_STR` inline string: `size[3:0]`, `bytes[119:0]`, `flags[3:0]` |
| `0111` | `LONG_STR` descriptor: `size[63:0]`, `addr[63:0]` |
| `1000` | opaque `OBJECT`: `addr[63:0]` |
| `1001` | `DICT` python dictionary: `addr[63:0]` |
| `1010` | `LIST` python list: `addr[63:0]` |
| `1011` | `SET` python set: `addr[63:0]` |
| `1100` | `CODE_OBJECT` PythonCodeObject: `addr[63:0]` |
| `1101` | `FRAME_OBJECT` PythonFrameObject: `addr[63:0]` |
| `1110` | `NULL` CPython `self_or_null` call sentinel |
| `1111` | `NONE` python None type |

Undefined local reads still trap instead of returning a garbage value.

### 128-bit value semantics

The value field is 128 bits wide, but the v1 datapath keeps the existing
single-cycle math leaves rather than widening every unit:

- `INT` uses a **64-bit signed fast path**. The ALU, multiplier, divider, and
  power unit operate on `value[63:0]`; `pycore_exec` sign-extends the 64-bit
  result into `value[127:64]`. This deviates from CPython arbitrary-precision
  integers in the same direction the prototype already did (overflow wraps at
  64 bits). A true 128-bit INT ALU is future work; the wider field reserves the
  encoding space for it.
- `FLOAT` stores the IEEE 754 double in `value[63:0]` with `value[127:64] = 0`.
  The FPU remains 64-bit.
- `BOOL` keeps the truth value in `value[0]` with all other bits zero.
- `PTR` is architecturally a 128-bit byte address. In v1 only `value[31:0]` is
  decoded onto the data bus (`ADDR_WIDTH = 32`); a nonzero upper PTR field
  raises `MEM_FAULT`.
- `SHORT_STR` uses 15 UTF-8 bytes inline in the value field plus a 4-bit size.
  The low 4 flag bits are reserved for future use and currently written zero.
- `LONG_STR` uses `{size, addr}` and stores byte payloads in string memory.
  `BINARY_OP (+)` concatenates `SHORT_STR`/`LONG_STR` pairs, producing short or
  long output based on result length; oversized results trap with `MEM_FAULT`.
- `UNINITIALIZED` and `OBJECT` retain their trap semantics unchanged.

## Trap policy

`OBJECT`, `UNINITIALIZED`, `PTR`, and reserved tags trap for arithmetic,
comparison, branch truthiness, and unary operations. `OBJECT` is not a generic
slow arithmetic type; it means "unknown, therefore unsafe." Reimplementing
CPython's complete object protocol in hardware is explicitly outside PyCore's
fast path.

Trap priority is implemented by `pycore_trap.sv` (numeric trap codes are noted
where they differ from priority position):

1. `TYPE_TRAP`
2. `STACK_FAULT`
3. `DIV_ZERO`
4. `FPU_EXCEPTION`
5. `ILLEGAL_OPCODE`
6. `CALL_FILTER` (code 6; non-callable, bad argc, or frame-manager fault)
7. `ADDR_ALIGN` (code 8; misaligned data access)
8. `MEM_FAULT` (code 7; out-of-range address, missing global/key, or invalid PTR)

The trap block halts the core (forcing the control FSM into `S_HALT`) and
latches the fault PC plus both source entries. `ADDR_ALIGN` and `MEM_FAULT` are
raised in the `S_MEM` state; the execute-state traps above are raised by the
execute fabric, the branch unit, and decode.

## Execution fabric

The execute stage is a tag-routed fabric:

1. `pycore_tag_decode.sv` checks operand tags and the abstract ALU operation.
2. `pycore_promote.sv` converts `BOOL -> INT`, `BOOL -> FLOAT`, or
   `INT -> FLOAT` when selected by tag decode.
3. Operation-specific modules run independently:
   - `pycore_int_alu.sv`
   - `pycore_mul.sv`
   - `pycore_div.sv`
   - `pycore_fpu.sv`
4. `pycore_exec.sv` muxes the selected result back into `{tag, value}` form.

`NB_TRUE_DIVIDE` always produces `FLOAT`, including `INT / INT`. The operands
are converted to IEEE 754 double before entering the FPU, matching Python's `/`
result type.

Integer overflow wraps for add/sub/mul and shift results. This is PyCore's
largest semantic deviation from CPython because Python integers are arbitrary
precision. Programs relying on values outside signed 64-bit range can silently
diverge unless preprocessing or software trapping rejects them.

## Control: multi-cycle, non-pipelined

The core is multi-cycle and non-pipelined: exactly one instruction is in flight
at a time. A control FSM in `pycore_core.sv` walks each instruction through five
states before fetching the next one:

```text
S_FETCH -> S_DECODE -> S_EXEC -> S_MEM -> S_WB -> (S_FETCH)
```

- `S_FETCH` runs `pycore_fetch.sv` until a real instruction is presented, then
  latches `{opcode, arg, pc}`. `pycore_fetch.sv` folds `EXTENDED_ARG` streams and
  skips `CACHE` entries internally, so multi-byte instructions are absorbed
  inside this state.
- `S_DECODE` drives the register-file read addresses and latches the operands.
- `S_EXEC` runs the execute fabric and branch unit; it holds while a multi-cycle
  execute unit asserts a stall.
- `S_MEM` runs `pycore_mem_stage.sv`; it holds while an in-flight data-memory
  access (PTR load/store) is outstanding and captures the writeback entry.
- `S_WB` writes the register file, advances the operand-stack pointer, and
  redirects fetch on a taken branch.

Any trap latched by `pycore_trap.sv` drives the FSM into a terminal `S_HALT`
state that freezes architectural state and the cycle counter.

Because only one instruction is ever in flight, there are **no hazards to
resolve**: the register file is always coherent by the time the next
instruction reads it. The pipelined design's operand forwarding (EX/MEM and
MEM/WB into EX, MEM/WB into ID), load-use stall detection, and the two-cycle
branch flush are all removed. Multi-cycle execute units and outstanding
data-memory accesses simply hold the FSM in `S_EXEC`/`S_MEM` until they
complete.

The operand stack pointer (`tos`) is a core register advanced once per
instruction in `S_WB`. Decode reads `tos` combinationally, so each instruction
addresses the correct stack slots; no forwarding is needed because the previous
instruction has already retired.

Because `pycore_fetch.sv` is itself a registered req/ack unit, the FSM freezes
it (via its `stall` input) while an instruction is being processed and ignores
the held, stale `instr_valid` on re-entry to `S_FETCH` until a fresh fetch
completes. Taken branches are applied by asserting the fetch unit's
`branch_taken`/`branch_target` redirect during the first `S_FETCH` cycle.

## Memory subsystem

PyCore is a Harvard machine. The core is a memory master: instruction fetch and
the MEM stage drive synchronous `req`/`ack` ports (`imem_*`, `dmem_*`) with a
one-cycle access latency. There is no `imem_rdata` loopback into the core; memory
banks live in `pycore_system.sv`.

Each bank (`pycore_mem_bank.sv`) is built from parameterized fixed-size SRAM
tiles (`pycore_mem_block.sv`). `BLOCK_SHIFT` (log2 bytes per block, default 12 =
4 KB) is the primary retarget knob. Byte addresses decode as:

```text
block_idx = addr[ADDR_WIDTH-1:BLOCK_SHIFT]
block_off = addr[BLOCK_SHIFT-1:0]
word_idx  = block_off >> log2(DATA_WIDTH/8)
```

- `pycore_imem.sv`: read-only, `IMEM_DATA_WIDTH = 64`. Each CPython two-byte
  code unit is one 8-byte slot. `CACHE` and `EXTENDED_ARG` units remain present
  in the image; fetch folds/skips them at execution time. Fetch drives `pc << 3`.
- `pycore_dmem.sv`: read/write, `DMEM_DATA_WIDTH = 128`. Access is one 128-bit
  value per transaction, 16-byte aligned in v1.

Default memory map (all parameters in `pycore_defs.svh`): `ADDR_WIDTH = 32`,
`BLOCK_SHIFT = 12`, `IMEM_BLOCK_COUNT = 4` (16 KB), `DMEM_BLOCK_COUNT = 4`
(16 KB). Out-of-range or misaligned data accesses raise `MEM_FAULT` /
`ADDR_ALIGN`.

PTR load/store reach data memory through two internal-only opcodes
(`PY_OP_MEM_LOAD_PTR`, `PY_OP_MEM_STORE_PTR`) that are not part of the CPython
opcode space and are never emitted by `preprocess.py`; they exist so test streams
can exercise the dmem datapath through the real MEM stage. A PTR load tags its
result `INT` in v1.

## Register file and frames

`pycore_regfile.sv` owns the 96-entry register file:

```text
RF[0..31]  frame locals
RF[32..95] operand stack
```

Function calls are managed by the as-built `pycore_frame.sv`, which implements
a **simple push/pop call-frame stack in dmem** (not a ring-buffer spill design).
Each CALL pushes a two-slot, 32-byte frame descriptor:

```text
slot 0: { pc_return[31:0], tos_base, locals_base, zero padding }
slot 1: { zero padding, caller cur_code[31:0] }
```

Each RETURN pops slot 1 then slot 0, restores the caller's code object pointer,
PC, TOS base, and locals base, then reloads the caller's `co_consts` and
`co_names` from the code object before fetch resumes. Frame depth is bounded by
the reserved frame-stack region (`0x2000`-`0x3FFF`).

> **Future work:** an earlier design study (`pycore/rtl/attic/pycore_frame_buffer.sv`)
> explored a ring-buffer RF window with memory spill so call depth could scale
> with dmem capacity rather than RF depth. That module is unintegrated; the
> production path remains the simple `pycore_frame.sv` push/pop manager.

## Image boot and code objects

When `BOOT_EN=1`, reset enters `S_BOOT` before normal fetch. The core reads the
boot record at `PYCORE_BOOT_RECORD_ADDR = 0x0000_03e0`:

```text
0x3e0: module code object value
0x3f0: module code object tag
0x400: globals dict value
0x410: globals dict tag
```

The boot walker verifies `CODE_OBJECT`/`DICT`, caches the module code object's
`co_consts` and `co_names`, latches `globals_base_r`, and redirects fetch to the
module entry slot. `BOOT_EN=0` is retained only for legacy hand-authored hex
fixtures.

Serialized code objects are four tagged-entry fields (32 bytes per field):

```text
field 0: entry_slot  (INT, imem slot index)
field 1: co_consts   (TUPLE handle)
field 2: co_names    (TUPLE handle)
field 3: metadata    (INT, packed {stacksize, nlocals, argcount})
```

The interim function model is **function == code object**: `MAKE_FUNCTION`
checks that TOS is a `CODE_OBJECT` and leaves it in place. `CALL` expects the
CPython 3.14 non-method layout `callable, NULL, args...`, validates the callable
tag and argcount, reads the callee code-object fields, then enters the frame
manager.

`LOAD_CONST` is now a normal one-slot CPython instruction. It indexes
`co_consts[arg]` and the container FSM performs two dmem reads (value slot then
tag slot) before pushing the tagged entry. This raises CPO for constant-heavy
programs versus the old inline literal path; an inline cache or small const
cache is future work.

`LOAD_GLOBAL` and `LOAD_NAME` read the name from `co_names`, then probe the
module globals dict. There is no builtins fallback in this prototype: a missing
name traps `PY_TRAP_MEM_FAULT`. `LOAD_NAME` is currently equivalent to globals
lookup at module scope. `STORE_NAME` and `STORE_GLOBAL` update the same globals
dict.

## CPython 3.14 image tooling

`pycore/tools/image_from_source.py` is the primary flow. It must run on Python
3.14, compiles the module with `compile()`, validates that all code objects use
supported opcodes, transcodes every raw `co_code` unit one-for-one into imem,
serializes the object graph (`co_consts`, `co_names`, nested code objects, and
globals dict) into tagged dmem slots, and writes the boot record. Branch
arguments are not remapped because imem slot index equals CPython code-unit
index.

`pycore/tools/preprocess.py` is deprecated legacy tooling for older
single-function hex fixtures and should not be used for new image-boot tests.

## Container heap and object model

### Heap allocator

The core carries a **bump-pointer heap allocator** for dynamically allocated
container objects.  The heap occupies a fixed region of data memory:

```text
PYCORE_HEAP_BASE  = 0x0000_0400  (1 KB offset from dmem start)
PYCORE_HEAP_LIMIT = 0x0000_2000  (just below the call-frame stack)
```

Capacity: ~7 KB.  A `heap_ptr_r` register in `pycore_core.sv` starts at
`HEAP_INIT_PTR` (default `PYCORE_HEAP_BASE`) and advances monotonically; there
is no free list (no object reclamation in this prototype).  Overflow traps
`PY_TRAP_MEM_FAULT`.  A preloaded static heap image sets `HEAP_INIT_PTR` to the
first free byte above the static objects so bump allocation does not overwrite
them.  `DMEM_HEX` on `pycore_system` / `pycore_dmem` preloads the whole dmem
bank (not just the first 4 KB block).

### LIST in-dmem layout (v2 — growable split object/buffer)

All addresses are 16-byte aligned (128-bit dmem slot granularity).

Lists moved (Phase A) from a v1 inline layout (header immediately followed
by elements at the same base) to a **CPython-style split model**: a stable
32-byte **object** whose address never changes (and is what the `LIST`
handle names), pointing at a relocatable **element buffer**.  This is the
prerequisite for growth — v1's inline layout made growing a list impossible
without moving it, which would dangle every alias of the handle.

```text
obj_addr + 0  : header  { capacity[63:0], length[63:0] }
obj_addr + 16 : { 64'd0, ob_item[63:0] }   (element buffer byte address)

ob_item + idx*32      : element[idx] value[127:0]
ob_item + idx*32 + 16 : element[idx] tag  { 124'b0, tag[3:0] }
```

Each element occupies **two 16-byte slots** in the buffer (element stride =
32 bytes).  The object is always exactly 32 bytes
(`pycore_list_obj_bytes()`); the buffer is `capacity × 32` bytes
(`pycore_list_buf_bytes(capacity)`).  Empty list: `capacity = 0, length = 0,
ob_item = 0` — no buffer allocation (object only).

The 132-bit tagged entry `{ tag[3:0], value[127:0] }` is split across two
consecutive 128-bit dmem slots: the value slot followed by the tag slot.
This avoids any non-16-byte addressing.

Helpers in `pycore_defs.svh`: `pycore_list_obitem_addr(obj)` /
`pycore_list_obitem(slot)` resolve the buffer address from the object;
`pycore_list_val_addr(buf, idx)` / `pycore_list_tag_addr(buf, idx)` compute
element addresses **within the buffer** (not the object — every read/write
path resolves `ob_item` first, then addresses the buffer, adding one dmem
op versus v1: `CONT_SUBSCR_LIST` / `CONT_STORE_LIST` insert a `CP_LIST_BUF`
phase between the header read and the element access).

`BUILD_LIST` allocates the object and a `count`-sized buffer in a single
combined OOM check, with `capacity == count` exactly (no spare capacity —
matching CPython list-literal semantics; growth only ever happens via
`LIST_APPEND` / `LIST_EXTEND`, never at construction).

Negative indices are **not** wrapped: the bounds check is unsigned, so a
negative INT key traps `PY_TRAP_MEM_FAULT` (same policy for TUPLE).

#### `LIST_APPEND`

`LIST_APPEND` (opcode 78) has a fast path and a grow path:

- **Fast path** (`length < capacity`, `CONT_LIST_APPEND` in `pycore_core.sv`):
  read the object header, read `ob_item`, write the element's value and tag
  at `ob_item + length*32`, write back `{capacity, length+1}`, pop the
  element.  5 dmem ops, no trap.
- **Grow path** (`length == capacity`): raises `PY_TRAP_LIST_GROW`
  (trap code 9) **before any RF/heap/dmem commit** — checked in the same
  cycle as the header read ack, before the `ob_item` read is even issued.
  With `EXCORE_EN=1` the excore doubles capacity (floor 4), copies, appends,
  and returns `COMPLETED`. With `EXCORE_EN=0` the trap is fatal.

Cost model: fast path is `O(1)` (5 dmem ops); the grow path is a
memory-ownership handoff plus `O(length)` element copy in firmware,
amortized `O(1)` across appends because the excore doubles capacity on
every grow.

#### `LIST_EXTEND`

`LIST_EXTEND` (opcode 79) extends a list from a **LIST or TUPLE** source
(other tags → `PY_TRAP_TYPE`; no iterator protocol yet):

- **Empty source**: no-op pop of the iterable on pycore (no trap).
- **Fast path** (`len + src_len <= capacity`, `CONT_LIST_EXTEND`): copy
  `src_len` elements into the spare slots, write back the new length, pop
  the iterable. Self-extend is safe when `2*len <= capacity` (write
  indices do not overlap the read window).
- **Grow path** (`len + src_len > capacity`): raises `PY_TRAP_LIST_EXTEND`
  (trap code 10) before any commit. The excore grows-to-fit
  (`new_cap = max(cap?cap*2:4, need)`, doubling until `>= need`), copies
  destination then source (self-extend snapshots `old_buf` before the
  `ob_item` rewrite; old buffer is intentionally leaked), and returns
  `COMPLETED` with pop 1.

`compile()` emits `LIST_EXTEND` for list-display unpack (`[1, 2, *x]`,
`[*a, *b]`). Method-style `a.extend(b)` still lowers via `LOAD_ATTR`+`CALL`
and is unsupported.

### TUPLE in-dmem layout

Because size lives inline in the handle `{ size[63:0], addr[63:0] }`, tuples
need **no header slot**:

```text
element[i] value : addr + 32*i
element[i] tag   : addr + 32*i + 16
allocation bytes : size * 32
```

Helpers: `pycore_tuple_val_addr`, `pycore_tuple_tag_addr`,
`pycore_tuple_alloc_bytes`, `pycore_tuple_size`, `pycore_tuple_addr`.

### DICT in-dmem layout

All addresses are 16-byte aligned (128-bit dmem slot granularity).

```text
base + 0                 : header { slot_count[63:0], used[63:0] }
base + 16*(1 + 4*i)      : slot[i] key   value[127:0]
base + 16*(2 + 4*i)      : slot[i] key   tag   { 124'b0, key_tag[3:0] }
base + 16*(3 + 4*i)      : slot[i] value value[127:0]
base + 16*(4 + 4*i)      : slot[i] value tag   { 124'b0, val_tag[3:0] }
```

Each slot occupies **four 16-byte dmem slots** (slot stride = 64 bytes).
Total allocation = `16 + slot_count × 64` bytes.

Empty-bucket sentinel: key tag = `PY_TAG_UNINIT` (4'b0000).

Slot count = `next_pow2(max(4, 2 × n_pairs))`, ensuring max load ≤ 50% at
construction time. Hash = `pycore_dict_key_hash(tag, value) & (slot_count − 1)`:

| Key tag | Hash |
| --- | --- |
| `INT` / `BOOL` | `value[31:0]` (preserves existing images) |
| `SHORT_STR` | XOR of the four 32-bit words of `value[127:0]` |
| `LONG_STR` | `value[31:0] ^ value[95:64]` (low 32 of addr XOR low 32 of size) |

Supported key tags: `INT`, `BOOL`, `SHORT_STR`, `LONG_STR`. Other key tags trap
`PY_TRAP_TYPE`. Key-not-found traps `PY_TRAP_MEM_FAULT`.

`LONG_STR` equality is descriptor equality (`{size, addr}`). This relies on
**interning**: `StringHeapBuilder` deduplicates identical long-string constants
so descriptor equality is string equality. Runtime-concatenated `LONG_STR`
results (private to `pycore_exec` string memory, not interned) are not valid
dict keys semantically; hardware cannot detect this.

The header `used` field is maintained on insert. Probe loops are bounded by
`slot_count` and trap `PY_TRAP_MEM_FAULT` on exhaustion. Interim insert policy
(until rehash/grow): never fill the table completely — require
`used + 1 < slot_count` before an empty-slot insert so at least one empty slot
always remains.

The implementation uses **tombstone-free open-addressed linear probing**.
`DELETE_SUBSCR` is deferred; tombstone logic can be added later when needed.

Static heap images for dicts/tuples/lists can be built with
`pycore/tools/heap_image.py` (`HeapImageBuilder`), which mirrors the RTL hash
and probe rules.

### DICT FSM path

`CONT_BUILD_MAP`, `CONT_SUBSCR_DICT`, and `CONT_STORE_DICT` are three distinct
container op codes (3-bit `container_op_r`) sharing the dict-specific phases
`CP_DICT_HASH` (5) through `CP_DICT_RD_VTAG` (14). `CONT_BUILD_TUPLE` and
`CONT_SUBSCR_TUPLE` reuse the shared LIST-style phases without a header.

- **`BUILD_MAP`**: allocates header, then for each pair reads key from RF,
  probes for empty/matching slot, inserts key + value (4 dmem writes each),
  rewrites `used` in the header once at the end.
- **`NB_SUBSCR` on DICT**: reads header → slot_count, probes for matching key,
  reads value value + tag, writes result to RF.
- **`STORE_SUBSCR` on DICT**: reads header, probes for matching or empty slot,
  writes key/value; bumps `used` on new-key insert.
- **`BUILD_TUPLE` / `NB_SUBSCR` on TUPLE**: no header; size is inline in the
  handle. `STORE_SUBSCR` on a TUPLE traps `PY_TRAP_TYPE` (immutable).

### `S_CONTAINER` FSM state

`S_CONTAINER` is a new FSM state (value 8, requiring 4-bit `state_r`) entered
directly from `S_EXEC` when `dec_is_container` is asserted.  It bypasses both
`S_MEM` and `S_WB`; TOS and RF updates happen inside `S_CONTAINER`.

Sub-phases (stored in `container_phase_r [2:0]`):

| Phase | Name | Purpose |
|-------|------|---------|
| 0 | `CP_INIT` | First active cycle; set up the first dmem or RF operation. |
| 1 | `CP_HDR` | In-flight header read/write; wait for dmem ack. |
| 2 | `CP_VAL` | In-flight element value read/write; wait for ack. |
| 3 | `CP_TAG` | In-flight element tag read/write; wait for ack. |
| 4 | `CP_DONE` | Terminal marker; `always_comb` transitions to `S_FETCH`. Empty in `always_ff`. |

The dmem port is arbitrated via `container_dmem_pending_r`, which mirrors
`frame_dmem_pending_r` used by `S_CALL` and `S_RETURN`.

An RF address override (`rs1_addr_eff`) redirects the regfile's rs1 read port
to `container_rf_addr_r` while in `S_CONTAINER`, enabling multi-element reads
for `BUILD_LIST` and the value read for `STORE_SUBSCR` without an extra RF
read port.

## Metrics

`cycle_count` increments every non-reset, non-trapped cycle. The primary metric
is cycles per opcode on the typed fast path:

```text
CPO = total_cycles / dynamic_opcodes
```

Secondary metrics are type-trap rate and unit utilization. The helper
`pycore/tools/cosim_trace.py` summarizes traces containing `opcode=`, `unit=`,
and `trap=` fields.
