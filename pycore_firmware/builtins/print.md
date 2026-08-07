# `print` — console output

**Status:** in ROM (MVP)  
**Plan:** `planning/builtins_print_console_plan.md`  
**Parent:** `planning/builtins_wave4_plan.md` §1

## Architecture

| Name | Kind | Role |
| --- | --- | --- |
| `print` | ROM `CODE_OBJECT` | `print(*args, sep=" ", end="\n")` — full `*args` / kwargs |
| `_bi_print` | `OBK_BUILTIN` / `BI_PRINT` | One-arg sink → `CONSOLE_TX` @ `0xF0` |

The ROM body never concatenates a full line (Phase 2 LONG_STR can stream
`for c in s: _bi_print(c)` without changing the public API).

## Supported tags (native sink)

INT / BOOL / None / SHORT_STR. LONG_STR and containers → `TYPE` fatal.

## Tests

`img_print_*.py` + `.stdout` goldens via `PYCORE_IMAGE_RUN_TWOCORE_STDOUT`.
