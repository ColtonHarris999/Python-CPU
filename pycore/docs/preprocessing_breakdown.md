# Preprocessing Breakdown and Design Budget

This document defines the active preprocessing flow for the current PyCore
implementation and clarifies what should remain host-side versus on-core.

## 1) Active preprocessing flow (`pycore/tools/preprocess.py`)

Input: Python source file + function name.

Outputs:

- instruction memory image (`pycore/programs/*.hex`)
- tagged constant memory image (`pycore/programs/*.hex`)
- string heap image for long strings (`pycore/programs/*.hex`)
- inferred type sketch (`pycore/programs/*.types`)
- inline-cache count map (`pycore/programs/*.hex`)

Steps:

1. **Version gate**: hard-fails unless running Python 3.14.
2. **Instruction filtering**: strips `CACHE`/`EXTENDED_ARG` and rejects unknown
   opcodes.
3. **Sub-op validation**: validates supported `BINARY_OP` opargs.
4. **Instruction encoding**: emits one 64-bit slot per instruction word.
5. **Tagged constant encoding**: emits `{tag,value}` constants.
6. **String heap packing**: emits short inline strings or long-string heap data.
7. **Type sketch pass**: emits lightweight variable/stack type metadata.
8. **Cache-map export**: emits CPython inline-cache entry counts.

## 2) Essential versus optional preprocessing

### Essential

- Version-safe opcode decoding aligned to CPython 3.14.
- Unsupported-opcode rejection.
- Program image formatting for instruction memory.
- Constant/string image formatting for data memories.

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
