# Architecture plan

Remaining machine work. The current system is specified in
[`pycore/docs/architecture.md`](../pycore/docs/architecture.md),
[`pycore/docs/tags.md`](../pycore/docs/tags.md),
[`pycore/docs/memory_hierarchy.md`](../pycore/docs/memory_hierarchy.md),
and [`pycore/docs/code_loading.md`](../pycore/docs/code_loading.md).

This file is only what is **not** built yet.

## Current split (do not relitigate)

| Piece | Owner today |
| --- | --- |
| Bytecode fetch / ALU / CALL / containers (in-capacity) | pycore |
| List/dict/set grow, non-empty extend, mid-list delete, set update | excore firmware |
| Fatal type / mem / illegal | `pycore_trap` halt |
| Code ROM (boot image) + code RAM (empty at runtime) | pycore I-bus |
| Bump heap + mark/release | pycore |

Excore never writes instruction memory. Every code writer must be on-core.

## Next architecture slices

### A1 — Code RAM writers (blocks compile)

Shipped: two banks, fetch mux, `code_ram_ptr_r`, mark/release, test-only
`$readmemh` preload.

Missing: runtime writes. Fetch still hard-wires `imem_we_o = 0`.

| Builtin | Job |
| --- | --- |
| `_bi_code_alloc(nslots) → INT` | bump-reserve RAM slots |
| `_bi_code_blit(base, words) → INT` | bulk-write a `list[int]` of packed words |
| `_bi_code_patch(slot, word)` | single-slot overwrite (jump backpatch) |
| `_bi_code_new(fields) → CODE_OBJECT` | 9-element list → 8-field heap object |

Host stand-ins in `image_from_source.py` so the firmware compiler can be
developed off-device. Sequence and tests: [`compiler_design.md`](compiler_design.md)
step C. The RF ring window (step B) lands first.

Do **not** invent a module-image loader just to emit one function.

### A2 — Module loader (after first compile)

A relocatable module image (text + data + reloc table) copied into code
RAM. Needed when the firmware compiler no longer fits in ROM, or when a
BIOS loads a payload. Geometry is already recorded in
[`code_loading.md`](../pycore/docs/code_loading.md) §4 — implement that,
do not redesign the banks.

### A3 — BIOS (after A2, or in parallel once A1 is green)

A Python program in ROM that is always the first thing the hart runs:
initialize, then `exec` a payload. Test programs today skip this and
enter `managed_entry` from the image. Keep skipping it until `compile()`
returns a real code object.

### A4 — Optional, pull only if a compile/OS slice hurts

| Item | When |
| --- | --- |
| `_bi_intern(s)` | compiler names exceed 15 bytes and SHORT_STR policy fails |
| List/tuple `BINARY_SLICE` | `copy_range` helper is a size/perf problem (see compile subset) |
| Negative indices in hardware | rewrite with `len-1` is no longer honest |
| GC / sweeping heap | after mark/release is insufficient for compiling large sources |
| RTL FSM split / decode cleanup | [`old/optimization_plan.md`](old/optimization_plan.md) — not a feature gate |

## Memory map locks

Do not move these without updating `encoding.py`, RTL params,
`memory_hierarchy.md`, and `code_loading.md` together. Post-P5 map:

- Code ROM slots `0x0000..0x1FFF`, code RAM `0x2000..0xA1FF`.
- Heap bump `0x440`–`PYCORE_HEAP_LIMIT` (`0xF0000`); exc-info arena
  `0xF0000–0xF0FFF`; native-method table `0xF0DE0`; frames
  `0xF1000–0xF8FFF`.
- `CONSOLE_TX` at `0xF0`.

The L1I/L1D/L2/RAM hierarchy, STRACC, CODC, and GIC are **built**. FTB is
skipped. See [`memory_hierarchy.md`](../pycore/docs/memory_hierarchy.md).
Dead `STRING_HEX` plusarg plumbing is a leftover, not a map move:
[`p5_review_followup.md`](p5_review_followup.md) §4.

## Out of scope here

Opcode ceilings → [`bytecode_support.md`](bytecode_support.md).
ROM names → [`builtin_support.md`](builtin_support.md).
Exception trap mapping → [`exceptions_plan.md`](exceptions_plan.md).
