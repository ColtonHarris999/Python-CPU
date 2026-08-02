# Planning and historical notes

Documents here are **not** the source of truth for the current system
(except active product briefs awaiting implementation). Current
architecture and tag/layout docs live under `pycore/docs/` and
`excore/docs/`.

| File | Contents |
| --- | --- |
| `pycore_sim_debugger_ui_prompt.md` | **Ready for handoff:** interactive PyCore simulator/debugger UI — implement on branch `ui_simulation` |
| `builtins_bytecode_support_plan.md` | **Done (bytecode milestone):** LEGB-B, `BI_LEN` miss path, `TO_BOOL` widen, `RAISE_VARARGS`, `UNPACK_EX`, LIST_TO_TUPLE |
| `builtins_next_steps_plan.md` | **Active:** next work for the firmware builtins agent (ROM seed, positional freeze, raise sweep) |
| `call_kw_support_plan.md` | **Done (v1):** `CALL_KW` / `CALL_FUNCTION_EX` / `DICT_MERGE` on `CODE_OBJECT` |
| `dict_set_bulk_contam_plan.md` | **Done:** `MAP_ADD` / `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE` + contamination bit |
| `optimization_plan.md` | Optional RTL cleanup / optimization backlog |
| `dead_code_report.md` | Historical dead-code audit notes |
| `tag_layout_plan.md` | Historical tag-restructure plan (superseded by `pycore/docs/tags.md`) |
