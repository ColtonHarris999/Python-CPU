# Planning and historical notes

Documents here are **not** the source of truth for the current system.
Current architecture and tag/layout docs live under `pycore/docs/` and
`excore/docs/`.

| File | Contents |
| --- | --- |
| `builtins_bytecode_support_plan.md` | **Done (bytecode milestone):** LEGB-B, `BI_LEN` miss path, `TO_BOOL` widen, `RAISE_VARARGS`, `UNPACK_EX`, LIST_TO_TUPLE |
| `builtins_next_steps_plan.md` | **Done through §4.4;** §4.5 points at wave 3 |
| `builtins_rom_wave3_plan.md` | **Active:** next ROM seed wave (3A ready pure-Python, 3B kwargs, 3C polish) |
| `call_kw_support_plan.md` | **Done (v1):** `CALL_KW` / `CALL_FUNCTION_EX` / `DICT_MERGE` on `CODE_OBJECT` |
| `dict_set_bulk_contam_plan.md` | **Done:** `MAP_ADD` / `DICT_UPDATE` / `DICT_MERGE` / `SET_UPDATE` + contamination bit |
| `optimization_plan.md` | Optional RTL cleanup / optimization backlog |
| `dead_code_report.md` | Historical dead-code audit notes |
| `tag_layout_plan.md` | Historical tag-restructure plan (superseded by `pycore/docs/tags.md`) |
