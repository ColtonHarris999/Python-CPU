# Planning and historical notes

Documents here are **not** the source of truth for the current system.
Current architecture and tag/layout docs live under `pycore/docs/` and
`excore/docs/`.

Implemented / superseded plans live under [`implemented/`](implemented/).

## Active / open

| File | Contents |
| --- | --- |
| `builtins_wave4_plan.md` | §1–§3 **done**; §4: string COMPARE_OP + FORMAT/BUILD MVP **done**; `LOAD_SUPER_ATTR` / `TO_BOOL` OBJECT remain |
| `code_loading_bios_tokenizer_plan.md` | **In progress (Plan 1):** ROM + relocatable code RAM, BIOS, `exec`/`eval` on precompiled code objects, tokenizer |
| `native_compiler_plan.md` | **Proposed (Plan 2):** parser, AST, codegen, assembler, self-hosting bootstrap |
| `exceptions_full_support_plan.md` | **Active:** T1–T5-A (except T4 oparg 2) + T8 landed; T6 / T7 / T9 / T10 remain. Tracker: `pycore/docs/exception_support.md` |
| `exceptions_firmware_followup_plan.md` | **F1 done;** F2/F3 firmware semantics and F4 `e.args` remain queued |
| `optimization_plan.md` | Optional RTL cleanup / optimization backlog |

## Implemented / historical (`implemented/`)

| File | Contents |
| --- | --- |
| `builtins_bytecode_support_plan.md` | **Done:** LEGB-B, `BI_LEN` miss path, `TO_BOOL` widen, `RAISE_VARARGS`, `UNPACK_EX`, LIST_TO_TUPLE |
| `builtins_next_steps_plan.md` | **Done:** post-CALL_KW builtins agent steps through wave 4 print/attrs |
| `builtins_rom_wave3_plan.md` | **Done:** wave 3 ROM seed + `sorted(reverse=)` / tests |
| `builtins_print_console_plan.md` | **Done:** ROM `print` + `_bi_print` / `CONSOLE_TX` + stdout goldens |
| `call_kw_support_plan.md` | **Done (v1):** `CALL_KW` / `CALL_FUNCTION_EX` / `DICT_MERGE` on `CODE_OBJECT` |
| `co_varkeywords_call_parity.md` | **Done:** `CO_VARKEYWORDS` + positional-only CALL parity |
| `for_loop_full_support_plan.md` | **Done (PR #66):** GET_ITER/FOR_ITER on OBJECT + StopIteration exception tables + comprehensions |
| `HANDOFF.md` | For-loop full support handoff / design locks |
| `dict_set_bulk_contam_plan.md` | **Done:** `MAP_ADD` / `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE` + contamination bit |
| `compile_exec_plan.md` | **Superseded index:** phase 0 shipped; rest split into Plan 1 / Plan 2 |
| `dead_code_report.md` | Historical dead-code audit notes |
| `tag_layout_plan.md` | Historical tag-restructure plan (superseded by `pycore/docs/tags.md`) |
