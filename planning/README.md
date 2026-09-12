# Planning

Living plans for work that is **not done yet**. Current architecture and
opcode/type inventories live under `pycore/docs/` and `excore/docs/`.

| File | Role |
| --- | --- |
| [`master_plan.md`](master_plan.md) | Timeline and how the tracks connect |
| [`architecture_plan.md`](architecture_plan.md) | Remaining machine / memory / boot work |
| [`bytecode_support.md`](bytecode_support.md) | Remaining opcode work |
| [`builtin_support.md`](builtin_support.md) | Remaining ROM / native builtins |
| [`compile_plan.md`](compile_plan.md) | On-device `compile()` via PyCPython |
| [`exceptions_plan.md`](exceptions_plan.md) | Remaining exception tracks |
| [`memory_system_plan.md`](memory_system_plan.md) | L1I/L1D/L2/RAM, strings in dmem, descriptor caches |
| [`string_accelerator_plan.md`](string_accelerator_plan.md) | String Accelerator unit and the new STR object layout (P5) |
| [`memory_hierarchy_report.md`](memory_hierarchy_report.md) | Measurements the sizing in that plan rests on |

Historical plans (including the old Plan 1 tokenizer and Plan 2/3 compiler
splits) are in [`old/`](old/).

GitHub CI skips the hardware suite when a PR/push only touches markdown,
`planning/`, licenses, or similar non-build paths (including `pycore/docs/`
and `excore/docs/`). Mix in RTL, programs, tools, `Makefile`, Docker, or
workflow files and the split jobs run as usual.
