# PyCore Architecture

PyCore is a research CPU whose native ISA is a small CPython 3.14 bytecode
subset. The prototype is written as portable SystemVerilog. FPGA use is only a
functional vehicle; FPGA-specific inference hints and resource pragmas are
intentionally absent.

Bytecode support status (fully supported / partially supported / unsupported) is
tracked separately in `pycore/docs/bytecode_support.md` so decode and
preprocessing changes can be reviewed against one explicit matrix.

## Two-core system: pycore + excore

The system is two cores: **pycore** (this document's subject — the
CPython-bytecode hart) and **excore**, an RV32 multicycle hart under
`excore/` that services *recoverable* traps in firmware instead of
halting. Fatal traps still go through `pycore_trap.sv` and halt. With
`EXCORE_EN=1`, recoverable codes are intercepted before `pycore_trap` and
routed through `S_TRAP_MARSHAL` / `S_TRAP_WAIT`.

How the split landed (all phases shipped):

- **Phase A**: growable LIST layout (stable object + relocatable buffer);
  spare-capacity `LIST_APPEND` on pycore; `PY_TRAP_LIST_GROW` /
  `PY_TRAP_LIST_EXTEND` (empty extend stays a no-op pop). Without
  `EXCORE_EN`, recoverable traps are fatal.
- **Phase B**: standalone excore — `excore_cpu.sv` (wrapper around the
  vendored `riscv_multicycle` hart), `excore_mmio.sv`, self-contained
  assembler (`excore/tools/asm_rv32.py`), and `excore/fw/list_grow.s`
  (now also list-delete / dict-grow / set-grow / set-update). Unit-tested
  against a mocked mailbox + real `pycore_mem_bank`. See `excore/docs/`
  and `excore/rtl/singlecore/README.md`.
- **Phase C**: mailbox transport (`trap_mailbox.sv`), memory-ownership
  grant mux in `pycore_excore_system.sv`, and pycore marshal/wait that
  apply `COMPLETED` / `RETRY` / `FATAL` results. See below.

### The excore contract: "complete the semantic effect"

The excore's job is not "retry the trapped instruction" but "finish what
it was trying to do." For `LIST_APPEND` this means the excore allocates a
bigger buffer, copies the old elements, **and appends the new one** —
because by the time the excore is invoked it already holds the element (in
the trap message) and is already looping over the buffer, so the append
itself is nearly free. For `LIST_EXTEND` the same rule applies: if
`need = len + src_len <= capacity`, copy source elements in place onto the
existing buffer; otherwise grow-to-fit (double until `new_cap >= need`),
copy destination then source, and answer `COMPLETED` (pop 1). Mid-list
`DELETE_SUBSCR` similarly completes the shift on excore (`LIST_DELETE`,
pop 2); last-element delete stays O(1) on pycore.

A plain **RETRY** after resize-only would cost a second memory-ownership
handoff plus a second `S_CONTAINER` dispatch. In the eventual pipelined
pycore that handoff is the dominant cost (pipeline drain / grant /
refill). Grow-to-fit also matters: a single doubling can still undershoot
`src_len` (e.g. cap=1, src_len=10 → need=11), so RETRY would cascade into
multiple traps; COMPLETED finishes in one handoff. The protocol still
defines `RETRY` for handlers where pycore state genuinely did not advance
(e.g. emulating an unimplemented opcode from scratch) — but every current
handler (`LIST_GROW`, `LIST_EXTEND`, `LIST_DELETE`, `DICT_GROW`,
`SET_GROW`, `SET_UPDATE`) answers `COMPLETED`.

This "complete, don't retry" contract is only safe because every
recoverable trap is raised **before any RF/heap/dmem commit** (see
`CONT_LIST_APPEND`'s `CP_HDR` / `CONT_LIST_EXTEND`'s empty check /
`CONT_DELETE_LIST`'s mid-delete path) — a property every future recoverable
container-op trap must preserve, since `RETRY` semantics depend on pycore
state not having advanced when the trap fired.

**Ownership split (containers):** hash + rich equality and open-addressed
probes stay on pycore; capacity-changing and O(n) memmove work go to
excore. Empty `LIST_EXTEND` is a no-op pop on pycore; spare-capacity
`LIST_APPEND` and last-element list delete stay O(1) on pycore. See
`pycore/docs/dict_excore.md` and `pycore/docs/set_excore.md`.

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
| 10 | `PY_TRAP_LIST_EXTEND` | **recoverable** | non-empty `LIST_EXTEND`; excore in-place or grow-to-fit + completes extend |
| 11 | `PY_TRAP_DICT_GROW` | **recoverable** | new-key dict insert at load ≥ 2/3; excore realloc + rehash + STORE |
| 12 | `PY_TRAP_LIST_DELETE` | **recoverable** | mid-list `DELETE_SUBSCR` shift; excore COMPLETED pop 2 |
| 13 | `PY_TRAP_SET_GROW` | **recoverable** | `SET_ADD` at load ≥ 2/3; excore realloc + insert |
| 14 | `PY_TRAP_SET_UPDATE` | **recoverable** | always; excore grow-to-fit + merge |
| 15 | *(free)* | — | reserved |

`pycore_trap_recoverable(code)` (`pycore_defs.svh`) is the single source of
truth for the fatal/recoverable split. `EXCORE_EN=1` intercepts a recoverable
code in the detecting container-op phase *before* it would have reached
`pycore_trap`, and routes it to `S_TRAP_MARSHAL` instead. `EXCORE_EN=0`, or
any non-recoverable code, is completely untouched — `pycore_trap` sees exactly
what it always has.

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
  (all live handlers complete); the code path exists and is wired end to
  end (`S_TRAP_WAIT`'s `unique case` on `trap_res_code_r2`) for a future
  handler where the excore does *not* hold enough state to finish the
  semantic effect itself (e.g. an opcode requiring iterator protocol
  support pycore does not have).
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

The two-core top level. `pycore_system.sv` remains the single-core top
(`EXCORE_EN` defaults to 0; trap_req/trap_res ports tied off) for
`EXCORE_EN=0` runs and `tb_pycore_runfile`. `tb_container.sv` takes
`EXCORE_EN`/`FW_HEX` and a `generate if` that instantiates
`pycore_excore_system` when `EXCORE_EN=1`, wrapped in generate block
`g_dut` so hierarchical debug refs (`g_dut.dut.core.*`) resolve for
either top. Image-boot tests run on the two-core system with
`-GEXCORE_EN=1 -GFW_HEX=<assembled firmware>` (see
`pycore-img-*-two-core` Makefile targets).

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
module entry slot. `BOOT_EN=0` remains available for hand-authored hex
fixtures that skip the boot record.

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

`LOAD_CONST` is a normal one-slot CPython instruction. It indexes
`co_consts[arg]` and the container FSM performs two dmem reads (value slot then
tag slot) before pushing the tagged entry. An inline or small const cache is
future work.

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

`pycore/tools/preprocess.py` is deprecated (older single-function / `run-file`
fixtures only) and should not be used for new image-boot tests.

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

#### LIST/TUPLE iteration

`GET_ITER` accepts LIST and TUPLE handles and rewrites TOS to an internal
`PY_TAG_PTR` hybrid iterator. Its 128-bit payload is
`magic[127:120], kind[119:116], aux[115:96], index[95:64],
size/stop[63:32], addr[31:0]`. Kinds 0/1 are LIST/TUPLE; RANGE, STR, and
HEAP_ITER reserve kinds 2/3/4. LIST stores `size=0, addr=list_object`;
TUPLE stores its immutable length and element-buffer address. Reserved kinds
remain invalid until both their `GET_ITER` and `FOR_ITER` paths land.
Validity is per-kind rather than a global PTR rule. `PY_TAG_PTR` is not emitted
by the image serializer, so malformed, unknown, or incomplete kinds raise
`PY_TRAP_TYPE` in `FOR_ITER`.

`FOR_ITER` runs in `S_CONTAINER`. TUPLE iteration compares the index with the
captured immutable size and reads the inline element slots. LIST iteration
re-reads the stable object header and `ob_item` each step, so length changes
and buffer growth are observed like CPython list iterators. A yield updates
the iterator and pushes the element in two RF beats. Exhaustion leaves the
iterator at TOS and redirects over `END_FOR` to `POP_ITER`, which performs the
single pop. Unsupported Python iterator types raise `PY_TRAP_TYPE`; there is
no generic `__iter__` / `__next__` dispatch.

Element rewrites through `STORE_SUBSCR` are visible when their index has not
yet been yielded. Rebinding the Python source name does not affect the
iterator, which retains the original object address. LIST `NB_INPLACE_ADD`
routes to the existing LIST_EXTEND/excore grow path and leaves the same list
handle in place; the next `FOR_ITER` observes the extended length and buffer.
LIST `DELETE_SUBSCR` decrements the live length (last element on pycore;
mid-list via `LIST_DELETE`/excore), so deletion can skip shifted elements or
cause early exhaustion.

The reserved kinds are deliberate trap-until-complete sockets, not partial
implementations. RANGE comes next after a native range source/CALL
representation exists. STR follows after `S_CONTAINER` can retain SHORT_STR
payloads and read LONG_STR `string_mem`. Dict views use HEAP_ITER only after a
heap iterator-object layout and insertion-order walk are defined. Generators
remain last because they require YIELD and suspended-frame state. Until each
prerequisite lands, both unsupported sources and forged reserved kinds
TYPE-trap rather than taking a plausible but incomplete path.

#### `LIST_EXTEND`

`LIST_EXTEND` (opcode 79) extends a list from a **LIST or TUPLE** source
(other tags → `PY_TRAP_TYPE`; it does not consume the internal iterator
protocol described above):

- **Empty source**: no-op pop of the iterable on pycore (no trap).
- **Non-empty**: always raises `PY_TRAP_LIST_EXTEND` (trap code 10) before
  any commit. The excore either copies in place when
  `need = len + src_len <= capacity`, or grows-to-fit
  (`new_cap = max(cap?cap*2:4, need)`, doubling until `>= need`), copies
  destination then source (self-extend snapshots `old_buf` before the
  `ob_item` rewrite; old buffer is intentionally leaked on grow), and
  returns `COMPLETED` with pop 1.

`compile()` emits `LIST_EXTEND` for list-display unpack (`[1, 2, *x]`,
`[*a, *b]`). Method-style `a.extend(b)` still lowers via `LOAD_ATTR`+`CALL`
and is unsupported.

#### `DELETE_SUBSCR` (list / dict)

`DELETE_SUBSCR` (opcode 8) on a **LIST** (`CONT_DELETE_LIST`): type and
bounds checks on pycore; deleting the last element is O(1) length-- on
pycore; mid-list delete raises `PY_TRAP_LIST_DELETE` (12) before any commit
so excore shifts `[idx+1 .. len)` down and writes `length-1` (`COMPLETED`
pop 2). Capacity unchanged; delete never reallocates. OOB / negative
indices → `PY_TRAP_MEM_FAULT`. Tuple / set → `PY_TRAP_TYPE`.

On a **DICT**, same-tag / rich-eq hits write `PY_TAG_TOMBSTONE`
(`== PY_TAG_DICT`, since dicts cannot be keys) on the key tag and
decrement `used` on pycore. Miss → `PY_TRAP_MEM_FAULT`.

#### `CONTAINS_OP`

`CONTAINS_OP` (opcode 57) implements `in` / `not in` (oparg bit 0) —
membership never changes capacity:

- **LIST / TUPLE**: linear scan on pycore; INT/BOOL cross-equality matches
  CPython (`True == 1`).
- **DICT / SET**: open-addressed probe; miss pushes `False` (unlike
  `NB_SUBSCR` on dict, which traps). Same-tag / rich-eq matches on
  pycore. Tombstones are skipped.

### TUPLE in-dmem layout

Because size lives inline in the handle `{ size[63:0], addr[63:0] }`, tuples
need **no header slot**:

```text
element[i] value : addr + 32*i
element[i] tag   : addr + 32*i + 16
allocation bytes : size * 32
```

Helpers: `pycore_tuple_val_addr`, `pycore_tuple_tag_addr`,
`pycore_tuple_alloc_bytes`, `pycore_tuple_size`.

### DICT in-dmem layout (v2)

All addresses are 16-byte aligned (128-bit dmem slot granularity). Layout v2
keeps a **stable 32-byte object** and a **relocatable table** (grow updates
`table_ptr` only; the dict handle address does not move):

```text
obj+0  : header { slot_count[63:0], used[63:0] }
obj+16 : { 64'd0, table_ptr[63:0] }     // 0 if slot_count == 0

table + i*64 + 0  : key value
table + i*64 + 16 : key tag   (UNINIT=empty, TOMBSTONE=DICT=9 deleted)
table + i*64 + 32 : value value
table + i*64 + 48 : value tag
```

`BUILD_MAP` may allocate object+table contiguously
(`pycore_dict_alloc_bytes`); slot helpers take the **table** base. Slot count
= `next_pow2(max(4, 2 × n_pairs))` (including empty `BUILD_MAP 0` → 4 slots).
Hash = `pycore_dict_key_hash(tag, value) & (slot_count − 1)`:

| Key tag | Hash |
| --- | --- |
| `INT` | `value[31:0]`; CPython `-1 → -2` |
| `BOOL` | `value[0]` as 0/1 |
| `FLOAT` | integer-valued / ±0 match int hashes; else bit-mix |
| `SHORT_STR` | XOR of the four 32-bit words of `value[127:0]` |
| `LONG_STR` | `value[31:0] ^ value[95:64]` (low 32 of addr XOR low 32 of size) |

Supported key tags: `INT`, `BOOL`, `FLOAT`, `SHORT_STR`, `LONG_STR`. Other key
tags trap `PY_TRAP_TYPE`. Key-not-found traps `PY_TRAP_MEM_FAULT`.

`LONG_STR` equality is descriptor equality (`{size, addr}`). This relies on
**interning**: `StringHeapBuilder` deduplicates identical long-string constants
so descriptor equality is string equality. Runtime-concatenated `LONG_STR`
results (private to `pycore_exec` string memory, not interned) are not valid
dict keys semantically; hardware cannot detect this.

**Same-tag probe**, **cross-tag rich equality**, and **tombstone skip** stay
on pycore. Before a new-key insert, load ≥ 2/3 (`used*3 >= slot_count*2`),
empty table, or no free slot raises `PY_TRAP_DICT_GROW` (11); excore
reallocates (`used*4` if `used≤50k` else `used*2`, floored/rounded to a
power of two), rehashes, and completes the STORE. Without `EXCORE_EN` grow
is fatal. Design notes: `pycore/docs/dict_excore.md`.

Static heap images for dicts/tuples/lists can be built with
`pycore/tools/heap_image.py` (`HeapImageBuilder`), which mirrors the RTL hash
and probe rules.

### DICT FSM path

`CONT_BUILD_MAP`, `CONT_SUBSCR_DICT`, `CONT_STORE_DICT`, plus dict
`DELETE_SUBSCR` / `CONTAINS_OP` paths, share the dict probe phases. Layout v2
reads `table_ptr` via `CP_LIST_BUF` after the header. `CONT_BUILD_TUPLE` and
`CONT_SUBSCR_TUPLE` reuse the shared LIST-style phases without a header.

- **`BUILD_MAP`**: allocates 32B object + contiguous table, writes header +
  `table_ptr`, then for each pair probes (same-tag only) and inserts; rewrites
  `used` once at the end. Empty maps still get ≥4 slots.
- **`NB_SUBSCR` on DICT**: reads header + `table_ptr`, probes; same-tag /
  rich-eq hit returns value; miss → `MEM_FAULT`.
- **`STORE_SUBSCR` on DICT**: same-tag / rich-eq upsert / tombstone reuse on
  pycore; new-key insert may `DICT_GROW`.
- **`DELETE_SUBSCR` / `CONTAINS_OP` on DICT**: tombstone / BOOL result via
  same-tag / rich-eq probe on pycore.
- **`BUILD_TUPLE` / `NB_SUBSCR` on TUPLE**: no header; size is inline in the
  handle. `STORE_SUBSCR` on a TUPLE traps `PY_TRAP_TYPE` (immutable).

### SET in-dmem layout

Sets mirror dict layout v2 but store **elements only** (no value half):

```text
obj+0  : header { slot_count[63:0], used[63:0] }
obj+16 : { 64'd0, table_ptr[63:0] }     // 0 if slot_count == 0

table + i*32 + 0  : element value
table + i*32 + 16 : element tag   (UNINIT=empty, TOMBSTONE=DICT=9 deleted)
```

Handle: `{ PY_TAG_SET, object_addr }`. Hash / rich-eq / tombstone policy
match dict (`PY_TAG_TOMBSTONE == PY_TAG_DICT`). Slot count =
`next_pow2(max(4, 2 × n_elems))`.

| Op | Path |
| --- | --- |
| `BUILD_SET` | pycore alloc + insert (same-tag + rich numeric/str eq) |
| `SET_ADD` | pycore probe/insert; load ≥ 2/3 → `SET_GROW` (13) |
| `SET_UPDATE` | always `SET_UPDATE` (14) → excore bulk merge |
| `CONTAINS_OP` | pycore probe + rich eq |
| `DELETE_SUBSCR` / `STORE_SUBSCR` | `TYPE` (sets are not subscriptable) |

Design notes: `pycore/docs/set_excore.md`.

### `S_CONTAINER` FSM state

`S_CONTAINER` (state value 8, 4-bit `state_r`) is entered from `S_EXEC` when
`dec_is_container` is asserted. It bypasses both `S_MEM` and `S_WB`; TOS and
RF updates happen inside `S_CONTAINER`.

Sub-phases live in `container_phase_r[4:0]`. Shared phases include:

| Phase | Name | Purpose |
|-------|------|---------|
| 0 | `CP_INIT` | First active cycle; set up the first dmem or RF operation. |
| 1 | `CP_HDR` | In-flight header read/write; wait for dmem ack. |
| 2 | `CP_VAL` | In-flight element value read/write; wait for ack. |
| 3 | `CP_TAG` | In-flight element tag read/write; wait for ack. |
| 4 | `CP_DONE` | Terminal marker; `always_comb` transitions to `S_FETCH` (or trap marshal). |

Additional phases cover list buffer / writeback, dict/set probe, name/const
loads, and extend source-header reads — see `pycore_core.sv` for the full
`CP_*` enumeration.

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
