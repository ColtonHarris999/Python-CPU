# PyCore easy long-term optimizations

Post dead-code cleanup plan. Each item is intentionally small-to-medium, low-risk relative to a full microarchitecture rewrite, and valuable as the collection/excore surface grows.

---

## Opt-1 — Split the container FSM out of `pycore_core.sv`

**Today:** One ~5.6kLOC core with a giant `S_CONTAINER` / `unique case` covering list, dict, set, tuple, name/const, and trap pulses.

**Change:** Extract per-family FSMs (`CONT_LIST_*`, `CONT_DICT_*`, `CONT_SET_*`, name/const) into includes or submodules that share the existing dmem/RF pulse registers and trap one-shots.

**Why / result:** Faster review and Verilator compile of touched paths; fewer merge conflicts when adding MAP_ADD / iterators / slices; clearer ownership of which phases can fire which traps.

---

## Opt-2 — Parameterize scan/probe loops (contains + hash probe)

**Today:** Near-duplicate sequencing for `CONT_CONTAINS_LIST` / `CONT_CONTAINS_TUPLE`, and parallel dict/set probe loops (`CP_VAL`/`CP_TAG`/`CHK`).

**Change:** One parameterized “scan/probe” engine: base pointer, length, stride (32B elem vs 64B dict bucket / 32B set bucket), and equality helper (`rich_eq` vs tag+val).

**Why / result:** Less duplicated control; smaller core; one place to add early-exit / prefetch later; fewer bugs when extending CONTAINS to new containers.

---

## Opt-3 — Narrow `pycore_decode` to what the core samples

**Today:** Decode still emits `decoded_valid_o`, `push_stack_o`, `pop_stack_o`, `decoded_pc_o`; core ties them off and owns TOS via `id_tos_delta`.

**Change:** Drop unused outputs (or gate behind a `DEBUG` param). Keep alu/rs/rd/branch/call/return/container/mem_op/illegal.

**Why / result:** Removes open-net noise; documents real interface; slightly simpler decode and TB wiring.

---

## Opt-4 — Make regfile a pure addressed storage block

**Today:** `pycore_regfile` still has idle `push_stack_i`/`pop_stack_i` and related TOS ports that the core does not drive.

**Change:** Remove stack-management ports; keep read/write by index; TOS/locals base stay in the core (matches current comments/wiring).

**Why / result:** Deletes dead case logic; clearer ownership; less risk of accidental dual TOS sources if someone re-enables ports.

---

## Opt-5 — Default image tests on the two-core top

**Today:** Parallel `PYCORE_IMAGE_RUN` vs `_TWOCORE` Makefile macros; many single-core image tests never exercise marshal/resume.

**Change:** Prefer `pycore_excore_system` with `EXCORE_EN` as a parameter for image-boot tests; keep intentional single-core-only cases for fatal-path coverage.

**Why / result:** Catches mailbox/marshal regressions earlier; less Makefile duplication; matches production-shaped topology.

---

## Opt-6 — Finish migration off legacy `preprocess.py` sidecars

**Today:** `preprocess.py` is deprecated but still emits `.types` / `_cache.hex` (now uncommitted) and backs `run-file` / some container hex regeneration.

**Change:** Point remaining container hex regeneration and `run-file` at `image_from_source` / `run_image_test`; stop writing unused sidecars.

**Why / result:** One image toolchain; smaller `programs/` surface; less confusion about which fixtures are authoritative.

---

## Opt-7 — Emit generator fixtures under `build/`

**Today:** Several generators write checked-in hex under `pycore/programs/` (`list_append_*`, `extend_*`, `grow_*`, etc.).

**Change:** Emit under `build/` like `img_*`; commit sources/generators only (or keep a thin “golden” set if offline runs need it).

**Why / result:** Cleaner tree; CI always regenerates; fewer stale binary hex drifts.

---

## Opt-8 — Skip unnecessary LIST_EXTEND destination header read

**Today:** Extend always reads the destination header before deciding empty vs trap, even when the source is a distinct list/tuple and only `src_len` matters for the trap decision.

**Change:** For non-self list/tuple sources, decide empty/trap from the source header alone; keep the dst-header path for self-extend and any future in-place bookkeeping.

**Why / result:** Saves one dmem round-trip on the common “non-empty → LIST_EXTEND trap” path without changing semantics.

---

## Opt-9 — Shared hash/mask helper for dict and set probes

**Today:** Probe index is computed inline (`hash & (slot_count-1)`) in a few places; set and dict differ mainly by stride and value layout.

**Change:** Single helper/function for masked probe index + next-probe step (linear), used by both dict and set FSMs (and by Opt-2’s engine).

**Why / result:** One place to evolve open-addressing policy; less copy-paste when adding tombstone-aware resume after grow.

---

## Opt-10 — Documentation / target surface hygiene (ongoing)

**Today:** Root README and Makefile occasionally lag retired flows (const ROM, legacy TBs).

**Change:** Keep `bytecode_support.md` + architecture as the source of truth; Makefile `.PHONY` list and README examples track only live targets.

**Why / result:** Less agent/human thrash on dead entry points; faster onboarding.

---

## Suggested order

1. Opt-3 / Opt-4 (interface cleanup — mechanical, low risk)  
2. Opt-8 / Opt-9 (small RTL wins on hot container paths)  
3. Opt-6 / Opt-7 / Opt-10 (toolchain + tree hygiene)  
4. Opt-2 then Opt-1 (structural FSM work — highest payoff, more invasive)  
5. Opt-5 (Makefile/topology once two-core is the default expectation)
