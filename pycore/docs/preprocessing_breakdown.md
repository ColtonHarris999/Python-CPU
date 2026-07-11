# Preprocessing Breakdown and Design Budget

This document defines the active preprocessing flow for the current PyCore
implementation and clarifies what should remain host-side versus on-core.

## 1) Active preprocessing flow (`pycore/tools/preprocess.py`)

Input: Python source file + function name.

Outputs:

- instruction memory image (`pycore/programs/*.hex`) — includes inlined
  constants; `LOAD_CONST` is a 3-slot variable-length instruction
- string heap image for long strings (`pycore/programs/*.hex`)
- inferred type sketch (`pycore/programs/*.types`)
- inline-cache count map (`pycore/programs/*.hex`)

Steps:

1. **Version gate**: hard-fails unless running Python 3.14.
2. **Instruction filtering**: strips `CACHE`/`EXTENDED_ARG` and rejects unknown
   opcodes.
3. **Sub-op validation**: validates supported `BINARY_OP` opargs.
4. **Constant encoding**: for each `LOAD_CONST`, eagerly encodes `co_consts[N]`
   into a `{tag[3:0], value[127:0]}` tagged entry and stores it in the
   `EmittedInstruction`.
5. **Type sketch pass**: infers variable/stack types from the encoded
   instruction stream (uses `const_tag` directly, not the const index).
6. **Branch remapping**: rewrites jump arguments from instruction-index units
   to slot-index units, accounting for the 3-slot width of `LOAD_CONST`.
7. **Program image encoding**: emits one 64-bit slot per instruction; emits
   three slots for `LOAD_CONST` (header word + two value words).
8. **String heap packing**: emits short inline strings or long-string heap
   data.
9. **Cache-map export**: emits CPython inline-cache entry counts.

## 2) Essential versus optional preprocessing

### Essential

- Version-safe opcode decoding aligned to CPython 3.14.
- Unsupported-opcode rejection.
- Program image formatting for instruction memory, including inline constant
  encoding for `LOAD_CONST` (3-slot format).
- Branch-target remapping from instruction-index to slot-index units.
- String heap image formatting for long-string constants.

### Optional tooling extras

- Type sketch (`.types`) for debugging visibility.
- Cache-map export for observability.

## 3) Preprocessing budget rule

Preprocessing should remain a thin translation/validation layer, not a hidden
runtime.

Allowed:

- Re-encoding bytecode and constants into hardware memory images.
- Rejecting unsupported constructs early.

Disallowed direction:

- Heavy semantic lowering that changes execution model (for example,
  software-emulated frame semantics or object protocol rewrites).

If a transform materially changes program semantics, it should move into
hardware/firmware instead.

## 4) On-core migration targets

To keep PyCore true to purpose, future work should continue moving these
behaviors on-core:

- bytecode decode and immediate extraction;
- frame/stack policy and spill strategy;
- runtime type checks/promotion;
- branch/call execution semantics.
