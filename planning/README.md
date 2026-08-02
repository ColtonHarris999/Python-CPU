# Planning and historical notes

Documents here are **not** the source of truth for the current system
(except active product briefs awaiting implementation). Current
architecture and tag/layout docs live under `pycore/docs/` and
`excore/docs/`.

| File | Contents |
| --- | --- |
| `pycore_sim_debugger_ui_prompt.md` | **Active brief:** interactive PyCore simulator/debugger UI (assumes pending `bytecode_support` → `main` merge / PR #61) |
| `builtins_bytecode_support_plan.md` | **Done (bytecode milestone):** LEGB-B, `BI_LEN` miss path, `TO_BOOL` widen, `RAISE_VARARGS`, `UNPACK_EX`, LIST_TO_TUPLE |
| `builtins_next_steps_plan.md` | **Active:** next work for the firmware builtins agent (ROM seed, positional freeze, raise sweep) |
| `call_kw_support_plan.md` | Landing via `bytecode_support` / PR #61: `CALL_KW` / `CALL_FUNCTION_EX` / code-object kw fields |
| `optimization_plan.md` | Optional RTL cleanup / optimization backlog |
| `dead_code_report.md` | Historical dead-code audit notes |
| `tag_layout_plan.md` | Historical tag-restructure plan (superseded by `pycore/docs/tags.md`) |
