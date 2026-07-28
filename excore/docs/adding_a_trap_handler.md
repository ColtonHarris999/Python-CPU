# Adding a new excore trap handler

Checklist for a future recoverable trap (GC, unimplemented-opcode
emulation, iterator helpers, …), following the pattern established by
the live container handlers in `excore/fw/list_grow.s`:

1. **Assign a trap code.** Add `PY_TRAP_<NAME>` to `pycore_defs.svh`.
   As of this writing codes **9–15 are taken** (`LIST_GROW`,
   `LIST_EXTEND`, `DICT_GROW`, `LIST_DELETE`, `SET_GROW`, `SET_UPDATE`,
   `DICT_UPDATE`). The 4-bit trap-code space is **full**; a new recoverable
   trap needs a wider encoding or a retired code. `pycore_defs.svh` is
   the source of truth.

2. **Classify it.** Add it to `pycore_trap_recoverable()` in
   `pycore_defs.svh`. This is the single gate that decides whether
   `EXCORE_EN=1` intercepts the trap before it reaches `pycore_trap`.

3. **Preserve the early-trap discipline.** The container op (or whichever
   RTL detects the condition) must raise the trap **before any RF, heap,
   or dmem-write commit** — this is what makes `RETRY` a semantically
   valid response later, and is required regardless of whether this
   particular handler ever returns `RETRY`. Grep `pycore_core.sv` for
   `container_list_grow_trap_r` / `trap_marshal_pending_r` for the
   worked example.

4. **Marshal the operands.** In the detecting phase, under `if
   (EXCORE_EN && pycore_trap_recoverable(PY_TRAP_<NAME>))`, set
   `trap_marshal_pending_r <= 1`, `trap_marshal_code_r <=
   PY_TRAP_<NAME>`, `trap_marshal_entry_count_r`, and
   `trap_marshal_entries_r[i]` from whichever registers already hold the
   operands this trap needs — reuse the container RF-read pattern (the op
   already decoded what it needs for its own fast/normal path; don't add
   a new RF read port). Set `container_phase_r <= CP_DONE` in the same
   cycle so the existing `S_CONTAINER` exit logic redirects to
   `S_TRAP_MARSHAL`.

5. **Add the firmware dispatch case.** In `excore/fw/`, either extend
   `list_grow.s`'s `wait_trap` dispatch with a new `beq t0, <code>,
   handler_label` before the `j fatal_illegal` fallthrough, or write a new
   `.s` file with its own dispatch loop (point `EXCORE_FW_SRC` at it). Use
   the MMIO registers documented in `mmio_map.md`; the slot port bridges
   32-bit loads/stores to 128-bit pycore dmem slots.

6. **Decide `RES_CODE`.** `COMPLETED` if the firmware finished the
   semantic effect (preferred — see "the excore contract" in
   `architecture.md`); `RETRY` only if pycore state genuinely did not
   advance (true by construction if step 3 held) and the firmware could
   not finish the effect itself; `FATAL` with a `fatal_code` that mirrors
   a `PY_TRAP_*` value pycore understands (it is forwarded verbatim into
   `pycore_trap`).

7. **Test at both layers.** Unit-test the new firmware against a mocked
   mailbox (extend `tb_excore.sv` or add a new `excore/tb/` testbench,
   canned trap messages, a real `pycore_mem_bank`) *before* wiring it into
   pycore. Then add a pycore-side integration test
   (`gen_excore_integration_fixtures.py`-style generator or
   `img_*` image-boot program) exercising the real trap path end to end,
   plus an `EXCORE_EN=0` companion proving the trap remains fatal when
   the excore is disabled.

8. **Widen the message if needed.** If the new handler needs more than 3
   trap-side or 2 result-side entries, bump `MAX_TRAP_ENTRIES` /
   `MAX_RES_ENTRIES` — they're parameters on `pycore_core`, `trap_mailbox`,
   and `excore_mmio` alike, so this is a one-line change in each
   instantiation, not a protocol redesign. `pycore_core.sv`'s internal
   `trap_marshal_entries_r` / `trap_res_entries_r2` arrays are currently
   hardcoded to `[0:2]`/`[0:1]` (matching the current defaults) and would
   need resizing to match.
