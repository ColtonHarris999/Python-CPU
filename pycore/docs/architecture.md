# PyCore Architecture

PyCore is a research CPU whose native ISA is a small CPython 3.14 bytecode
subset. The prototype is written as portable SystemVerilog. FPGA use is only a
functional vehicle; FPGA-specific inference hints and resource pragmas are
intentionally absent.

## Tagged value invariant

Every architectural value is a 67-bit register-file entry:

```text
{ tag[2:0], value[63:0] }
```

The tag is co-located with the value and is read on every access. This avoids a
second tag SRAM lookup in silicon at the cost of entries that are about 4.7%
wider than a 64-bit value. The intended ASIC implementation can replace
`pycore_regfile.sv` with a custom multiport SRAM macro without changing
pipeline logic.

The tag encoding is:

| Tag | Meaning |
| --- | --- |
| `000` | `UNINITIALIZED` |
| `001` | signed 64-bit `INT` |
| `010` | IEEE 754 double `FLOAT` |
| `011` | `BOOL`, with `value[0]` significant |
| `100` | raw `PTR`, reserved for future load/store work |
| `101` | opaque `OBJECT` |
| `11x` | reserved, treated as `OBJECT` |

Three bits leave room for `PTR` and future numeric types while making
`UNINITIALIZED` a real architectural state. Undefined local reads trap instead
of returning a garbage value.

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

The trap block freezes the pipeline and latches the fault PC plus both source
entries.

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

## Pipeline and hazards

The intended pipeline is five stages:

```text
IF -> ID -> EX -> MEM -> WB
```

The current top-level scaffold keeps those boundaries explicit and integrates
fetch, decode, register file, execute, and trap blocks. `pycore_fetch.sv`
supports folded `EXTENDED_ARG` streams and skips `CACHE` entries. Taken branches
flush IF and ID, giving a documented two-cycle penalty; branch prediction is a
future use for the CPython 3.14 `NOT_TAKEN` hint.

RAW hazards are intended to use MEM->EX and WB->EX forwarding. `STORE_FAST`
followed by `LOAD_FAST` of the same local must forward the tagged entry rather
than stall. Multi-cycle units assert `stall`, freezing IF and ID while EX owns
the operation.

## Register file and frames

`pycore_regfile.sv` owns the 96-entry register file:

```text
RF[0..31]  frame locals
RF[32..95] operand stack
```

Function calls use a locals-base window instead of copying frame contents.
All live frames must fit inside the physical RF; this is a sizing constraint of
the prototype and a capacity/performance knob for a future macro.

`pycore_frame.sv` stores `{pc_return, tos_base, locals_base}` for calls and
requests that new-frame locals be tagged `UNINITIALIZED`.

## CPython 3.14 preprocessing

`pycore/tools/preprocess.py` must run on Python 3.14. It compiles a host Python
function, rejects unsupported opcodes, strips `CACHE`, emits folded 40-bit
instruction words, writes 67-bit tagged constants, and produces a `.types`
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
