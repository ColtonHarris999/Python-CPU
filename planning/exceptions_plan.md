# Exceptions plan

Remaining exception work. The type inventory is
[`pycore/docs/exception_support.md`](../pycore/docs/exception_support.md)
and `pycore.json` → `exceptions.types`. Update both in the same PR that
seeds or relinks a type. Opcode rows stay in
[`pycore/docs/bytecode_support.md`](../pycore/docs/bytecode_support.md).

## On main

T1–T5-A (except T4 oparg 2) + T8: `except Exception:`, `raise TypeError` /
`raise TypeError("msg")`, MRO + tuple match, cross-frame unwind,
`try`/`except`/`else`/`finally`, `e.args`. Unhandled raise is still fatal
`PY_TRAP_RAISE` (17). Hardware type/mem traps are **not** yet Python
exceptions.

Firmware F1 (no `raise <int>`) and F4 (`e.args`) are done. F2/F3 remain
under [`builtin_support.md`](builtin_support.md).

Locks that still apply:

- Do not bake type names into `CHECK_EXC_MATCH`.
- Do not implement `SETUP_*` / `POP_BLOCK` (3.14 pseudo-ops).
- Protocol `StopIteration` stays identity vs `iter_exhaust_type_r`.
- Stay in the existing op’s FSM; one dmem beat; MRO depth 8.
- Recoverable excore traps stay mailbox completions, not Python
  exceptions, until a later design.

## Remaining tracks (order)

| Track | What | Next |
| --- | --- | --- |
| **T6** | Hardware trap → catchable Python exception (`TypeError`, `ZeroDivisionError`, `AttributeError`, then `IndexError` / `KeyError` / `NameError` / `UnboundLocalError`) | **Next language slice** after compile F1 if you are not on the compiler path |
| **T4 leftover** | `RAISE_VARARGS` oparg 2 (`raise e from cause`) | small |
| **T7** | `assert` / `LOAD_COMMON_CONSTANT` → `AssertionError` | needs T5-A (seeded) |
| **T9** | `with` / `LOAD_SPECIAL` `__enter__`/`__exit__` | after T8 (done) |
| **T10** | `class MyError(Exception)` | image folding currently rejects bases |
| **T5-B/C** | extra types (`OverflowError`, `ImportError`, `OSError` stub, `SystemExit`, …) | seed when a site needs the name |
| **T11** | `except*` / exception groups | later; single `tp_base` cannot express dual inherit |
| **T12** | generators / `GeneratorExit` | with `YIELD_*` |

Do not re-implement the exception table, exc-info stack, or `RAISE_VARARGS`
1 path.

## T6 sketch (when it lands)

Boot-sidecar **handles** of already-seeded types. Sites that today pulse
`PY_TRAP_TYPE` / `PY_TRAP_DIV_ZERO` / `PY_TRAP_ATTR_ERROR` (and later
index/key/name) construct an `OBK_EXCEPTION` and enter the table walk as
if `RAISE_VARARGS` 1 had run. Unhandled still ends in trap 17.

Do **not** convert recoverable mailbox traps (list grow, …) in T6.

## Firmware leftovers

See [`builtin_support.md`](builtin_support.md): `getattr` should raise
`AttributeError`; empty `min`/`max` should raise `ValueError`; NYI stubs
should `raise TypeError` instead of `1 % 0`. Compiler work does not wait
on these.

## Historical

Full track write-ups, CPython hierarchy copy, and RTL phase notes:

- [`old/exceptions_full_support_plan.md`](old/exceptions_full_support_plan.md)
- [`old/exceptions_firmware_followup_plan.md`](old/exceptions_firmware_followup_plan.md)
