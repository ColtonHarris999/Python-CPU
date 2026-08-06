# Builtins wave 4 — what comes next

**Audience:** next agent (firmware, bytecode, or excore)  
**Prerequisite:** wave 3 ROM seed landed (`planning/builtins_rom_wave3_plan.md`)  
**Current ROM set:** 21 `CODE_OBJECT` builtins in `ROM_FIRMWARE_BUILTINS`

Wave 3 finished the easy pure-Python seed + `sorted(reverse=)` /
`sum(start=)`. Remaining work needs **new hardware / excore / bytecode**,
not just more `.py` stubs.

---

## 1. Priority A — `print` console (testing win)

**Why first:** full-program tests can assert stdout instead of packing
everything into one INT return.

| Layer | Work |
| --- | --- |
| MMIO | Add write-only console sink (e.g. `CONSOLE_TX` byte / ring) on excore MMIO map; TB captures to a log file |
| Excore | Handle `PY_TRAP_BUILTIN_CALL` for `BI_PRINT`: stringify INT/BOOL/None/SHORT_STR, write bytes, `COMPLETED` + push `None` |
| Firmware | Optional ROM `CODE_OBJECT` wrapper with `sep=` / `end=` (CALL_KW) that calls into native print or builds one string then traps |
| Tests | `img_print_basic.py` + golden `.stdout`; extend `run_image_test` / Makefile to diff captured output |

**Out of scope for A:** full `str`/`repr` for containers; `file=` streams.

Plan detail can live in `pycore_firmware/builtins/print.md` once started.

---

## 2. Priority B — attribute protocol primitives (unblocks many builtins)

Firmware `hasattr` / `getattr` / `setattr` / `delattr` / `isinstance` /
`issubclass` / `vars` / `dir` / `type` are **not ROM-seedable** until these
LOAD_ATTR special cases exist:

| Name | Required LOAD_ATTR / TYPE behavior |
| --- | --- |
| `__dict__` | On `OBK_INSTANCE`, return field0 dict handle (do not probe key `"__dict__"`) |
| `__class__` | On `OBK_INSTANCE`, return `ob_type` as `OBK_TYPE` handle |
| `__base__` | On `OBK_TYPE`, return `tp_base` (field1) |

Also useful:

- `BI_TYPE` or CALL on `type` one-arg → tag/ob_type expose  
- Tuple-of-types `isinstance` once single-class works

**Acceptance:** seed attr helpers + `isinstance`/`issubclass` into ROM;
image tests with `SEED_INSTANCE` / `SEED_TYPE`.

---

## 3. Priority C — `BI_ORD` / `BI_CHR` (native, not custom opcodes)

| Id | Behavior |
| --- | --- |
| `BI_ORD` | One-char STR → INT code point (reuse STR FOR_ITER UTF-8 decode) |
| `BI_CHR` | INT → one-char SHORT_STR (UTF-8 encode, range checks) |

Seed `ord` / `chr` in builtins dict; then firmware `ascii` becomes feasible.
See existing `ord.md` / `chr.md`.

---

## 4. Priority D — bytecode / CALL follow-ups

| Item | Unlocks |
| --- | --- |
| `CO_VARARGS` / `CO_VARKEYWORDS` on defs | `zip(*args)`, `map(f, *iterables)`, `print(*args)` as Python |
| Exception tables / real exception objects | Replace fatal `raise` / TYPE traps with `TypeError`/`StopIteration` |
| `COMPARE_OP` string ordering | `sorted`/`min`/`max` on str |
| `GET_ITER` / `FOR_ITER` on OBJECT | User `__iter__` / `__next__` |
| `FORMAT_*` / `BUILD_STRING` | Richer `str`/`format`/`print` |
| `LOAD_SUPER_ATTR` + descriptors | `super`, `property`, `classmethod` |
| `TO_BOOL` OBJECT `__bool__`/`__len__` | Truthiness protocol completion |

---

## 5. Priority E — more ROM seeds (after B/C)

Once primitives land, seed without new invention:

- `hasattr`, `getattr`, `setattr`, `delattr`, `isinstance`, `issubclass`
- `ord`, `chr`, then `ascii`
- Optional ROM `max`/`min` kwargs wrappers **without** removing `BI_MAX`
  (document shadowing policy)

Still hybrid: keep `BI_LEN` / `BI_RANGE` / `BI_SET` / `BI_MAX` positional.

---

## 6. Explicitly deferred

- Host `compile` / string `eval`/`exec` (`compile.md`)
- Filesystem `open` / `input`
- Async (`aiter`/`anext`)
- `frozenset`, `memoryview`, `slice` objects, buffer protocol
- `locals` / `globals` / `id` / `hash` frame or probe exposure
- Custom non-CPython opcodes

---

## 7. Suggested owner split

| Track | Owner | First deliverable |
| --- | --- | --- |
| A print console | excore + TB | `BI_PRINT` writes bytes; one stdout golden test |
| B attr specials | pycore RTL (LOAD_ATTR) | `__dict__` / `__class__` / `__base__` |
| C ORD/CHR | pycore CALL FSM | `BI_ORD` / `BI_CHR` + image tests |
| D bytecode | bytecode agent | `CO_VARARGS` or str `COMPARE_OP` |
| E ROM seed | firmware agent | seed attr + ord/chr after B/C |

---

## 8. Success metric for wave 4

At least one of:

1. A program with `print(...)` checked via captured stdout in CI, **or**
2. `hasattr`/`getattr`/`isinstance` in ROM with green image tests, **or**
3. `ord`/`chr` native + ROM/tests.

Do not open a “seed everything remaining” PR without one of those
primitives.
