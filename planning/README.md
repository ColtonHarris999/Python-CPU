# Planning

Plans for work that is **not done yet**. The machine as built is documented
under `pycore/docs/`, `excore/docs/`, and `pycore_firmware/builtins/`.

| File | Role |
| --- | --- |
| [`master_plan.md`](master_plan.md) | The only living roadmap: what is left to build, by track, plus policies and memory-map locks |
| [`cleanup_report.md`](cleanup_report.md) | Simplification and dead-code backlog, written as independent work items for agents |
| [`old/`](old/) | Archived designs and plans. Code comments cite them by section (`compiler_design.md §6.1`), so they stay in the repo |

## Rules

- When a plan lands, move it to `old/`, add an `Archived` note at the top
  that points to the as-built doc, and copy anything still open into
  `master_plan.md`. Do not keep a "graduated" plan at the top level.
- Do not duplicate opcode, type, or builtin tables here. Link to
  `pycore/docs/bytecode_support.md`, `pycore/docs/exception_support.md`,
  `pycore/targets/pycore.json`, and `pycore_firmware/builtins/builtins.md`.
- When you finish a `cleanup_report.md` item, delete its entry in the same
  PR. The report should only ever list open work.

GitHub CI skips the hardware suite when a PR or push only touches markdown,
`planning/`, licenses, or similar non-build paths (including `pycore/docs/`
and `excore/docs/`). If you also touch RTL, programs, tools, the `Makefile`,
Docker, or workflow files, the split jobs run as usual.
