# Bytecode support plan

Remaining opcode work. The living matrix is
[`pycore/docs/bytecode_support.md`](../pycore/docs/bytecode_support.md)
and `pycore/targets/pycore.json`. Update those in the same PR that
changes hardware or image validation.

This file is the **order** of remaining lifts, not a second table.

## Shipped (do not re-plan)

`execute` / documented `partial` rows already on main: ALU, jumps, CALL /
CALL_KW / CALL_FUNCTION_EX, containers, GET_ITER / FOR_ITER, exception
table ops (RAISE 0/1, PUSH_EXC_INFO, CHECK_EXC_MATCH MRO+tuples,
POP_EXCEPT, RERAISE 0/1), string `BINARY_SLICE` (variable bounds and
host fold of unit-step literals `s[1:]` / `s[:]` → `BINARY_SLICE`),
native `LOAD_ATTR` methods, `UNPACK_EX`, `LIST_TO_TUPLE`.

Host images still use CPython `compile()`. A step other than `None`/1
on a literal slice is still rejected (`BINARY_SLICE` has no step).

## Remaining, grouped

### Needed soon (language you can already write around)

| Opcode / ceiling | Why it still matters | Owner |
| --- | --- | --- |
| List/tuple `BINARY_SLICE` | tokenizer/compiler can rewrite with `copy_range`; pull if the helper dominates size | pycore |
| `TO_BOOL` on `OBJECT` (`__bool__` / `__len__`) | remaining wave-4 bytecode | pycore |
| `LOAD_SUPER_ATTR` | `super()` in methods | pycore |
| `RAISE_VARARGS` oparg 2 | `raise e from cause` | exceptions T4 leftover |
| Negative indices | deviation 3; rewrite with `len-1` until it hurts | pycore later |

### Needed for a fuller compiler emit list (after first `compile()`)

The on-device compiler must **not emit** these in v1. They become
compile-time errors, not illegal-opcode traps. Lift them when user
programs need them, not to unblock `eval(compile("1+2"))`.

| Opcode | Use |
| --- | --- |
| `LOAD_BUILD_CLASS` / `LOAD_LOCALS` | runtime `class` |
| `IMPORT_NAME` / `IMPORT_FROM` / `IMPORT_STAR` | `import` |
| `MAKE_CELL` / `LOAD_DEREF` / `STORE_DEREF` / `COPY_FREE_VARS` | closures |
| `LOAD_COMMON_CONSTANT` | `assert` (exceptions T7) |
| `LOAD_SPECIAL` | `with` (exceptions T9) |
| `YIELD_VALUE` / `SEND` / … | generators |
| `FORMAT_WITH_SPEC` | format-spec f-strings |
| `STORE_SLICE` / `BUILD_SLICE` / slice step ≠ 1 | slice assignment / stepped slices |
| `MATCH_*` | `match` |

### Explicitly later / never in v1 hardware

| Item | Note |
| --- | --- |
| `SETUP_*` / `POP_BLOCK` | compiler pseudo-ops; not in `co_code` |
| `except*` (`CHECK_EG_MATCH`, …) | exceptions T11 |
| Async (`GET_AWAITABLE`, …) | out of scope with generators |
| Unmodified CPython `CACHE` in **firmware emit** | fetch skips CACHE; ROM compiler emits none |

## Policy for new opcodes

1. Prefer a same-algorithm rewrite in firmware (index loop vs slice) over
   a new FSM, unless the rewrite is the `append` → `+= [x]` class of
   bug-farm. That rule is locked in [`compile_plan.md`](compile_plan.md).
2. JSON `support` / `plan_track` and the human table land in the same PR
   as RTL.
3. Image tests use the shared simulator plusargs (`ensure_sim.py`).
