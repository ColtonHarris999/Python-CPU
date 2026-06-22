# PyCore Architecture

PyCore is a research CPU whose native ISA is a small CPython 3.14 bytecode
subset. The prototype is written as portable SystemVerilog. FPGA use is only a
functional vehicle; FPGA-specific inference hints and resource pragmas are
intentionally absent.

## Tagged value invariant

Every architectural value is a 131-bit register-file entry:

```text
{ tag[2:0], value[127:0] }
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
| `000` | `UNINITIALIZED` |
| `001` | signed `INT` (64-bit fast path, sign-extended to 128) |
| `010` | IEEE 754 double `FLOAT` in `value[63:0]`, upper bits zero |
| `011` | `BOOL`, with `value[0]` significant, upper bits zero |
| `100` | raw `PTR`, 128-bit byte address for data memory |
| `101` | opaque `OBJECT` |
| `11x` | reserved, treated as `OBJECT` |

Three bits leave room for `PTR` and future numeric types while making
`UNINITIALIZED` a real architectural state. Undefined local reads trap instead
of returning a garbage value.

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

- `pycore_imem.sv`: read-only, `IMEM_DATA_WIDTH = 64`. Each instruction is one
  8-byte slot (the 40-bit folded word zero-padded). Fetch drives `pc << 3`.
- `pycore_dmem.sv`: read/write, `DMEM_DATA_WIDTH = 128`. Access is one 128-bit
  value per transaction, 16-byte aligned in v1.
- `pycore_const_table.sv`: a 131-bit constant ROM read by the MEM stage so that
  `LOAD_CONST` writeback flows through MEM -> WB like any other value.

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

## CPython 3.14 preprocessing

`pycore/tools/preprocess.py` must run on Python 3.14. It compiles a host Python
function, rejects unsupported opcodes, strips `CACHE`, emits folded 40-bit
instruction words zero-padded to one 8-byte imem slot, writes 131-bit tagged
constants (33 hex digits), and produces a `.types`
annotation file. `LOAD_FAST_BORROW`, `LOAD_SMALL_INT`, `NOT_TAKEN`, and
`POP_ITER` are modeled as CPython 3.14 features; removed 3.13 opcodes are not
assumed.

## Metrics

`cycle_count` increments every non-reset, non-trapped cycle. The primary metric
is cycles per opcode on the typed fast path:

```text
CPO = total_cycles / dynamic_opcodes
```

Secondary metrics are type-trap rate and unit utilization. The helper
`pycore/tools/cosim_trace.py` summarizes traces containing `opcode=`, `unit=`,
and `trap=` fields.
