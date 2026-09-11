# Historical plans

These documents are **not** the source of truth. They were the working
plans before the `planning/` tree was collapsed to six living files
([`../master_plan.md`](../master_plan.md)).

Kept for provenance and for RTL notes that have not been recopied.

## Superseded compiler / tokenizer

The live compile plan is [`../compile_plan.md`](../compile_plan.md).
PyCPython (`vendor/pycpython`) replaced the PyPy tokenizer path.

| File | Was |
| --- | --- |
| `code_loading_bios_tokenizer_plan.md` | Plan 1 (code RAM / BIOS / PyPy tokenizer). Code RAM and `exec`/`eval` shipped; P9 tokenizer **dropped**. |
| `native_compiler_plan.md` | Plan 2 (parser → self-host) |
| `native_compiler_full_plan.md` | Plan 3 (PyCPython integration, still useful background) |
| `compile_fast_path.md` | First-`compile()` sequencing (folded into the live compile plan) |
| `bytecode_compile_progress.md` | Measured vendor opcode mix; regenerate with `measure_pycpython_opcodes.py` |
| `implemented/compile_exec_plan.md` | Original compile/exec index |

## Other historical

| File | Was |
| --- | --- |
| `exceptions_full_support_plan.md` | Full exception tracks; live remainder is [`../exceptions_plan.md`](../exceptions_plan.md) |
| `exceptions_firmware_followup_plan.md` | F1–F4; F1/F4 shipped |
| `builtins_wave4_plan.md` | Wave 4; remainder in [`../builtin_support.md`](../builtin_support.md) |
| `optimization_plan.md` | Optional RTL cleanup |
| `implemented/` | Shipped CALL_KW, for-loops, bulk dict/set, print, tag layout, … |

Relative links inside these files may be one directory deeper than when
they were written; prefer the living docs under `pycore/docs/`.
