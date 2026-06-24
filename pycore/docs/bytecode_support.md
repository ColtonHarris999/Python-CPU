# PyCore Bytecode Support Lists (CPython 3.14)

This file classifies bytecodes into fully supported, partially supported, and
fully unsupported for the current PyCore implementation.

## Fully supported bytecodes

| Bytecode | Description | PyCore-specific note |
| --- | --- | --- |
| `RESUME` | Marks function entry/resume points in CPython bytecode. | Treated as a no-op control marker. |
| `LOAD_FAST` | Pushes a local variable onto the value stack. | Mapped directly to local-window reads. |
| `LOAD_FAST_BORROW` | Pushes a local variable with CPython borrow semantics. | Executed the same as `LOAD_FAST` in current hardware. |
| `STORE_FAST` | Pops the top stack value into a local variable slot. | Writes local-window storage directly. |
| `LOAD_SMALL_INT` | Pushes a small immediate integer encoded in `oparg`. | Fully supported fast-path immediate load. |
| `LOAD_CONST` | Pushes a constant-table entry onto the value stack. | Loads tagged constants through MEM stage. |
| `POP_TOP` | Pops and discards the top stack value. | Implemented as a stack-pointer decrement. |
| `POP_ITER` | Pops iterator state in loop/iteration sequences. | Implemented as a stack-pointer decrement. |
| `RETURN_VALUE` | Returns the top-of-stack value from a function. | Implemented return datapath is active. |
| `JUMP_FORWARD` | Unconditionally jumps forward by relative offset. | Fully handled by branch unit. |
| `JUMP_BACKWARD` | Unconditionally jumps backward by relative offset. | Fully handled by branch unit. |
| `POP_JUMP_IF_TRUE` | Pops TOS and jumps if truthy. | Supported with numeric/bool truthiness rules. |
| `POP_JUMP_IF_FALSE` | Pops TOS and jumps if falsy. | Supported with numeric/bool truthiness rules. |

## Partially supported bytecodes

| Bytecode | Description | Current limitation |
| --- | --- | --- |
| `CACHE` | Inline cache entry used by CPython adaptive interpreter. | Stripped by preprocess and never executed in hardware. |
| `EXTENDED_ARG` | Extends argument width of the following opcode. | Folded out by preprocess/fetch rather than executed architecturally. |
| `BINARY_OP` | Performs binary arithmetic/bitwise operation selected by `oparg`. | Only selected integer/float/bool `oparg` values are legal; unsupported variants trap or are rejected. |
| `COMPARE_OP` | Performs rich comparison selected by `oparg`. | Only compare selectors `0..5` (`<,<=,==,!=,>,>=`) are decoded. |
| `CALL` | Invokes a callable with positional arguments. | Decoded but full Python call-frame/object-call semantics are not implemented. |
| `COPY` | Duplicates a stack value at depth `oparg`. | Accepted by preprocess for compatibility, but current decode path does not execute it. |
| `SWAP` | Swaps TOS with a deeper stack element. | Accepted by preprocess for compatibility, but current decode path does not execute it. |
| `JUMP_IF_TRUE_OR_POP` | Jumps if truthy else pops TOS. | Accepted by preprocess for compatibility, but current decode path does not execute it. |
| `JUMP_IF_FALSE_OR_POP` | Jumps if falsy else pops TOS. | Accepted by preprocess for compatibility, but current decode path does not execute it. |
| `NOT_TAKEN` | Marker used by CPython for branch prediction/adaptation accounting. | Accepted by preprocess for compatibility, but current decode path does not execute it. |

## Fully unsupported bytecodes

Any CPython 3.14 opcode **not listed in the first two tables** is fully
unsupported in the current PyCore flow.

For unsupported bytecodes, behavior is strict:

1. preprocess rejects the program before artifact generation when possible;
2. if one still reaches decode, it is treated as illegal and traps.

In short, unsupported bytecodes do not have fallback emulation in hardware.
