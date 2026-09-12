# Builtin support plan

Remaining names in the boot builtins dict and ROM. The inventory is
[`pycore_firmware/builtins/builtins.md`](../pycore_firmware/builtins/builtins.md).
Per-name stubs (`compile.md`, `open.md`, `super.md`, …) keep the deep
blockers.

Architecture: hardware `OBK_BUILTIN` / `BI_*` fast paths for known tags;
Python bodies are miss / protocol paths only.

## Shipped

Native: `len`, `range`, `ord`, `chr`, `int`, `str`, 2-arg `max` (`BI_MAX`),
and the print sink (`_bi_print` / `CONSOLE_TX`).

In ROM: `print(*args, sep=, end=)`, `min`/`sorted`/`sum` (kwargs wrappers),
`map`/`zip`/`enumerate`/`filter`/`reversed` (**return lists**),
`list`/`dict`/`tuple`/`set`, `abs`/`all`/`any`, `bin`/`hex`/`oct`,
`hasattr`/`getattr`/`isinstance`/`delattr`, `exec`/`eval` on **code
objects** (including `globals=`). `isinstance(s, str)` works: `LOAD_ATTR`
`__class__` on `SHORT_STR`/`LONG_STR` returns the seeded `str` type.

Native methods via `LOAD_ATTR`: `list.append/pop/extend/clear`,
`set.add/update`, `str.join/startswith/endswith/find`,
`dict.get/keys/items/values/update/pop`.

Firmware `raise TypeError` / `ValueError` / `StopIteration` is catchable
(F1). `e.args` is readable (F4).

## Remaining

### Blocks on-device `compile()` — see compile plan

| Name | Status | Next |
| --- | --- | --- |
| `compile` | stub (`1 % 0`) | ROM wrapper over `pycore_firmware/compiler/` + F1 emit |
| string `eval` / `exec` | code-object form works | after `compile`; keep `eval(compile(s,…))` for v1 |

Do not wait for BIOS, `open`, or a module loader.

### Firmware leftovers (exceptions F2 / F3)

| Item | Today | Target |
| --- | --- | --- |
| `getattr` missing name | returns default / `None` | raise `AttributeError` when no default |
| empty `min` / `max` iterable | returns `None` | raise `ValueError` |
| NYI stubs (`compile.py`, …) | `return 1 % 0` | `raise TypeError` once callers stop relying on trap 3 |

`hasattr` must stay non-raising. Instance-dict-only probes are a
completeness gap, not an exceptions leftover.

### Bytecode that looks like a builtin

| Need | Plan |
| --- | --- |
| `super()` | `LOAD_SUPER_ATTR` — [`bytecode_support.md`](bytecode_support.md) |
| `OBJECT` truthiness | `TO_BOOL` protocol — same |
| `assert` | exceptions T7 |
| `property` / `classmethod` / `staticmethod` | still blocked; no descriptor protocol |

### Print / I/O phase 2

MVP `print` is in ROM. Still open: LONG_STR on the sink, container
`__str__`, `file=`. No stdin / `input` / `open` until there is a device.

### Leave blocked

Async (`aiter`/`anext`), files, `breakpoint`, `hash` as a Python builtin,
`memoryview`, `compile(..., flags≠0)`, `"single"` mode, `locals=` on
`exec`/`eval`.

## ROM seed rule

Do not seed CPython’s full builtins dict. Boot dict size and 128 B per
`OBK_TYPE` share the bump heap under `PYCORE_HEAP_LIMIT`. New ROM bodies
must pass `validate_code_tree` and the compiler subset in
[`compile_plan.md`](compile_plan.md) if they will later be compiled on
device.
