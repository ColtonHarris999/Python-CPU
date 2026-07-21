# PyCore Bytecode Support Lists (CPython 3.14)

This file classifies bytecodes into fully supported, partially supported, and
fully unsupported for the current PyCore implementation.

## Fully supported bytecodes

| Bytecode | Description | PyCore-specific note |
| --- | --- | --- |
| `CACHE` | Inline cache entry used by CPython adaptive interpreter. | Preserved in the image and skipped by fetch; slot order remains CPython-identical. |
| `EXTENDED_ARG` | Extends argument width of the following opcode. | Preserved in the image and folded by fetch; following opcode sees the full argument. |
| `RESUME` | Marks function entry/resume points in CPython bytecode. | Treated as a no-op control marker. |
| `NOP` | Explicit no-op left by dead-code elimination (e.g. `if False:`). | Decode empty case clone of `RESUME`/`NOT_TAKEN`; stack 0, no trap. Layer D: `img_nop`. |
| `LOAD_FAST` | Pushes a local variable onto the value stack. | Mapped directly to local-window reads. |
| `LOAD_FAST_BORROW` | Pushes a local variable with CPython borrow semantics. | Executed the same as `LOAD_FAST` in current hardware. |
| `STORE_FAST` | Pops the top stack value into a local variable slot. | Writes local-window storage directly. |
| `LOAD_FAST_LOAD_FAST` | Push two locals; oparg `(hi<<4)\|lo`. | Aliases `CONT_LFB_PAIR` (same as LFB_LFB); tag-agnostic; stack +2. |
| `LOAD_FAST_BORROW_LOAD_FAST_BORROW` | Push two locals; oparg `(hi<<4)\|lo`. | Native `CONT_LFB_PAIR` on image-boot (same FSM as LFLF); borrow≡owned; stack +2. Legacy preprocess still expands to two `LOAD_FAST_BORROW`. |
| `STORE_FAST_LOAD_FAST` | Pop → `locals[hi]`, push `locals[lo]`. | New `CONT_SFLF`; net stack 0; `hi==lo` reloads stored value. |
| `STORE_FAST_STORE_FAST` | Pop → `locals[hi]`, pop → `locals[lo]`. | New `CONT_SFSF`; net stack −2; unlocks LFLF-emitting swap/parallel assign. |
| `DELETE_FAST` | Clears local slot `oparg` to unbound. | Writes `PY_TAG_UNINIT`; already-unbound traps `PY_TRAP_MEM_FAULT` (7). |
| `LOAD_FAST_AND_CLEAR` | Push local `oparg`, then clear slot to unbound. | New `CONT_LFAC`; stack +1; unbound does not trap (unlike `DELETE_FAST`); unbound push is `UNINIT` not `NULL`. Layer D: `img_load_fast_and_clear` (push half), `img_load_fast_and_clear_cleared` (clear half: a following `del` on the cleared slot traps 7). |
| `LOAD_FAST_CHECK` | Push local `oparg`; trap if unbound. | Same datapath as `LOAD_FAST`; `UNINIT` → `PY_TRAP_MEM_FAULT` (7). Layer D: `img_load_fast_check`, `img_load_fast_check_unbound`. |
| `LOAD_SMALL_INT` | Pushes a small immediate integer encoded in `oparg`. | Fully supported fast-path immediate load. |
| `LOAD_CONST` | Pushes `co_consts[oparg]` onto the value stack. | One CPython code unit; hardware reads value+tag from the serialized `co_consts` tuple in dmem. |
| `LOAD_GLOBAL` | Loads a global by name. | Reads `co_names[namei]`, probes module globals, and optionally pushes `NULL` when `oparg & 1`. No builtins fallback. |
| `LOAD_NAME` | Loads a name by index. | Same globals lookup path as `LOAD_GLOBAL` at module scope; no locals/builtins chain. |
| `STORE_NAME` | Stores TOS into a module/global name. | Updates the serialized globals dict, popping one value. |
| `STORE_GLOBAL` | Stores TOS into a global name. | Same hardware path as `STORE_NAME`. |
| `PUSH_NULL` | Pushes CPython's non-method call sentinel. | Writes `{PY_TAG_NULL, 0}` to TOS. |
| `MAKE_FUNCTION` | Builds a function object from a code object. | Interim model: function is the `CODE_OBJECT` handle itself; defaults/closures are rejected by tooling. |
| `CALL` | Invokes a callable with positional arguments. | Supports CPython 3.14 non-method layout `callable, NULL, args...`; validates callable tag and argcount, pushes/pops hardware frames. |
| `TO_BOOL` | Converts TOS to exact bool for branch helpers. | Rewrites TOS in place to `BOOL` for `INT`/`BOOL`/`FLOAT`; other tags (incl. `None`, containers, strings) trap `PY_TRAP_TYPE`. Layer D: `img_to_bool` (INT/BOOL/FLOAT, incl. `0.0` falsy), `img_to_bool_type_trap` (None), `img_to_bool_str_trap` (str), `img_to_bool_list_trap` (list). |
| `UNARY_NOT` | Invert TOS bool (`not` after `TO_BOOL`). | `BOOL` bit invert in place; non-`BOOL` → `PY_TRAP_TYPE`. Layer D: `img_unary_not`. |
| `IS_OP` | `is` / `is not` (oparg 0/1). | Full RF-entry identity → `BOOL`; all tags; no trap. Layer D: `img_is_op`. |
| `NOT_TAKEN` | CPython branch prediction/adaptation marker. | Treated as a no-op marker. |
| `POP_TOP` | Pops and discards the top stack value. | Implemented as a stack-pointer decrement. |
| `POP_ITER` | Pops iterator state in loop/iteration sequences. | Implemented as a stack-pointer decrement. |
| `RETURN_VALUE` | Returns the top-of-stack value from a function. | Implemented return datapath is active. |
| `JUMP_FORWARD` | Unconditionally jumps forward by relative offset. | Fully handled by branch unit. |
| `JUMP_BACKWARD` | Unconditionally jumps backward by relative offset. | Fully handled by branch unit. |
| `POP_JUMP_IF_TRUE` | Pops TOS and jumps if truthy. | Supported with numeric/bool truthiness rules. |
| `POP_JUMP_IF_FALSE` | Pops TOS and jumps if falsy. | Supported with numeric/bool truthiness rules. |
| `POP_JUMP_IF_NONE` | Pops TOS; jumps if tag is `NONE`. | Tag-only (`PY_TAG_NONE`); all other tags fall through; no TYPE trap. Layer D: `img_pop_jump_if_none`. |
| `POP_JUMP_IF_NOT_NONE` | Pops TOS; jumps if tag is not `NONE`. | Same tag-only rule. Layer D: `img_pop_jump_if_none`. |
| `BUILD_LIST` | Pops `count` values, allocates a list object, pushes a `LIST`-tagged handle. | Multi-cycle `S_CONTAINER` FSM; heap bump-allocator at `HEAP_INIT_PTR` (default `PYCORE_HEAP_BASE` 0x0400). Layout v2 (Phase A): allocates a stable 32-byte object + a `count`-sized element buffer (`capacity == count` exactly) in one combined OOM check. Index must be `INT` or `BOOL`; out-of-range or OOM traps `PY_TRAP_MEM_FAULT`. Empty list (`count=0`) allocates the object only (`ob_item=0`). |
| `BUILD_TUPLE` | Pops `count` values, allocates a tuple (no header), pushes a `TUPLE` handle `{size, addr}`. | Opcode 51 (resolved from CPython 3.14). Same index rules as LIST for `NB_SUBSCR`. |
| `BUILD_MAP` | Pops `2*count` items (interleaved key/value), allocates a dict, pushes `DICT`. | Open-addressed linear-probe insert. Keys: `INT`, `BOOL`, `SHORT_STR`, `LONG_STR`. Slot count = `next_pow2(max(4, 2*count))`. |
| `BINARY_OP` with oparg `NB_SUBSCR` (26) | Subscript read `x[k]`. | `LIST`/`TUPLE`: unsigned bounds-checked index read. `DICT`: linear-probe lookup; missing key traps `PY_TRAP_MEM_FAULT`. Dict keys may be `INT`/`BOOL`/`SHORT_STR`/`LONG_STR`; other key tags trap `PY_TRAP_TYPE`. |
| `STORE_SUBSCR` | Subscript write `x[k] = v`. | `LIST`: bounds-checked index write. `DICT`: upsert via linear probe (maintains `used`; refuses inserts that would fill the table completely). `TUPLE`: traps `PY_TRAP_TYPE` (immutable). Pops key, container, value (3 items). |
| `COPY` | Duplicates the stack entry at depth `oparg`, pushing a copy to TOS. | Clone of the `LOAD_FAST` datapath: reads RF slot `tos_index - oparg` and pushes the `{tag, value}` entry verbatim. Tag-agnostic, no trap. Value-stack-overflow is not detected (see deviation 10). |
| `SWAP` | Swaps TOS with the stack entry at depth `oparg`. | Two-beat `S_CONTAINER` RF exchange (`CONT_LFB_PAIR` clone): writes deep→TOS then TOS→deep; tag-agnostic, net stack 0, no trap. |

## Partially supported bytecodes

| Bytecode | Description | Current limitation |
| --- | --- | --- |
| `BINARY_OP` | Performs binary arithmetic/bitwise operation selected by `oparg`. | Arithmetic/bitwise opargs use the existing ALU path; `NB_SUBSCR` (oparg 26) routes to `S_CONTAINER`; unsupported variants trap or are rejected by preprocess. |
| `COMPARE_OP` | Performs rich comparison selected by `oparg`. | Only compare selectors `0..5` (`<,<=,==,!=,>,>=`) are decoded. |
| `JUMP_IF_TRUE_OR_POP` | Jumps if truthy else pops TOS. | Not part of the current image-boot subset. |
| `JUMP_IF_FALSE_OR_POP` | Jumps if falsy else pops TOS. | Not part of the current image-boot subset. |
| `LIST_APPEND` | Appends TOS to the list `oparg` slots below it (`list, unused[oparg-1], v -- list, unused[oparg-1]`); pops only `v`. | Fast path (`CONT_LIST_APPEND`, opcode 78): spare capacity (`length < capacity`) appends in place, 5 dmem ops, no trap. Grow path (`length == capacity`) raises `PY_TRAP_LIST_GROW` (trap 9) before any commit. With `EXCORE_EN=1` the excore doubles the buffer (floor 4), copies, appends, and returns `COMPLETED`. With `EXCORE_EN=0` it is fatal. `compile()` only emits this inside comprehensions (`FOR_ITER`/`GET_ITER` still unsupported); coverage is via hand-assembled fixtures. |
| `LIST_EXTEND` | Extends the list `oparg` slots below TOS with the iterable at TOS; pops only the iterable. | Fast path (`CONT_LIST_EXTEND`, opcode 79) when `len + src_len <= capacity` (LIST or TUPLE sources only; empty source is a no-op pop). Grow path raises `PY_TRAP_LIST_EXTEND` (trap 10); with `EXCORE_EN=1` the excore grows-to-fit and completes the extend (`COMPLETED`, pop 1). Unsupported iterable tags → `PY_TRAP_TYPE`. Emitted by compile() for list-display unpack (`[1,2,*x]`, `[*a,*b]`); `list.extend` method calls still need `LOAD_ATTR`. Fixtures: `list_extend_*` (single-core), `extend_*` + `img_list_extend` (two-core). |
| `DELETE_SUBSCR` | `del container[key]` — pops container and key. | List: in-place shift-down on pycore (`CONT_DELETE_LIST`, opcode 8); capacity unchanged; OOB → `MEM_FAULT`. Tuple/dict: `TYPE` trap (dict tombstones deferred). No excore — delete never reallocates. |
| `CONTAINS_OP` | `x in container` / `x not in container` (oparg 0/1); needle then container on stack; pushes BOOL. | List/tuple: linear scan (`CONT_CONTAINS_LIST` / `_TUPLE`) with INT/BOOL cross-equality (`True == 1`). Dict: hash probe (`CONT_CONTAINS_DICT`); miss → False (not KeyError / not `MEM_FAULT`); key match is same-tag like `NB_SUBSCR`. All on pycore — no capacity change, no excore. |

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
10. **No value-stack-overflow detection.** Pushing opcodes (`COPY`,
   `LOAD_FAST`, `LOAD_SMALL_INT`, `PUSH_NULL`, etc.) advance `tos_index`
   without a capacity check; an over-deep stack silently overruns RF slots
   instead of raising. The flow relies on `co_stacksize`-valid bytecode. A
   stack-limit trap is future work.
11. **Unbound local → `PY_TRAP_MEM_FAULT`.** CPython raises
   `UnboundLocalError`; PyCore has no exception objects, so a second `del`
   (`DELETE_FAST` on `UNINIT`) and use-after-`del` / maybe-unbound loads
   (`LOAD_FAST_CHECK` on `UNINIT`) both trap memory-fault (7).
12. **`LOAD_FAST_AND_CLEAR` unbound ≠ `DELETE_FAST`.** CPython pushes
   `NULL` and clears; PyCore pushes `PY_TAG_UNINIT` and clears. Already-unbound
   slots do not trap (comprehension save of a maybe-unbound outer local).
13. **`IS_OP` tagged-scalar identity.** PyCore compares full RF entries
   (tag + payload). Equal unboxed `INT`/`FLOAT`/`SHORT_STR` values always
   `is`; CPython heap objects with equal value may not. Handle tags
   (`LIST`/`DICT`/`TUPLE`/…) remain pointer-identity.

## Deferred container opcodes

The following container-related opcodes are explicitly deferred.
`image_from_source.py` rejects them with a `"Deferred opcode"` error message
before image generation; if somehow one reaches hardware it is trapped as
illegal. Each entry has a TODO hook ready for a follow-up PR.

| Bytecode | Description | Deferral reason |
| --- | --- | --- |
| `MAP_ADD` | Add a key/value pair to an existing dict. | Dict mutation via comprehension helper; use `STORE_SUBSCR`. |
| `DICT_UPDATE` | Update dict from a mapping. | Requires dict merge semantics. |
| `DICT_MERGE` | Merge dict into another dict. | Requires dict iteration. |
| `BINARY_SLICE` | Slice read `x[a:b]`. | Requires multi-element copy allocation. |
| `STORE_SLICE` | Slice write `x[a:b] = v`. | Same. |
| `BUILD_SET` | Build a set literal. | Set type not yet implemented in hardware. |
| `SET_ADD` | Append to a set comprehension. | Requires set insert. |
| `SET_UPDATE` | Update a set. | Requires set merge. |
