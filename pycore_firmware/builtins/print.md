# `print` — deep plan pointer

Full implementation plan (MMIO, excore handler, tests, phases):

→ **`planning/builtins_print_console_plan.md`**

Parent wave: `planning/builtins_wave4_plan.md` §1.

Stub body: `print.py` (not ROM-seeded until Phase 2 kwargs wrapper).
Native path today: builtins dict → `OBK_BUILTIN` / `BI_PRINT` →
`PY_TRAP_BUILTIN_CALL` (needs excore handler + console MMIO).
