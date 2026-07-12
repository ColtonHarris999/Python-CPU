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
| `BUILD_LIST` | Pops `count` values, allocates a list object, pushes a `LIST`-tagged handle. | Multi-cycle `S_CONTAINER` FSM; heap bump-allocator at `PYCORE_HEAP_BASE` (0x0400). Element layout: header slot + 2 dmem slots per element (value + tag). Traps `PY_TRAP_MEM_FAULT` on OOM or out-of-range index. Keys must be `INT` or `BOOL`. |
| `BINARY_OP` with oparg `NB_SUBSCR` (26) | Subscript read `x[k]`. | `LIST`: bounds-checked index read. `DICT`: open-addressed linear-probe lookup; key not found traps `PY_TRAP_MEM_FAULT`. Key must be `INT` or `BOOL`; others trap `PY_TRAP_TYPE`. |
| `STORE_SUBSCR` | Subscript write `x[k] = v`. | `LIST`: bounds-checked index write. `DICT`: upsert via linear probe (insert new key or overwrite existing). Same key constraints; pops key, container, value (3 items). |

## Partially supported bytecodes

| Bytecode | Description | Current limitation |
| --- | --- | --- |
| `CACHE` | Inline cache entry used by CPython adaptive interpreter. | Stripped by preprocess and never executed in hardware. |
| `EXTENDED_ARG` | Extends argument width of the following opcode. | Folded out by preprocess/fetch rather than executed architecturally. |
| `LOAD_FAST_BORROW_LOAD_FAST_BORROW` | CPython 3.14 combined two-local load (opcode 87). | Expanded by preprocess into two `LOAD_FAST_BORROW` instructions; never reaches hardware. |
| `BINARY_OP` | Performs binary arithmetic/bitwise operation selected by `oparg`. | Arithmetic/bitwise opargs use the existing ALU path; `NB_SUBSCR` (oparg 26) routes to `S_CONTAINER` for list reads; unsupported variants trap or are rejected by preprocess. |
| `BUILD_MAP` | Pops `2*count` items (interleaved key/value), allocates a dict object, pushes a `DICT`-tagged handle. | Multi-cycle `S_CONTAINER` FSM with open-addressed linear-probe insertion. Key must be `INT` or `BOOL`; others trap `PY_TRAP_TYPE`. Slot count = `next_pow2(max(4, 2*count))`; OOM traps `PY_TRAP_MEM_FAULT`. |
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

## Deferred container opcodes

The following container-related opcodes are explicitly deferred. `preprocess.py`
rejects them with a `"Deferred opcode"` error message; if somehow one reaches
hardware it is trapped as illegal. Each entry has a TODO hook ready for a
follow-up PR.

| Bytecode | Description | Deferral reason |
| --- | --- | --- |
| `LIST_APPEND` | Append value to an existing list. | Requires mutable list resize (realloc or capacity extension). |
| `MAP_ADD` | Add a key/value pair to an existing dict. | Dict mutation requires linear-probe insert (deferred with dict). |
| `LIST_EXTEND` | Extend list with an iterable. | Requires iteration protocol. |
| `DICT_UPDATE` | Update dict from a mapping. | Requires dict merge semantics. |
| `DICT_MERGE` | Merge dict into another dict. | Requires dict iteration. |
| `DELETE_SUBSCR` | `del x[k]` — delete a subscript. | Requires tombstone or shift-down logic. |
| `CONTAINS_OP` | `in` / `not in` operator. | Requires linear scan or hash lookup. |
| `BINARY_SLICE` | Slice read `x[a:b]`. | Requires multi-element copy allocation. |
| `STORE_SLICE` | Slice write `x[a:b] = v`. | Same. |
| `BUILD_SET` | Build a set literal. | Set type not yet implemented in hardware. |
| `SET_ADD` | Append to a set comprehension. | Requires set insert. |
| `SET_UPDATE` | Update a set. | Requires set merge. |
