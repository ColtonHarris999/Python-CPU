# PyCore Bytecode Support Lists (CPython 3.14)

This file classifies bytecodes into fully supported, partially supported, and
fully unsupported for the current PyCore implementation.

**Machine source of truth:** `pycore/targets/pycore.json` → `opcodes`
(`support` / `hw_class` / `fold` / `supported_opargs` / `plan_track`).
The analyzer (`pycore/tools/btanalyze`) reads that file. This document is
the human notes — including semantic ceilings that remain even when JSON
says `execute` (e.g. `COMPARE_OP` numeric-only).

**Exception types** are tracked separately, the same way: machine catalog in
`pycore.json` → `exceptions.types`, human table in
[`exception_support.md`](exception_support.md). Roadmap:
[`planning/exceptions_full_support_plan.md`](../../planning/exceptions_full_support_plan.md).

## Inventory (from `pycore.json`)

Listed opcode rows only (unlisted CPython names still resolve via `obj_groups`
as `trap` / `INTERNAL` strip). Recompute after changing `opcodes`:

| `support` | Count | Meaning for the analyzer |
| --- | --- | --- |
| `execute` | 63 | hardware runs the documented subset |
| `partial` | 6 | runs, with a named ceiling (`message` / `supported_opargs`) |
| `strip` | 1 | `RESUME` (control marker) |
| `reject` | 3 | image tooling / decode refuse |
| `trap` | 10 | listed but not implemented (explicit OBJ_EXC / assert / with / except* rows) |

`partial` today includes `RAISE_VARARGS` (oparg 1 only). Object-protocol
opcodes are suppressed in the default analyzer view (`fit=infeasible`);
`--include-out-of-scope` reports `partial` as **warn** so remaining ceilings
are visible.

JSON `plan_track` on an opcode names the exceptions-plan track that lifts it
(`T1` … `T12`, `landed-B`, or `never` for compiler pseudo-ops).

## Fully supported bytecodes


| Bytecode                                | Description                                                                                 | PyCore-specific note                                                                                                                                                                                                                                                                                                                                                                                                                       |
| --------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CACHE`                                 | Inline cache entry used by CPython adaptive interpreter.                                    | Preserved in the image and skipped by fetch; slot order remains CPython-identical.                                                                                                                                                                                                                                                                                                                                                         |
| `EXTENDED_ARG`                          | Extends argument width of the following opcode.                                             | Preserved in the image and folded by fetch; following opcode sees the full argument.                                                                                                                                                                                                                                                                                                                                                       |
| `RESUME`                                | Marks function entry/resume points in CPython bytecode.                                     | Treated as a no-op control marker.                                                                                                                                                                                                                                                                                                                                                                                                         |
| `NOP`                                   | Explicit no-op left by dead-code elimination (e.g. `if False:`).                            | Decode empty case clone of `RESUME`/`NOT_TAKEN`; stack 0, no trap. Layer D: `img_nop`.                                                                                                                                                                                                                                                                                                                                                     |
| `LOAD_FAST`                             | Pushes a local variable onto the value stack.                                               | Mapped directly to local-window reads.                                                                                                                                                                                                                                                                                                                                                                                                     |
| `LOAD_FAST_BORROW`                      | Pushes a local variable with CPython borrow semantics.                                      | Executed the same as `LOAD_FAST` in current hardware.                                                                                                                                                                                                                                                                                                                                                                                      |
| `STORE_FAST`                            | Pops the top stack value into a local variable slot.                                        | Writes local-window storage directly.                                                                                                                                                                                                                                                                                                                                                                                                      |
| `LOAD_FAST_LOAD_FAST`                   | Push two locals; oparg `(hi<<4)|lo`.                                                        | Aliases `CONT_LFB_PAIR` (same as LFB_LFB); tag-agnostic; stack +2.                                                                                                                                                                                                                                                                                                                                                                         |
| `LOAD_FAST_BORROW_LOAD_FAST_BORROW`     | Push two locals; oparg `(hi<<4)|lo`.                                                        | Native `CONT_LFB_PAIR` on image-boot (same FSM as LFLF); borrow≡owned; stack +2. Legacy preprocess still expands to two `LOAD_FAST_BORROW`.                                                                                                                                                                                                                                                                                                |
| `STORE_FAST_LOAD_FAST`                  | Pop → `locals[hi]`, push `locals[lo]`.                                                      | New `CONT_SFLF`; net stack 0; `hi==lo` reloads stored value.                                                                                                                                                                                                                                                                                                                                                                               |
| `STORE_FAST_STORE_FAST`                 | Pop → `locals[hi]`, pop → `locals[lo]`.                                                     | New `CONT_SFSF`; net stack −2; unlocks LFLF-emitting swap/parallel assign.                                                                                                                                                                                                                                                                                                                                                                 |
| `DELETE_FAST`                           | Clears local slot `oparg` to unbound.                                                       | Writes `PY_TAG_UNINIT`; already-unbound traps `PY_TRAP_MEM_FAULT` (7).                                                                                                                                                                                                                                                                                                                                                                     |
| `LOAD_FAST_AND_CLEAR`                   | Push local `oparg`, then clear slot to unbound.                                             | New `CONT_LFAC`; stack +1; unbound does not trap (unlike `DELETE_FAST`); unbound push is `UNINIT` not `NULL`. Layer D: `img_load_fast_and_clear` (push half), `img_load_fast_and_clear_cleared` (clear half: a following `del` on the cleared slot traps 7).                                                                                                                                                                               |
| `LOAD_FAST_CHECK`                       | Push local `oparg`; trap if unbound.                                                        | Same datapath as `LOAD_FAST`; `UNINIT` → `PY_TRAP_MEM_FAULT` (7). Layer D: `img_load_fast_check`, `img_load_fast_check_unbound`.                                                                                                                                                                                                                                                                                                           |
| `LOAD_SMALL_INT`                        | Pushes a small immediate integer encoded in `oparg`.                                        | Fully supported fast-path immediate load.                                                                                                                                                                                                                                                                                                                                                                                                  |
| `LOAD_CONST`                            | Pushes `co_consts[oparg]` onto the value stack.                                             | One CPython code unit; hardware reads value+tag from the serialized `co_consts` tuple in dmem.                                                                                                                                                                                                                                                                                                                                             |
| `LOAD_GLOBAL`                           | Loads a global by name.                                                                     | Reads `co_names[namei]` (`namei = oparg >> 1`), probes the current frame's **globals** (`globals_base_r`), then on miss probes the boot-record **builtins** dict once (`builtins_base_r`). Optionally pushes `NULL` when `oparg & 1`. Missing in both → `PY_TRAP_MEM_FAULT`. `_bi_exec_globals` can point `globals_base_r` at a supplied dict for one frame.                                                                                                                                                                                                                                                              |
| `LOAD_NAME`                             | Loads a name by index.                                                                      | Same globals-then-builtins probe as `LOAD_GLOBAL` at module scope (no NULL push; `namei = oparg`). Full LEGB locals→globals→builtins for function/`exec` scopes is not implemented yet.                                                                                                                                                                                                                                                                                                              |
| `STORE_NAME`                            | Stores TOS into a module/global name.                                                       | Updates the current frame's globals dict, popping one value.                                                                                                                                                                                                                                                                                                                                                                                    |
| `STORE_GLOBAL`                          | Stores TOS into a global name.                                                              | Same hardware path as `STORE_NAME`.                                                                                                                                                                                                                                                                                                                                                                                                        |
| `PUSH_NULL`                             | Pushes CPython's non-method call sentinel.                                                  | Writes CONTROL+NULL (`PY_CTL_NULL`) to TOS.                                                                                                                                                                                                                                                                                                                                                                                               |
| `MAKE_FUNCTION`                         | Builds a function object from a code object.                                                | Interim model: function is the `CODE_OBJECT` handle itself; defaults/closures are rejected by tooling.                                                                                                                                                                                                                                                                                                                                     |
| `CALL`                                  | Invokes a callable with positional arguments.                                               | Supports CPython 3.14 non-method layout `callable, NULL, args...`; validates callable tag and argcount, pushes/pops hardware frames. `CODE_OBJECT` callees with `CO_VARKEYWORDS` still enter the binder so an (empty) `**kwargs` dict local is installed. `OBK_BUILTIN` / `BI_LEN` covers LIST/TUPLE/DICT/SET/STR/inline RANGE plus INSTANCE `__len__` via own `tp_dict` (miss → `ATTR_ERROR`). `BI_ORD` / `BI_CHR` convert between a one-character `SHORT_STR` and its `INT` code point in one cycle (inline payload, no `string_mem` access); `chr` rejects > U+10FFFF, negatives, and lone surrogates with `TYPE`. Layer D: `img_builtin_ord*`, `img_builtin_chr*`. |
| `CALL_KW`                               | Keyword / mixed calls (`f(1, b=2)`).                                                         | `CODE_OBJECT` binder uses `co_varnames` + `kwonlyargcount` + `co_posonlyargcount` + `co_defaults` / `co_kwdefaults`; `CO_VARARGS` packs extras into `*args`; `CO_VARKEYWORDS` packs leftovers into `**kwargs` (pre-sized dict). Posonly name as keyword → leftover / trap. Unexpected/duplicate kw → `CALL_FILTER` (duplicate still traps with varkw). `OBK_BUILTIN` / TYPE kwargs → `CALL_FILTER` (use firmware `CODE_OBJECT`). Layer D: `img_call_kw`, `img_varargs_*`, `img_varkw_*`, `img_posonly_*`, `img_print_sep_end`. |
| `CALL_FUNCTION_EX`                      | `f(*args)` / `f(*args, **kwargs)`.                                                          | Args: LIST or TUPLE (expand onto stack, then CALL/binder). Kwargs absent = NULL sentinel; present = `MUT_DICT` (order-sidecar bind; remaining kw-only filled from `co_kwdefaults`; leftovers packed when callee has `CO_VARKEYWORDS`). Layer D: `img_call_function_ex`, `img_call_function_ex_kw`, `img_varargs_ex_kw`, `img_varkw_call_ex`, `img_print_star_kw`. |
| `DICT_MERGE`                            | Merge TOS mapping into dict at `TOS-1-oparg`; pop TOS.                                      | Empty-dest fast path (CPython call `**kwargs` shape): alias source into dest RF slot. Non-empty uncontaminated A/B → `PY_TRAP_DICT_MERGE` (20) before commit; excore builds a fresh dict C (insert A then B, duplicate key → fatal `TYPE`), replaces A's slot, pops B (`COMPLETED` pop 2 push 1). Contaminated A/B (OBJECT keys) → pycore builds C in `pycore_cont_bulk.svh` (dup key → `TYPE`). Layer D: `img_dict_merge`. |
| `DICT_UPDATE`                           | `A.update(B)`: merge dict B (TOS) into dict A at `TOS-1-oparg`; pop TOS.                    | Both operands must be `MUT_DICT`. Uncontaminated A/B → `PY_TRAP_DICT_UPDATE` (19) before commit; excore grows A to fit `used(A)+used(B)` then inserts every entry of B, overwriting duplicates, in place (`COMPLETED` pop 1). Contaminated A/B (OBJECT keys) → pycore grow/rehash + insert in `pycore_cont_bulk.svh`. Emitted by `{**a, **b}` dict-unpack displays. Layer D: `img_dict_update`, `img_dict_update_obj`. |
| `MAP_ADD`                               | `dict[key]=value` inside a dict comprehension; value at TOS, key at TOS-1, dict at `TOS-2-oparg`; pop 2, leave dict. | Single-pair pycore insert reusing the `STORE_DICT` probe/upsert path; new key at load ≥ 2/3 → `DICT_GROW` (11) via excore. An `OBJECT` key sets the dict handle's contamination bit (written back to its RF slot). compile() emits `MAP_ADD` in dict comprehensions (with table/`RERAISE` cleanup — Option B below); `img_map_add` still drives it via the `MAP_ADD_SEQ` inject. |
| `TO_BOOL`                               | Converts TOS to exact bool for branch helpers.                                              | `CONT_TO_BOOL`: `None` → False; `INT`/`BOOL`/`FLOAT`/`SHORT_STR`/`LONG_STR` as before (corrupt short size >15 → `TYPE`); `TUPLE` / inline `RANGE` by length≠0; `LIST`/`DICT`/`SET` via header length/used. Other tags (incl. `OBJECT` without protocol) → `TYPE`. Layer D: `img_to_bool`, `img_to_bool_str`, `img_to_bool_none`, `img_to_bool_containers` (legacy `img_to_bool_type_trap` / `img_to_bool_list_trap` are positive None/list cases). |
| `UNARY_NOT`                             | Invert TOS bool (`not` after `TO_BOOL`).                                                    | `BOOL` bit invert in place; non-`BOOL` → `PY_TRAP_TYPE`. Layer D: `img_unary_not`.                                                                                                                                                                                                                                                                                                                                                         |
| `IS_OP`                                 | `is` / `is not` (oparg 0/1).                                                                | Full RF-entry identity → `BOOL`; all tags; no trap. Layer D: `img_is_op`.                                                                                                                                                                                                                                                                                                                                                                  |
| `NOT_TAKEN`                             | CPython branch prediction/adaptation marker.                                                | Treated as a no-op marker.                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `POP_TOP`                               | Pops and discards the top stack value.                                                      | Implemented as a stack-pointer decrement.                                                                                                                                                                                                                                                                                                                                                                                                  |
| `END_FOR`                               | Removes one loop-cleanup value.                                                             | `POP_TOP`-equivalent. Natural FOR_ITER exhaustion skips it; direct RTL coverage: `for_iter_end_for`.                                                                                                                                                                                                                                                                                                                                       |
| `POP_ITER`                              | Pops iterator state in loop/iteration sequences.                                            | Stack-pointer decrement at the FOR_ITER exhaustion target. Layer D: `img_for_iter`.                                                                                                                                                                                                                                                                                                                                                        |
| `RETURN_VALUE`                          | Returns the top-of-stack value from a function.                                             | Implemented return datapath is active. CPython 3.14 emits `LOAD_CONST`+`RETURN_VALUE` for `return True/False/None` (`RETURN_CONST` is absent). Layer D: `img_return_true`. |
| `PUSH_EXC_INFO`                         | Handler entry: push prior active exception, expose current.                                 | dmem exc-info push; stack `[exc]→[prev\|None,exc]`; latches `active_exc_r`. Type matching is `CHECK_EXC_MATCH`. See [`exception_support.md`](exception_support.md). |
| `CHECK_EXC_MATCH`                       | `except T:` type test.                                                                      | Identity, then `tp_base` walk (depth 8). `except (A, B):` one-level tuples (length ≤ 8); nested tuples → `TYPE`. `[exc,type]→[exc,bool]`. Layer D: `img_try_stopiteration*`, `img_try_exception`, `img_try_tuple_match`. |
| `POP_EXCEPT`                            | Exit `except` block.                                                                        | dmem-pop restore of prior active exc + pop TOS. |
| `RERAISE`                               | Re-raise (oparg 0/1).                                                                       | Re-enter table walk on TOS exception; oparg `1` does **not** dmem-pop (cleanup already ran `POP_EXCEPT`). Oparg `2` is Track 9 (`with`). Used by comprehension cleanup and nested handlers. |
| `UNPACK_EX`                             | Starred unpack: `before`, rest list, `after`.                                               | LIST/TUPLE sources only; allocates the middle rest as a LIST. Wrong length → `TYPE`. Layer D: `img_unpack_ex`. |
| `CALL_INTRINSIC_1` (arg 6)              | `INTRINSIC_LIST_TO_TUPLE`.                                                                  | Copies a LIST into a new TUPLE (CPython 3.14 `(*lst,)` / `tuple` materialization). Other intrinsic ids remain deferred. Layer D: `img_list_to_tuple`. |
| `JUMP_FORWARD`                          | Unconditionally jumps forward by relative offset.                                           | Fully handled by branch unit.                                                                                                                                                                                                                                                                                                                                                                                                              |
| `JUMP_BACKWARD`                         | Unconditionally jumps backward by relative offset.                                          | Fully handled by branch unit.                                                                                                                                                                                                                                                                                                                                                                                                              |
| `POP_JUMP_IF_TRUE`                      | Pops TOS and jumps if truthy.                                                               | Supported with numeric/bool truthiness rules.                                                                                                                                                                                                                                                                                                                                                                                              |
| `POP_JUMP_IF_FALSE`                     | Pops TOS and jumps if falsy.                                                                | Supported with numeric/bool truthiness rules.                                                                                                                                                                                                                                                                                                                                                                                              |
| `POP_JUMP_IF_NONE`                      | Pops TOS; jumps if value is `None`.                                                         | CONTROL+NONE (`pycore_is_none`); all other tags fall through; no TYPE trap. Layer D: `img_pop_jump_if_none`.                                                                                                                                                                                                                                                                                                                              |
| `POP_JUMP_IF_NOT_NONE`                  | Pops TOS; jumps if value is not `None`.                                                     | Same CONTROL+NONE rule. Layer D: `img_pop_jump_if_none`.                                                                                                                                                                                                                                                                                                                                                                                   |
| `BUILD_LIST`                            | Pops `count` values, allocates a list object, pushes a `MUT_COLLEC`/`MUT_LIST` handle.      | Multi-cycle `S_CONTAINER` FSM; heap bump-allocator at `HEAP_INIT_PTR` (default `PYCORE_HEAP_BASE` 0x0440). Allocates a stable 32-byte object + a `count`-sized element buffer (`capacity == count` exactly) in one combined OOM check. Index must be `INT` or `BOOL`; out-of-range or OOM traps `PY_TRAP_MEM_FAULT`. Empty list (`count=0`) allocates the object only (`ob_item=0`).                                                  |
| `BUILD_TUPLE`                           | Pops `count` values, allocates a tuple (no header), pushes a `TUPLE` handle `{size, addr}`. | Opcode 51 (resolved from CPython 3.14). Same index rules as LIST for `NB_SUBSCR`.                                                                                                                                                                                                                                                                                                                                                          |
| `BUILD_MAP`                             | Pops `2*count` items (interleaved key/value), allocates a dict, pushes `MUT_COLLEC`/`MUT_DICT`. | Open-addressed linear-probe insert. Keys: `INT`, `BOOL`, `FLOAT`, `SHORT_STR`, `LONG_STR`, `OBJECT` (identity; sets contamination bit). Slot count = `next_pow2(max(4, 2*count))`. Stable 48B object + insertion-order sidecar + relocatable table.                                                                                                                                                                                                                                |
| `BUILD_SET`                             | Pops `count` values, allocates a set, pushes a `MUT_COLLEC`/`MUT_SET` handle.               | Open-addressed element table (32B/slot). Same hash/rich-eq key rules as dict (no values). Deleted slots use the dedicated `PY_TAG_TOMBSTONE`. Images: `img_set_*`.                                                                                                                                                                                                                                                                                              |
| `BINARY_OP` with oparg `NB_SUBSCR` (26) | Subscript read `x[k]`.                                                                      | `LIST`/`TUPLE`: unsigned bounds-checked index read. `DICT`: linear-probe lookup; missing key traps `PY_TRAP_MEM_FAULT`. Dict keys may be `INT`/`BOOL`/`FLOAT`/`SHORT_STR`/`LONG_STR`; other key tags trap `PY_TRAP_TYPE`. `SHORT_STR`/`LONG_STR` (`CONT_SUBSCR_STR`): walks one UTF-8 **character** per cycle from the start, so `s[i]` agrees with `for c in s` (cost is O(i), like STR `FOR_ITER`); returns a one-character `SHORT_STR`. Index past the last character traps `PY_TRAP_MEM_FAULT`; malformed UTF-8 traps `PY_TRAP_TYPE`. Layer D: `img_str_subscr`, `img_str_subscr_long`, `img_str_subscr_unicode`, `img_str_subscr_loop`, `img_str_subscr_oob_trap`, `img_str_subscr_char_oob_trap`. |
| `STORE_SUBSCR`                          | Subscript write `x[k] = v`.                                                                 | `LIST`: bounds-checked index write. `DICT`: same-tag / rich-eq upsert on pycore (tombstone reuse); new-key insert at load ≥ 2/3 → `DICT_GROW` (11). `TUPLE`/`SET`: `TYPE`. Pops key, container, value (3 items). Prefer `d={}` + stores or locals for `BUILD_MAP` (CPython 3.14 may emit `BUILD_CONST_KEY_MAP` for constant `{k:v}`).                                                                                                      |
| `BINARY_SLICE`                          | Slice read `x[a:b]` (stack `subject, start, stop`).                                          | Strings only (`CONT_SLICE_STR`). Bounds are **character** indices, matching `s[i]` and `for c in s`; one UTF-8 walk resolves them to byte offsets, so cost is O(stop). Out-of-range bounds **clamp** like CPython (`"abc"[1:99] == "bc"`), `stop <= start` gives `""`, and omitted bounds arrive as `None`. Result ≤15 bytes is an inline `SHORT_STR`, longer goes to `string_mem` as `LONG_STR` via the slice port. Negative bounds trap `PY_TRAP_TYPE` (deviation 3); LIST/TUPLE subjects trap `PY_TRAP_TYPE` (not implemented). Note CPython folds all-literal slices (`s[1:3]`, `s[:]`) into a `slice` constant + `NB_SUBSCR` instead, which is still deferred. Layer D: `img_slice_str*`, `img_slice_list_trap`. |
| `COPY`                                  | Duplicates the stack entry at depth `oparg`, pushing a copy to TOS.                         | Clone of the `LOAD_FAST` datapath: reads RF slot `tos_index - oparg` and pushes the `{tag, value}` entry verbatim. Tag-agnostic, no trap. Value-stack-overflow is not detected (see deviation 10).                                                                                                                                                                                                                                         |
| `SWAP`                                  | Swaps TOS with the stack entry at depth `oparg`.                                            | Two-beat `S_CONTAINER` RF exchange (`CONT_LFB_PAIR` clone): writes deep→TOS then TOS→deep; tag-agnostic, net stack 0, no trap.                                                                                                                                                                                                                                                                                                             |




## Partially supported bytecodes


| Bytecode               | Description                                                                                                          | Current limitation                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BINARY_OP`            | Performs binary arithmetic/bitwise operation selected by `oparg`.                                                    | Arithmetic/bitwise opargs use the existing ALU path; `NB_SUBSCR` (oparg 26) routes to `S_CONTAINER`. `NB_INPLACE_ADD` (13) with a LIST lhs routes to LIST_EXTEND semantics and supports LIST/TUPLE rhs, including the existing excore grow path. Unsupported variants trap or are rejected by preprocess.                                                                                                                                                                                                                                                         |
| `COMPARE_OP`           | Compares TOS-2 and TOS-1 using the packed CPython 3.14 `oparg`, replacing both with `BOOL`.                          | Selectors `0..5` (`<,<=,==,!=,>,>=`); native `INT`/`BOOL`/`FLOAT` fast path, net stack −1. Non-numeric tags trap `PY_TRAP_TYPE` (1); there is no generic rich-compare protocol. Layer D: `img_compare_op`, `img_compare_op_type_trap`.                                                                                                                                                                                                                                                                                                                            |
| `GET_ITER`             | Replaces TOS with iterator state.                                                                                    | Native LIST/TUPLE/STR/DICT/SET/`PY_TAG_RANGE` → hybrid `PY_TAG_ITER` (kinds 0–3, 5–6). `OBJECT`/`OBK_INSTANCE`: resolve `__iter__`, protocol `CALL`; return converts native containers / existing `ITER`, else wraps `HEAP_ITER` kind 4. Missing `__iter__` → `TYPE`. Coverage: `img_for_iter_*`, `img_for_iter_object_*`. |
| `FOR_ITER`             | Advances the iterator at TOS, pushing one value or taking the exhaustion edge.                                       | Native kinds as before. `HEAP_ITER`: resolve `__next__`, protocol `CALL`; `StopIteration` via §6.1.1 `call_exc_*` + `iter_exhaust_type_r` → native exhaust redirect (handle **identity**, not MRO — see [`exception_support.md`](exception_support.md)). Size-changing DICT/SET mutation → `TYPE`. Exhaustion skips `END_FOR` and redirects to `POP_ITER`. |
| `RAISE_VARARGS`        | Raises an exception (oparg 0/1/2).                                                                                   | JSON `partial`; `supported_opargs: [1]`. oparg `1`: build `OBK_EXCEPTION` treating TOS as a **type**, walk `co_exceptiontable` (code field 7); hit → redirect (active exc set by `PUSH_EXC_INFO`); miss → `PY_TRAP_RAISE` (17) unless a container protocol CALL is active (§6.1.1). Oparg 0/2 → `TYPE` until Track 4. Type vs instance is Track 2. Wave A types are seeded. Layer D: `img_raise_varargs`, `img_try_stopiteration*`, `img_try_exception`. |
| `JUMP_IF_TRUE_OR_POP`  | Jumps if truthy else pops TOS.                                                                                       | Not part of the current image-boot subset.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `JUMP_IF_FALSE_OR_POP` | Jumps if falsy else pops TOS.                                                                                        | Not part of the current image-boot subset.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `LIST_APPEND`          | Appends TOS to the list `oparg` slots below it (`list, unused[oparg-1], v -- list, unused[oparg-1]`); pops only `v`. | Fast path (`CONT_LIST_APPEND`, opcode 78): spare capacity (`length < capacity`) appends in place, 5 dmem ops, no trap. Grow path (`length == capacity`) raises `PY_TRAP_LIST_GROW` (trap 9) before any commit. With `EXCORE_EN=1` the excore doubles the buffer (floor 4), copies, appends, and returns `COMPLETED`. With `EXCORE_EN=0` it is fatal. Comprehensions serialize through GET_ITER/FOR_ITER for LIST/TUPLE sources; a non-empty result still needs this grow/excore path. Spare-capacity coverage remains hand-assembled.                             |
| `LIST_EXTEND`          | Extends the list `oparg` slots below TOS with the iterable at TOS; pops only the iterable.                           | Empty LIST/TUPLE source is a no-op pop on pycore. Non-empty always raises `PY_TRAP_LIST_EXTEND` (trap 10); with `EXCORE_EN=1` the excore copies in place when `need <= cap`, else grows-to-fit, then `COMPLETED` pop 1. Unsupported iterable tags → `PY_TRAP_TYPE`. Emitted by compile() for list-display unpack (`[1,2,*x]`, `[*a,*b]`); `list.extend` method calls still need `LOAD_ATTR`. LIST `NB_INPLACE_ADD` (`+=`) also routes here. Fixtures: `list_extend_empty` / fatal (single-core), `extend_*` + `img_list_extend` / `img_for_iter_grow` (two-core). |
| `DELETE_SUBSCR`        | `del container[key]` — pops container and key.                                                                       | List: type/bounds on pycore; last element → O(1) length-- on pycore; mid delete → `PY_TRAP_LIST_DELETE` (12) for excore shift-down (`COMPLETED` pop 2); capacity unchanged; OOB → `MEM_FAULT`. Tuple / set → `TYPE`. Dict: same-tag / rich-eq hit writes dedicated `PY_TAG_TOMBSTONE` and decrements `used` on pycore; miss → `MEM_FAULT`. Delete never reallocates. Images: `img_list_del_*`, `img_dict_del_*`, `img_for_iter_delete`, `img_for_iter_clear`.                                                                                        |
| `CONTAINS_OP`          | `x in container` / `x not in container` (oparg 0/1); needle then container on stack; pushes BOOL.                    | List/tuple: linear scan with INT/BOOL cross-equality (`True == 1`). Dict/set: hash probe + rich-eq on pycore; miss → False (not KeyError). Tombstones are skipped. Images: `img_dict_contains*`, `img_set_*`, `img_list_contains_*`, `img_tuple_contains`.                                                                                                                                                                                                                                                                                                        |
| `SET_ADD`              | Adds TOS to the set `oparg` slots below; pops only the element.                                                      | Probe/insert on pycore (same hash/rich-eq as dict). Load ≥ 2/3 (or empty table) → `SET_GROW` (13); excore reallocates, rehashes, completes insert (`COMPLETED`). Direct SET sources use native iterator kind 6. Coverage via `img_set_*` / hand fixtures. |
| `SET_UPDATE`           | Updates the set `oparg` slots below TOS from the iterable at TOS; pops the iterable.                                 | When A and source B are both uncontaminated and B is `LIST`/`SET`/`DICT` (`DICT` inserts keys) → `PY_TRAP_SET_UPDATE` (14) before commit; excore grow-to-fit + merge (`COMPLETED` pop 1). Contaminated A/B or a `TUPLE` source → pycore grow/rehash + insert in `pycore_cont_bulk.svh` (tuples have no contamination bit). Unsupported iterable → `TYPE`. Layer D: `img_set_update`, `img_set_update_tuple`.                                                                                                                                                                                                                                                                                                                     |




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

1. **INT/BOOL/FLOAT cross-tag keys stay on pycore.** Rich equality
  (`True == 1`, `1.0 == 1`, …) runs on the probe path for dict and set.
   Only capacity-changing / O(n) memmove work is offloaded to excore.
2. **Missing dict key →** `PY_TRAP_MEM_FAULT`**.** There is no `KeyError` object
  yet (`KeyError` is `absent` in [`exception_support.md`](exception_support.md));
  absent keys raise the memory-fault trap (KeyError analog). Track 6 splits this
  site to `KeyError` after T5-A seeds it. `CONTAINS_OP` misses push `False`
  instead.
3. **Negative list/tuple indices trap.** Bounds checks are unsigned; negative
  INT indices do not wrap to `size + idx`.
4. **Non-interned runtime strings as dict keys.** `LONG_STR` equality is
  descriptor (`{size, addr}`) equality and relies on tooling interning.
   Runtime-concatenated long strings live in the exec unit's private
   `string_mem` and are not interned; using them as dict keys is not
   semantically valid. Hardware cannot detect this.
5. **Dict grow via excore.** Load ≥ 2/3 (or empty table / no free slot) before
  a new-key insert raises `DICT_GROW` (11). With `EXCORE_EN=1` excore
   reallocates the table, rehashes, and completes the STORE; without excore
   the trap is fatal. See `pycore/docs/dict_excore.md`.
6. **Globals then builtins (not full LEGB).** `LOAD_GLOBAL` / `LOAD_NAME`
   probe the current frame's globals dict (`globals_base_r`), then the
   boot-record builtins dict (`CONT_LOAD_GLOBAL` + `builtins_base_r`).
   `exec(code, g)` switches `globals_base_r` for that callee via
   `_bi_exec_globals`. There is still no locals-mapping
   step for `LOAD_NAME` inside functions / `exec` / class bodies. Missing in
   both dicts traps `PY_TRAP_MEM_FAULT`. See
   `planning/builtins_bytecode_support_plan.md`.
7. **Function object model.** `MAKE_FUNCTION` leaves a `CODE_OBJECT` handle on
  the stack and `CALL` treats that handle as the function. Defaults are folded
  at image-build time; annotations, closures, and generic `__call__` objects
  remain out of scope. `OBK_BUILTIN` / `BI_*` ids use the CALL FSM fast path
  (e.g. `BI_LEN` header reads) instead of a Python frame.
8. `LOAD_NAME` **module-scope behavior.** Hardware uses the same
  globals-then-builtins path as `LOAD_GLOBAL` (without the NULL push). That
  matches image-boot module programs and builtin resolution, but not
  CPython's full locals→globals→builtins chain.
9. **Image fidelity scope.** Images preserve the `compile()` object graph and
  bytecode-unit order, including `CACHE` and `EXTENDED_ARG`, but use PyCore's
   tagged 128-bit-slot layout rather than CPython C structs.
10. **No value-stack-overflow detection.** Pushing opcodes (`COPY`,
  `LOAD_FAST`, `LOAD_SMALL_INT`, `PUSH_NULL`, etc.) advance `tos_index`
   without a capacity check; an over-deep stack silently overruns RF slots
   instead of raising. The flow relies on `co_stacksize`-valid bytecode. A
   stack-limit trap is future work.
11. **Unbound local →** `PY_TRAP_MEM_FAULT`**.** CPython raises
  `UnboundLocalError` (`absent` until T5-A). A second `del`
   (`DELETE_FAST` on `UNINIT`) and use-after-`del` / maybe-unbound loads
   (`LOAD_FAST_CHECK` on `UNINIT`) both trap memory-fault (7). Track 6
   converts this site after the type is seeded.
12. `LOAD_FAST_AND_CLEAR` **unbound ≠** `DELETE_FAST`**.** CPython pushes
  `NULL` and clears; PyCore pushes `PY_TAG_UNINIT` and clears. Already-unbound
   slots do not trap (comprehension save of a maybe-unbound outer local).
13. `IS_OP` **tagged-scalar identity.** PyCore compares full RF entries
  (tag + payload). Equal unboxed `INT`/`FLOAT`/`SHORT_STR` values always
   `is`; CPython heap objects with equal value may not. Handle tags
   (`LIST`/`DICT`/`TUPLE`/…) remain pointer-identity.
14. **Slice bounds are unsigned and clamp; negatives trap.** `BINARY_SLICE`
  clamps out-of-range bounds exactly as CPython does, but a negative bound
   traps `PY_TRAP_TYPE` rather than counting from the end (the same unsigned
   rule as deviation 3 for indices). So `s[1:99]` works and `s[1:-1]` traps.
   Coverage: `img_slice_str_clamp`, `img_slice_str_neg_trap`.
15. **String length is bytes, indexing and iteration are characters.** `BI_LEN`
  returns the UTF-8 **byte** count from the `SHORT_STR` size nibble or the
   `LONG_STR` descriptor, while `s[i]` and `for c in s` both step whole
   **characters**. The two agree for ASCII. For non-ASCII, `len(s)` overstates
   the character count, so `range(len(s))` walks past the last character and
   `s[i]` traps `PY_TRAP_MEM_FAULT` instead of silently returning a partial
   continuation byte. Coverage: `img_str_subscr_char_oob_trap`.
16. **Exceptions do not propagate across frames.** `RAISE_VARARGS` walks only
  the raising code object's own `co_exceptiontable`; a miss is
   `PY_TRAP_RAISE` (17) even when a caller has a matching handler. Keep a raise
   and its handler in one frame until Track 3. Boot seeds Wave A exception
   types (including `SyntaxError` under `Exception`). `CHECK_EXC_MATCH` is
   identity then MRO; `OBK_EXCEPTION.args` is always empty until Track 2, so
   messages are passed by writing a global before raising. Coverage:
   `img_try_exc_types`, `img_try_exc_cross_frame_fatal`,
   `img_try_syntaxerror_msg`.
17. `COMPARE_OP` **numeric ceiling.** Native comparison uses the signed 64-bit
  INT fast path and existing INT/BOOL-to-FLOAT promotion. Integers outside
   that range and mixed large-INT/FLOAT precision boundaries do not provide
   CPython arbitrary-precision comparison semantics. Strings, `None`,
   containers, and user-defined rich comparison trap `PY_TRAP_TYPE` instead.



## Comprehension `RERAISE` policy

CPython list/set/dict comprehensions embed exception-table cleanup that uses
`RERAISE`. **Policy (option B):** image tooling accepts `RERAISE` and serializes
`co_exceptiontable` on code objects; hardware walks the table on raise/reraise
(see `planning/for_loop_full_support_plan.md`). List comps from real
`compile()` run on the two-core top when `LIST_APPEND` grow is required
(`img_list_comp_basic`, `img_list_comp_fast_clear`). Dict comps that need
`MAP_ADD` + grow remain a follow-on (use `MAP_ADD_SEQ` inject until then).

## Exception-related opcodes (`OBJ_EXC` + assert / with)

Type objects are **not** opcodes — see [`exception_support.md`](exception_support.md).
This table is the opcode half of that tracker. `plan_track` is the exceptions
plan track that lifts the row (`never` = compiler pseudo; do not implement).


| Bytecode                 | JSON `support` | `plan_track` | Note |
| ------------------------ | -------------- | ------------ | ---- |
| `RAISE_VARARGS`          | `partial`      | T4 (oparg 0/2); T2 type-vs-instance | oparg 1 landed-B |
| `PUSH_EXC_INFO`          | `execute`      | landed-B     | |
| `CHECK_EXC_MATCH`        | `execute`      | landed-T1    | identity + `tp_base` walk + one-level tuples |
| `POP_EXCEPT`             | `execute`      | landed-B     | |
| `RERAISE`                | `execute`      | T9 (oparg 2) | oparg 0/1 landed-B |
| `CHECK_EG_MATCH`         | `trap`         | T11          | `except*` |
| `WITH_EXCEPT_START`      | `trap`         | T9           | `with` exception path |
| `LOAD_SPECIAL`           | `trap`         | T9           | `OBJ_NS`; `__enter__`/`__exit__` |
| `LOAD_COMMON_CONSTANT`   | `trap`         | T7           | `OBJ_NS`; oparg 0 = `AssertionError` |
| `CALL_INTRINSIC_2`       | `trap`         | T11          | `INTRINSIC_PREP_RERAISE_STAR` |
| `SETUP_FINALLY`          | `trap`         | never        | compiler pseudo; **not** in `co_code` |
| `SETUP_WITH`             | `trap`         | never        | compiler pseudo |
| `SETUP_CLEANUP`          | `trap`         | never        | compiler pseudo |
| `POP_BLOCK`              | `trap`         | never        | compiler pseudo |
| `EXIT_INIT_CHECK`        | `trap`         | never        | not part of the exceptions plan |

Real `try/finally` / `with` in CPython 3.14 use exception tables + `RERAISE`,
not `SETUP_*`. Image tooling must keep rejecting the pseudo-ops if they ever
appear.

## Deferred container opcodes

The following container-related opcodes are explicitly deferred.
`image_from_source.py` rejects them with a `"Deferred opcode"` error message
before image generation; if somehow one reaches hardware it is trapped as
illegal. Each entry has a TODO hook ready for a follow-up PR.


| Bytecode              | Description                               | Deferral reason                                                        |
| --------------------- | ----------------------------------------- | ---------------------------------------------------------------------- |
| `STORE_SLICE`         | Slice write `x[a:b] = v`.                 | Requires multi-element copy allocation.                                |
| `slice` **constants** | All-literal slices (`s[1:3]`, `s[:]`).    | CPython folds these to a `slice` constant + `NB_SUBSCR`; needs slice objects. Use a variable bound to get `BINARY_SLICE`. |
| `BUILD_CONST_KEY_MAP` | Const-key map literal.                    | Use `BUILD_MAP` + stores, or empty dict + `STORE_SUBSCR`.              |
