# PyCore Architecture

PyCore is a research CPU whose native ISA is a small CPython 3.14 bytecode
subset. The prototype is written as portable SystemVerilog. FPGA use is only a
functional vehicle; FPGA-specific inference hints and resource pragmas are
intentionally absent.

Bytecode support status (fully supported / partially supported / unsupported) is
tracked separately in `pycore/docs/bytecode_support.md` so decode and
preprocessing changes can be reviewed against one explicit matrix.

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
| `1110` | `UNUSED` |
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

Trap priority is implemented by `pycore_trap.sv`:

1. `TYPE_TRAP`
2. `STACK_FAULT`
3. `DIV_ZERO`
4. `FPU_EXCEPTION`
5. `ILLEGAL_OPCODE`
6. `ADDR_ALIGN` (misaligned data access)
7. `MEM_FAULT` (out-of-range address or invalid PTR)

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

- `pycore_imem.sv`: read-only, `IMEM_DATA_WIDTH = 64`. Most instructions are one
  8-byte slot (the 40-bit folded word zero-padded). `LOAD_CONST` is a 3-slot
  variable-length instruction (see below). Fetch drives `pc << 3`.
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

Function calls are managed by `pycore_frame.sv`, which now treats the RF stack
window as a **ring buffer with memory spill** rather than a hard depth limit.
Each call allocates a frame node containing:

- `{pc_return, tos_base, locals_base}` bookkeeping
- linked-list pointers (`prev`, `next`) for active-frame traversal
- a per-slot mapping table where `0` means "resident in RF" and nonzero is the
  spill memory address
- an allocation pointer target used to identify the oldest frame that still owns
  resident RF data

The RF residency policy is FIFO by age: when a new frame needs registers and
the resident ring is full, the oldest resident slot is spilled to memory and
its mapping table entry flips from `0` to the spill address. This allows call
depth and total logical register demand to scale with memory capacity rather
than RF depth.

Two explicit memory regions are reserved for runtime frame storage:

- **stack-frame metadata region**: frame linked-list nodes
- **frame spill region**: spilled register payloads for non-resident slots

Spill slots are reclaimed on return, so deep but finite recursion can continue
as long as free spill capacity remains. A separate heap region remains reserved
for future object/string support.

## LOAD_CONST: inline literal encoding

`LOAD_CONST` constants are embedded directly in the instruction stream rather
than in a separate constant ROM. This removes the single-function limitation and
the fixed-depth table.

Each `LOAD_CONST` occupies **three consecutive 8-byte imem slots**:

```text
Slot 0  bits[63:60] = tag[3:0]   bits[7:0] = opcode (PY_OP_LOAD_CONST)
Slot 1  value[127:64]
Slot 2  value[63:0]
```

The fetch unit (`pycore_fetch.sv`) detects `PY_OP_LOAD_CONST` in the FS_NORMAL
sub-state, then issues two more imem reads (sub-states FS_CONST_W1,
FS_CONST_W2) to assemble the complete 132-bit tagged entry. It reports the
instruction to the rest of the pipeline only after all three slots have been
consumed, presenting the entry in the `inline_const` output alongside the usual
`instr_valid`/`opcode`/`pc` signals. The core latches `inline_const` and
delivers it directly to the MEM stage, which forwards it to writeback without
any ROM lookup.

Because `LOAD_CONST` instructions are three slots wide rather than one,
`preprocess.py` rewrites all jump arguments from instruction-index units to
slot-index units (`remap_branch_args`) so that the hardware branch unit
(`pycore_branch.sv`) continues to compute correct targets from the raw `arg`
field.

### Benefits over the fixed const ROM

- **Multi-function programs**: each function's constants travel with its code
  in imem; no shared or conflicting index space exists.
- **Unbounded constants**: the only limit is total imem capacity; no 256-entry
  ceiling applies.
- **No startup loading**: constants are part of the instruction image loaded
  once at elaboration; no separate ROM hex file is needed.
- **Simpler integration**: `pycore_system.sv` no longer instantiates
  `pycore_const_table.sv`; the `CONST_HEX`, `CONST_DEPTH`, and `CONST_IDX_W`
  parameters are gone.

## CPython 3.14 preprocessing

`pycore/tools/preprocess.py` must run on Python 3.14. It compiles a host Python
function, rejects unsupported opcodes, strips `CACHE`, emits folded 40-bit
instruction words zero-padded to one 8-byte imem slot (three slots for
`LOAD_CONST`), and produces a `.types` annotation file. `LOAD_FAST_BORROW`,
`LOAD_SMALL_INT`, `NOT_TAKEN`, and `POP_ITER` are modeled as CPython 3.14
features; removed 3.13 opcodes are not assumed.

## Container heap and object model

### Heap allocator

The core carries a **bump-pointer heap allocator** for dynamically allocated
container objects.  The heap occupies a fixed region of data memory:

```text
PYCORE_HEAP_BASE  = 0x0000_0400  (1 KB offset from dmem start)
PYCORE_HEAP_LIMIT = 0x0000_2000  (just below the call-frame stack)
```

Capacity: ~7 KB.  A `heap_ptr_r` register in `pycore_core.sv` starts at
`PYCORE_HEAP_BASE` and advances monotonically; there is no free list (no
object reclamation in this prototype).  Overflow traps `PY_TRAP_MEM_FAULT`.

### LIST in-dmem layout

All addresses are 16-byte aligned (128-bit dmem slot granularity).

```text
base + 0                : header { capacity[63:0], length[63:0] }
base + 16*(1 + 2*i)     : element[i] value[127:0]
base + 16*(2 + 2*i)     : element[i] tag  { 124'b0, tag[3:0] }
```

Each element occupies **two 16-byte slots** (element stride = 32 bytes).
Total allocation = `16 + capacity × 32` bytes.

The 132-bit tagged entry `{ tag[3:0], value[127:0] }` is split across two
consecutive 128-bit dmem slots: the value slot followed by the tag slot.
This avoids any non-16-byte addressing.

Helpers `pycore_list_val_addr(base, idx)` and `pycore_list_tag_addr(base,
idx)` in `pycore_defs.svh` compute element addresses.

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
construction time. Hash = `key_val[31:0] & (slot_count − 1)` (INT/BOOL keys
only; other key tags trap `PY_TRAP_TYPE`).

The implementation uses **tombstone-free open-addressed linear probing**.
`DELETE_SUBSCR` is deferred; tombstone logic can be added later when needed.

### DICT FSM path

`CONT_BUILD_MAP`, `CONT_SUBSCR_DICT`, and `CONT_STORE_DICT` are three distinct
container op codes (3-bit `container_op_r`) sharing the dict-specific phases
`CP_DICT_HASH` (5) through `CP_DICT_RD_VTAG` (14).

- **`BUILD_MAP`**: allocates header, then for each pair reads key from RF,
  probes for empty/matching slot, inserts key + value (4 dmem writes each).
- **`NB_SUBSCR` on DICT**: reads header → slot_count, probes for matching key,
  reads value value + tag, writes result to RF.
- **`STORE_SUBSCR` on DICT**: reads header, probes for matching or empty slot,
  writes key value, key tag, value value, value tag.

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
