# Planning and historical notes

Documents here are **not** the source of truth for the current system
(except active product briefs awaiting implementation). Current
architecture and tag/layout docs live under `pycore/docs/` and
`excore/docs/`.

| File | Contents |
| --- | --- |
| `pycore_sim_debugger_ui_prompt.md` | **Ready for handoff:** interactive PyCore simulator/debugger UI — implement on branch `ui_simulation` |
| `builtins_bytecode_support_plan.md` | **Done (bytecode milestone):** LEGB-B, `BI_LEN` miss path, `TO_BOOL` widen, `RAISE_VARARGS`, `UNPACK_EX`, LIST_TO_TUPLE |
| `builtins_next_steps_plan.md` | **Done through §4.5 (wave 3);** next is wave 4 |
| `builtins_rom_wave3_plan.md` | **Done:** wave 3 ROM seed + `sorted(reverse=)` / tests |
| `builtins_wave4_plan.md` | **Active:** ORD/CHR + bytecode; §1 print + §2 attr specials **done** |
| `compile_exec_plan.md` | **Superseded index:** phase 0 (`s[i]`, `ord`, `chr`) shipped; the rest split into the two plans below |
| `code_loading_bios_tokenizer_plan.md` | **Proposed (Plan 1):** ROM + relocatable code RAM, module format + loader, Python **BIOS** boot, `exec`/`eval` on precompiled code objects, per-frame globals, slicing / str+list methods / string interning, exceptions with messages, heap+code marks, on-device **tokenizer** |
| `native_compiler_plan.md` | **Proposed (Plan 2):** parser, AST, symbol table, codegen, assembler, `CODE_OBJECT` fabrication, `compile()` + string `exec`/`eval`, on-device source store, **self-hosting bootstrap** |
| `builtins_print_console_plan.md` | **Done:** ROM `print` + `_bi_print` / `CONSOLE_TX` + stdout goldens |
| `call_kw_support_plan.md` | **Done (v1):** `CALL_KW` / `CALL_FUNCTION_EX` / `DICT_MERGE` on `CODE_OBJECT` |
| `for_loop_full_support_plan.md` | **Done (PR #66):** GET_ITER/FOR_ITER on OBJECT + StopIteration exception tables + comprehensions |
| `exceptions_full_support_plan.md` | **Active:** T1–T5-A (except T4 oparg 2) + T8 on `cursor/exceptions-full-t1-match` / PR #74. Type tracker: `pycore/docs/exception_support.md` + `pycore.json` `exceptions.types` |
| `exceptions_firmware_followup_plan.md` | **F1 done:** firmware `raise <int>` uses real types; F2/F3 firmware semantics and F4 `e.args` remain queued |
| `dict_set_bulk_contam_plan.md` | **Done:** `MAP_ADD` / `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE` + contamination bit |
| `optimization_plan.md` | Optional RTL cleanup / optimization backlog |
| `dead_code_report.md` | Historical dead-code audit notes |
| `tag_layout_plan.md` | Historical tag-restructure plan (superseded by `pycore/docs/tags.md`) |
