# Archived plans

These documents are **not** the source of truth. They are the design history
behind what is on `main`, kept so that code comments citing a section
(`compiler_design.md §6.1`, `memory_system_plan.md §6`, …) still resolve.

- **What the machine does today:** `pycore/docs/`, `excore/docs/`, and
  `pycore_firmware/builtins/builtins.md`.
- **What is left to build:** [`../master_plan.md`](../master_plan.md).
- **Cleanup work for agents:** [`../cleanup_report.md`](../cleanup_report.md).

Relative links in the older files may be one directory off from where they
were written. When a plan and a `pycore/docs/` page disagree, the docs page
is correct.

## Retired 2026-09-25 (built on `main`)

| File | Was | As-built |
| --- | --- | --- |
| `compiler_design.md` | On-device `compile()` design, steps T0–K, §11 follow-ups. Everything landed except O-2, the loader, and self-host | [`pycore/docs/compiler.md`](../../pycore/docs/compiler.md) |
| `compile_plan.md` | First `compile()` plan, superseded by `compiler_design.md` | same |
| `memory_system_plan.md` | L1I / L1D / L2 / RAM, STRACC, CODC, GIC (P0–P9) | [`pycore/docs/memory_hierarchy.md`](../../pycore/docs/memory_hierarchy.md) |
| `memory_hierarchy_report.md` | Sizing study behind the memory system; §7 has the P9 measurement | same |
| `string_accelerator_plan.md` | STRACC design | [`pycore/docs/string_accel.md`](../../pycore/docs/string_accel.md) |
| `p5_review_followup.md` | Post-merge review of STRACC. §1–§3 fixed; §4 and §5 moved to the cleanup report | — |
| `architecture_plan.md` | A1 code-RAM writers (landed), A2 loader, A3 BIOS (landed), A4 options | [`pycore/docs/code_loading.md`](../../pycore/docs/code_loading.md) |
| `bytecode_support.md` | Ordered list of opcode lifts | [`pycore/docs/bytecode_support.md`](../../pycore/docs/bytecode_support.md) |
| `builtin_support.md` | Remaining builtins (`compile` has since landed) | [`pycore_firmware/builtins/builtins.md`](../../pycore_firmware/builtins/builtins.md) |
| `exceptions_plan.md` | Exception tracks T4–T12 | [`pycore/docs/exception_support.md`](../../pycore/docs/exception_support.md) |

Anything still open from these files has been copied into
[`../master_plan.md`](../master_plan.md).

## Older history

| File | Was |
| --- | --- |
| `code_loading_bios_tokenizer_plan.md` | Plan 1 (code RAM / BIOS / PyPy tokenizer). Code RAM and `exec`/`eval` shipped; the P9 tokenizer was **dropped** |
| `native_compiler_plan.md` | Plan 2 (parser → self-host) |
| `native_compiler_full_plan.md` | Plan 3 (PyCPython integration) |
| `compile_fast_path.md` | First-`compile()` sequencing |
| `bytecode_compile_progress.md` | Measured vendor opcode mix. Regenerate with `pycore/tools/measure_pycpython_opcodes.py` |
| `exceptions_full_support_plan.md` | Full exception tracks, CPython hierarchy copy, RTL phase notes |
| `exceptions_firmware_followup_plan.md` | Firmware F1–F4 (F1 and F4 shipped) |
| `builtins_wave4_plan.md` | Builtins wave 4 |
| `optimization_plan.md` | Optional RTL cleanup. Superseded by the RTL section of [`../cleanup_report.md`](../cleanup_report.md) |
| `implemented/` | Shipped plans: CALL_KW, for-loops, bulk dict/set, print, tag layout, … |
