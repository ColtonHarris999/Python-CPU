# Planning

Living plans for work that is **not done yet**. Current architecture lives
under `pycore/docs/` and `excore/docs/`. Shipped plans are in
[`implemented/`](implemented/).

Try a program against the shipped subset: `make help` / `make lint-file` /
`make run-file` (see the root `README.md`).

## Active

| File | Status |
| --- | --- |
| `code_loading_bios_tokenizer_plan.md` | **Plan 1, in progress.** Shipped: P1 (code RAM), P3 (`exec`/`eval` on code objects), P4 (per-frame globals), P6.1 (string slice), P6.3.2 (native methods), P7 (exception types + `e.args`), P8 (mark/release). Open: P2 loader, P5 BIOS, P6.2/P6.3.1 (list/tuple slice, interning), P9 tokenizer. |
| `native_compiler_plan.md` | **Plan 2, proposed.** On-device parser / AST / codegen / `compile()`. Depends on Plan 1. Related in-review: PRs #85 (PyCPython inventory) and #87 (fast-path `compile()`). |
| `exceptions_full_support_plan.md` | **Active.** On `main`: T1–T5-A (except T4 oparg 2) + T8. Remaining: T6 trap→raise, T7 `assert`, T9 `with`, T10 user subclasses, T5-B/C extra types, T11 `except*`, T12 generators. Tracker: `pycore/docs/exception_support.md`. |
| `exceptions_firmware_followup_plan.md` | **F1 + F4 done** on `main`. F2 (firmware that still avoids raising) and F3 (NYI stubs) remain. |
| `builtins_wave4_plan.md` | **§1–§3 done** (print, attr specials, `ord`/`chr`). Remaining: `LOAD_SUPER_ATTR` / `TO_BOOL` on OBJECT. |
| `optimization_plan.md` | Optional RTL cleanup backlog. Not a feature gate. |

## Implemented / historical (`implemented/`)

| File | Contents |
| --- | --- |
| `builtins_bytecode_support_plan.md` | **Done:** LEGB-B, `BI_LEN` miss path, `TO_BOOL` widen, `RAISE_VARARGS`, `UNPACK_EX`, LIST_TO_TUPLE |
| `builtins_next_steps_plan.md` | **Done:** post-CALL_KW builtins steps through wave 4 print/attrs |
| `builtins_rom_wave3_plan.md` | **Done:** wave 3 ROM seed + `sorted(reverse=)` |
| `builtins_print_console_plan.md` | **Done:** ROM `print` + `_bi_print` / `CONSOLE_TX` |
| `call_kw_support_plan.md` | **Done:** `CALL_KW` / `CALL_FUNCTION_EX` / `DICT_MERGE` |
| `co_varkeywords_call_parity.md` | **Done:** `CO_VARKEYWORDS` + positional-only CALL parity |
| `for_loop_full_support_plan.md` | **Done (PR #66):** GET_ITER/FOR_ITER on OBJECT + StopIteration tables + comprehensions |
| `HANDOFF.md` | For-loop design locks (historical) |
| `dict_set_bulk_contam_plan.md` | **Done:** `MAP_ADD` / `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE` + contamination bit |
| `compile_exec_plan.md` | **Superseded:** phase 0 shipped; rest split into Plan 1 / Plan 2 |
| `dead_code_report.md` | Historical dead-code audit |
| `tag_layout_plan.md` | Historical tag-restructure plan (see `pycore/docs/tags.md`) |
