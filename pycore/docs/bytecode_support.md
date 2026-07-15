# PyCore Bytecode Support Lists (CPython 3.14)

This file classifies bytecodes into fully supported, partially supported, and
fully unsupported for the current PyCore implementation.

## Fully supported bytecodes

| Bytecode | Description | PyCore-specific note |
| --- | --- | --- |
| `CACHE` | Inline cache entry used by CPython adaptive interpreter. | Preserved in the image and skipped by fetch; slot order remains CPython-identical. |
| `EXTENDED_ARG` | Extends argument width of the following opcode. | Preserved in the image and folded by fetch; following opcode sees the full argument. |
| `RESUME` | Marks function entry/resume points in CPython bytecode. | Treated as a no-op control marker. |
| `LOAD_FAST` | Pushes a local variable onto the value stack. | Mapped directly to local-window reads. |
| `LOAD_FAST_BORROW` | Pushes a local variable with CPython borrow semantics. | Executed the same as `LOAD_FAST` in current hardware. |
| `STORE_FAST` | Pops the top stack value into a local variable slot. | Writes local-window storage directly. |
| `LOAD_SMALL_INT` | Pushes a small immediate integer encoded in `oparg`. | Fully supported fast-path immediate load. |
| `LOAD_CONST` | Pushes `co_consts[oparg]` onto the value stack. | One CPython code unit; hardware reads value+tag from the serialized `co_consts` tuple in dmem. |
| `LOAD_GLOBAL` | Loads a global by name. | Reads `co_names[namei]`, probes module globals, and optionally pushes `NULL` when `oparg & 1`. No builtins fallback. |
| `LOAD_NAME` | Loads a name by index. | Same globals lookup path as `LOAD_GLOBAL` at module scope; no locals/builtins chain. |
| `STORE_NAME` | Stores TOS into a module/global name. | Updates the serialized globals dict, popping one value. |
| `STORE_GLOBAL` | Stores TOS into a global name. | Same hardware path as `STORE_NAME`. |
| `PUSH_NULL` | Pushes CPython's non-method call sentinel. | Writes `{PY_TAG_NULL, 0}` to TOS. |
| `MAKE_FUNCTION` | Builds a function object from a code object. | Interim model: function is the `CODE_OBJECT` handle itself; defaults/closures are rejected by tooling. |
| `CALL` | Invokes a callable with positional arguments. | Supports CPython 3.14 non-method layout `callable, NULL, args...`; validates callable tag and argcount, pushes/pops hardware frames. |
| `TO_BOOL` | Converts TOS to exact bool for branch helpers. | Supports numeric/bool truthiness and rewrites TOS in place to `BOOL`; unsupported tags trap `TYPE`. |
| `NOT_TAKEN` | CPython branch prediction/adaptation marker. | Treated as a no-op marker. |
| `POP_TOP` | Pops and discards the top stack value. | Implemented as a stack-pointer decrement. |
| `POP_ITER` | Pops iterator state in loop/iteration sequences. | Implemented as a stack-pointer decrement. |
| `RETURN_VALUE` | Returns the top-of-stack value from a function. | Implemented return datapath is active. |
| `JUMP_FORWARD` | Unconditionally jumps forward by relative offset. | Fully handled by branch unit. |
| `JUMP_BACKWARD` | Unconditionally jumps backward by relative offset. | Fully handled by branch unit. |
| `POP_JUMP_IF_TRUE` | Pops TOS and jumps if truthy. | Supported with numeric/bool truthiness rules. |
| `POP_JUMP_IF_FALSE` | Pops TOS and jumps if falsy. | Supported with numeric/bool truthiness rules. |
| `BUILD_LIST` | Pops `count` values, allocates a list object, pushes a `LIST`-tagged handle. | Multi-cycle `S_CONTAINER` FSM; heap bump-allocator at `HEAP_INIT_PTR` (default `PYCORE_HEAP_BASE` 0x0400). Element layout: header slot + 2 dmem slots per element (value + tag). Index must be `INT` or `BOOL`; out-of-range or OOM traps `PY_TRAP_MEM_FAULT`. Empty list (`count=0`) allocates header only. |
| `BUILD_TUPLE` | Pops `count` values, allocates a tuple (no header), pushes a `TUPLE` handle `{size, addr}`. | Opcode 51 (resolved from CPython 3.14). Same index rules as LIST for `NB_SUBSCR`. |
| `BUILD_MAP` | Pops `2*count` items (interleaved key/value), allocates a dict, pushes `DICT`. | Open-addressed linear-probe insert. Keys: `INT`, `BOOL`, `SHORT_STR`, `LONG_STR`. Slot count = `next_pow2(max(4, 2*count))`. |
| `BINARY_OP` with oparg `NB_SUBSCR` (26) | Subscript read `x[k]`. | `LIST`/`TUPLE`: unsigned bounds-checked index read. `DICT`: linear-probe lookup; missing key traps `PY_TRAP_MEM_FAULT`. Dict keys may be `INT`/`BOOL`/`SHORT_STR`/`LONG_STR`; other key tags trap `PY_TRAP_TYPE`. |
| `STORE_SUBSCR` | Subscript write `x[k] = v`. | `LIST`: bounds-checked index write. `DICT`: upsert via linear probe (maintains `used`; refuses inserts that would fill the table completely). `TUPLE`: traps `PY_TRAP_TYPE` (immutable). Pops key, container, value (3 items). |

## Partially supported bytecodes

| Bytecode | Description | Current limitation |
| --- | --- | --- |
| `LOAD_FAST_BORROW_LOAD_FAST_BORROW` | CPython 3.14 combined two-local load (opcode 87). | Expanded by preprocess into two `LOAD_FAST_BORROW` instructions; never reaches hardware. |
| `BINARY_OP` | Performs binary arithmetic/bitwise operation selected by `oparg`. | Arithmetic/bitwise opargs use the existing ALU path; `NB_SUBSCR` (oparg 26) routes to `S_CONTAINER`; unsupported variants trap or are rejected by preprocess. |
| `COMPARE_OP` | Performs rich comparison selected by `oparg`. | Only compare selectors `0..5` (`<,<=,==,!=,>,>=`) are decoded. |
| `COPY` | Duplicates a stack value at depth `oparg`. | Rejected by the image builder; no hardware execute path yet. |
| `SWAP` | Swaps TOS with a deeper stack element. | Rejected by the image builder; no hardware execute path yet. |
| `JUMP_IF_TRUE_OR_POP` | Jumps if truthy else pops TOS. | Not part of the current image-boot subset. |
| `JUMP_IF_FALSE_OR_POP` | Jumps if falsy else pops TOS. | Not part of the current image-boot subset. |

## Fully unsupported bytecodes

Any CPython 3.14 opcode **not listed in the first two tables** is fully
unsupported in the current PyCore flow.

For unsupported bytecodes, behavior is strict:

1. preprocess rejects the program before artifact generation when possible;
2. if one still reaches decode, it is treated as illegal and traps.

In short, unsupported bytecodes do not have fallback emulation in hardware.

## Semantic deviations from CPython

These are intentional or interim differences; they are not bugs to "fix" in
this milestone:

1. **INT/BOOL key non-equivalence.** CPython has `hash(True) == hash(1)` and
   `True == 1`, so `{1: v}[True]` hits. PyCore matches keys only within the same
   tag, so that lookup traps as key-not-found (`PY_TRAP_MEM_FAULT`).
2. **Missing dict key → `PY_TRAP_MEM_FAULT`.** There is no `KeyError` object;
   absent keys raise the memory-fault trap (KeyError analog).
3. **Negative list/tuple indices trap.** Bounds checks are unsigned; negative
   INT indices do not wrap to `size + idx`.
4. **Non-interned runtime strings as dict keys.** `LONG_STR` equality is
   descriptor (`{size, addr}`) equality and relies on tooling interning.
   Runtime-concatenated long strings live in the exec unit's private
   `string_mem` and are not interned; using them as dict keys is not
   semantically valid. Hardware cannot detect this.
5. **Dict fill policy.** Until rehash/grow exists, an insert that would make
   the table completely full traps `PY_TRAP_MEM_FAULT` so absent-key probes
   always terminate (at least one empty slot remains).
6. **No builtins fallback for names.** `LOAD_GLOBAL` / `LOAD_NAME` probe only
   the serialized module globals dict; missing names trap `PY_TRAP_MEM_FAULT`.
7. **Function object model.** `MAKE_FUNCTION` leaves a `CODE_OBJECT` handle on
   the stack and `CALL` treats that handle as the function. Defaults,
   annotations, closures, bound methods, and callable objects are out of scope.
8. **`LOAD_NAME` module-scope behavior.** The current hardware treats
   `LOAD_NAME` as a globals lookup, matching the image-boot module programs but
   not CPython's full locals/globals/builtins search chain.
9. **Image fidelity scope.** Images preserve the `compile()` object graph and
   bytecode-unit order, including `CACHE` and `EXTENDED_ARG`, but use PyCore's
   tagged 128-bit-slot layout rather than CPython C structs.

## Deferred container opcodes

The following container-related opcodes are explicitly deferred.
`image_from_source.py` rejects them with a `"Deferred opcode"` error message
before image generation; if somehow one reaches hardware it is trapped as
illegal. Each entry has a TODO hook ready for a follow-up PR.

| Bytecode | Description | Deferral reason |
| --- | --- | --- |
| `LIST_APPEND` | Append value to an existing list. | Requires mutable list resize (realloc or capacity extension). |
| `MAP_ADD` | Add a key/value pair to an existing dict. | Dict mutation via comprehension helper; use `STORE_SUBSCR`. |
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
