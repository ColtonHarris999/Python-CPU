# PyCore Exception Support Lists (CPython 3.14)

This file classifies **built-in exception types** the same way
`bytecode_support.md` classifies opcodes. Update it in the same PR that
seeds, relinks, constructs, or trap-maps a type.

**Machine source of truth:** `pycore/targets/pycore.json` → `exceptions.types`.
This document is the human table and the notes. Do not claim a type is seeded
unless the JSON `status` is `seeded` and boot (`build_builtins_dict`) agrees.

**Hierarchy source of truth:**
[Built-in Exceptions](https://docs.python.org/3/library/exceptions.html)
(Python 3.14). Copy `tp_base` from that page; do not invent parents.

**Roadmap:** [`planning/exceptions_full_support_plan.md`](../../planning/exceptions_full_support_plan.md).
Opcode rows live in [`bytecode_support.md`](bytecode_support.md) and the
`OBJ_EXC` group in `pycore.json`.

## How to read status

| JSON `status` | Meaning |
| --- | --- |
| `seeded` | `OBK_TYPE` in the boot builtins dict |
| `absent` | not in boot dict; `LOAD_GLOBAL` misses |
| `alias` | name should bind to `alias_of`'s handle when that type is seeded |
| `skip` | explicitly not planned (unused / warnings until something emits them) |

Sibling fields (independent of `status`):

| Field | Values | Meaning |
| --- | --- | --- |
| `tp_base` | name or `null` | **documented** parent (what hardware must store once seeded) |
| `tp_base_actual` | name or `null` | parent currently stored on the live `OBK_TYPE` |
| `seed_track` | `landed-B` / `T1` / `T5-A` / … | which plan track **inserts** the type |
| `uses_tracks` | list | tracks that **consume** the type after it exists |
| `match` | `none` / `identity` / `mro` | what `CHECK_EXC_MATCH` can do for this type |
| `construct` | `none` / `raise-type` / `call` | `raise T` vs `raise T(...)` / `raise e` |
| `trap_map` | trap names | Track 6 sites that become this exception |

`landed-B` means for-loop PR #66 Track B (leaf `StopIteration` only).

## Inventory (from `pycore.json`)

Counts are derived from `exceptions.types`. Recompute after every seed PR:

| `status` | Count | Types |
| --- | --- | --- |
| `seeded` | 16 | Wave A (`BaseException` … `AssertionError`, including `StopIteration`) plus `SyntaxError` |
| `absent` | 39 | Wave B–C + groups + OSError children |
| `alias` | 3 | `EnvironmentError`, `IOError`, `WindowsError` → `OSError` |
| `skip` | 14 | warnings family + `FloatingPointError` + `_IncompleteInputError` |

Today Wave A is **seeded** with documented `tp_base` links and `match = mro`.
`RAISE_VARARGS` 1 still treats TOS as a type (`construct = raise-type`).
`CALL TypeError("x")` still allocates `OBK_INSTANCE` (Track 2). FOR_ITER
exhaustion still uses handle **identity** vs `iter_exhaust_type_r`, not MRO.

## Tracker

`Exception | Status | Track | Blocked by | Note` — drop into the plan without
re-deriving. **Track** is `seed_track`. **Blocked by** is the track that must
land before this type is useful (often matching / construction, not the seed
itself).

### Seeded today (Wave A / Track 1)

| Exception | Status | Track | Blocked by | Note |
| --- | --- | --- | --- | --- |
| `BaseException` | seeded | T1 | — | root; `tp_base_actual=null`; bare `except:` is already this without a matcher |
| `Exception` | seeded | T1 | — | `tp_base_actual=BaseException`; `except Exception:` catches Wave A leaves |
| `StopIteration` | seeded | landed-B / T1 relink | — | `tp_base_actual=Exception`; FOR_ITER exhaust still identity vs `iter_exhaust_type_r` |
| `ArithmeticError` | seeded | T5-A | — | parent of `ZeroDivisionError` / later `OverflowError` |
| `ZeroDivisionError` | seeded | T5-A | T6 | trap map not converted yet |
| `LookupError` | seeded | T5-A | — | parent of `IndexError` / `KeyError` |
| `IndexError` | seeded | T5-A | T6 | trap map not converted yet |
| `KeyError` | seeded | T5-A | T6 | trap map not converted yet |
| `NameError` | seeded | T5-A | T6 | trap map not converted yet |
| `UnboundLocalError` | seeded | T5-A | T6 | trap map not converted yet |
| `TypeError` | seeded | T5-A | T2 / T6 | raise-type only; CALL still INSTANCE |
| `ValueError` | seeded | T5-A | T2 | raise-type only |
| `AttributeError` | seeded | T5-A | T6 | trap map not converted yet |
| `RuntimeError` | seeded | T5-A | T4 | Track 4 bare `raise` with no active exception |
| `AssertionError` | seeded | T5-A | T7 | `LOAD_COMMON_CONSTANT` still trap |
| `SyntaxError` | seeded | T1 rebase | — | Plan 1 P7 leaf pulled under `Exception`; `IndentationError`/`TabError` stay absent |

T1 shipped MRO + tuple `CHECK_EXC_MATCH` in the same PR as Wave A seeds. Rebase onto `main` also seeds `SyntaxError`.

### Track 5 Wave B — remaining `Exception` children PyCore can raise

| Exception | Status | Track | Blocked by | Note |
| --- | --- | --- | --- | --- |
| `OverflowError` | absent | T5-B | T5-A `ArithmeticError` | under `ArithmeticError` |
| `MemoryError` | absent | T5-B | T1 `Exception` | heap OOM only after site split from `MEM_FAULT` |
| `ImportError` | absent | T5-B | T1 `Exception` | |
| `ModuleNotFoundError` | absent | T5-B | T5-B `ImportError` | |
| `NotImplementedError` | absent | T5-B | T5-A `RuntimeError` | |
| `RecursionError` | absent | T5-B | T5-A `RuntimeError` | |
| `PythonFinalizationError` | absent | T5-B | T5-A `RuntimeError` | low; seed with the RuntimeError family if cheap |
| `OSError` | absent | T5-B | T1 `Exception` | stub only; no errno→subclass constructor |
| `EnvironmentError` | alias | T5-B | T5-B `OSError` | alias of `OSError` |
| `IOError` | alias | T5-B | T5-B `OSError` | alias of `OSError` |
| `WindowsError` | alias | T5-B | T5-B `OSError` | alias of `OSError` |
| `BlockingIOError` | absent | T5-B | — | do **not** seed; errno subclasses stay off Wave B |
| `ChildProcessError` | absent | T5-B | — | do not seed |
| `ConnectionError` | absent | T5-B | — | do not seed |
| `BrokenPipeError` | absent | T5-B | — | do not seed |
| `ConnectionAbortedError` | absent | T5-B | — | do not seed |
| `ConnectionRefusedError` | absent | T5-B | — | do not seed |
| `ConnectionResetError` | absent | T5-B | — | do not seed |
| `FileExistsError` | absent | T5-B | — | do not seed |
| `FileNotFoundError` | absent | T5-B | — | do not seed |
| `InterruptedError` | absent | T5-B | — | do not seed |
| `IsADirectoryError` | absent | T5-B | — | do not seed |
| `NotADirectoryError` | absent | T5-B | — | do not seed |
| `PermissionError` | absent | T5-B | — | do not seed |
| `ProcessLookupError` | absent | T5-B | — | do not seed |
| `TimeoutError` | absent | T5-B | — | do not seed |
| `BufferError` | absent | T5-B | T1 `Exception` | seed only if something raises it |
| `EOFError` | absent | T5-B | T1 `Exception` | seed only if something raises it |
| `ReferenceError` | absent | T5-B | T1 `Exception` | seed only if something raises it |
| `SystemError` | absent | T5-B | T1 `Exception` | seed only if something raises it |

### Track 5 Wave C / Track 11 / Track 12 — language features

| Exception | Status | Track | Blocked by | Note |
| --- | --- | --- | --- | --- |
| `SystemExit` | absent | T5-C | T1 `BaseException` | **not** under `Exception` |
| `KeyboardInterrupt` | absent | T5-C | T1 `BaseException` | **not** under `Exception` |
| `GeneratorExit` | absent | T12 | T1 `BaseException` | **not** under `Exception`; generator plan |
| `StopAsyncIteration` | absent | T12 | T1 `Exception` | async iterators; generator/async plan |
| `BaseExceptionGroup` | absent | T11 | T1 `BaseException` | sibling of `Exception`; `except Exception` must **not** catch it |
| `ExceptionGroup` | absent | T11 | T1 `Exception` | v1 `tp_base=Exception` only (single-inheritance ceiling) |
| `SyntaxError` | seeded | T1 rebase | T1 `Exception` | Plan 1 P7 exact-match tests required the name; parented to `Exception` on rebase |
| `IndentationError` | absent | T5-C | T5-C `SyntaxError` | |
| `TabError` | absent | T5-C | T5-C `IndentationError` | |
| `UnicodeError` | absent | T5-C | T5-A `ValueError` | codecs |
| `UnicodeDecodeError` | absent | T5-C | T5-C `UnicodeError` | |
| `UnicodeEncodeError` | absent | T5-C | T5-C `UnicodeError` | |
| `UnicodeTranslateError` | absent | T5-C | T5-C `UnicodeError` | |

### Skip

| Exception | Status | Track | Blocked by | Note |
| --- | --- | --- | --- | --- |
| `FloatingPointError` | skip | skip | — | docs: not currently used |
| `_IncompleteInputError` | skip | skip | — | CPython 3.13+ REPL incomplete-input (`SyntaxError` subclass); not on the public exceptions.html tree |
| `Warning` | skip | skip | — | seed the family only if something emits warnings |
| `UserWarning` | skip | skip | — | |
| `DeprecationWarning` | skip | skip | — | |
| `PendingDeprecationWarning` | skip | skip | — | |
| `SyntaxWarning` | skip | skip | — | |
| `RuntimeWarning` | skip | skip | — | |
| `FutureWarning` | skip | skip | — | |
| `ImportWarning` | skip | skip | — | |
| `UnicodeWarning` | skip | skip | — | |
| `BytesWarning` | skip | skip | — | |
| `ResourceWarning` | skip | skip | — | |
| `EncodingWarning` | skip | skip | — | |

## Tracks that do not seed types

These tracks **use** types from the tables above. They do not add new builtin
names (Track 10 adds **user** types).

| Track | Types it needs | What it does with them |
| --- | --- | --- |
| T2 Construction | any seeded exception type (tests: `StopIteration`, `TypeError`) | `CALL` with exception `ob_flags` → `OBK_EXCEPTION`; `RAISE` type vs instance |
| T3 Cross-frame unwind | none new | preserves the already-built object across `S_RETURN` |
| T4 `RAISE_VARARGS` 0/2 | `RuntimeError` (T5-A) for bare `raise` with no active exc | oparg 0 re-raise; oparg 2 optional `raise from` |
| T6 Trap→raise | `TypeError`, `AttributeError`, `ZeroDivisionError`; later `IndexError` / `KeyError` / `NameError` / `UnboundLocalError` | boot-sidecar handles; enter `CONT_RAISE` next cycle |
| T7 `assert` | `AssertionError` (T5-A) | `LOAD_COMMON_CONSTANT` 0 is a register write of that handle |
| T8 try/finally/else/as | whatever the test raises | tests only; no new types |
| T9 `with` | whatever `__exit__` sees | no new builtin types |
| T10 user subclasses | Wave A bases (`Exception` and seeded children) | host copies `tp_base` **and** the exception bit onto `MyError` |

## Update checklist (every exception PR)

1. Change `pycore.json` `exceptions.types.<Name>` (`status`, `tp_base_actual`, `match`, `construct`, `trap_map`).
2. Edit the matching row in this file.
3. If an opcode’s ceiling moved (MRO match, `RAISE` oparg, `CALL` exception types), update `bytecode_support.md` **and** the opcode row in `pycore.json`.
4. Grep `object_model.md` boot-builtins paragraph if `StopIteration` / parents changed.
