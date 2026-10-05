# GC independent reviews (G15)

## Review round at 10df31c66a728bbc75e93281d6d7e5c09474ab80 (2026-10-01T16:23:17+00:00)

Reviewer: a fresh general-purpose agent with no prior context (Claude Code
subagent; the Cursor `bugbot` subagent is not available in this harness),
given `git diff origin/main...10b2ba8` plus the uncommitted change set that
became this commit, with the plan's G15 instructions.
Reviewed tree: 10b2ba8 plus the change set (not yet a commit). This record
is appended at the commit that contains the fixes.

Correctness findings: 4 (all in code already at 10b2ba8)

1. Allocator run headers written at the old bump pointer could lie at or
   above `heap_zero_r` and survive into a "zeroed" run (phantom dict/set
   keys). Fixed: `heap_zero_r` follows allocator header writes; new G6
   invariant. Ledger B20; regression: `img_gc_memoryerror_caught` under
   G7 (a) fires the invariant without the fix.
2. `len(instance)` committed two RF writes before the binder reservation;
   an abort re-dispatched `__len__(x, x)`. Fixed: undo record
   `gc_undo_len_r`. Ledger B21; regression `img_gc_len_varkw`.
3. The `GC_CALL_BINDER_OOM` `[GC-INV]` branch was unreachable, so an
   under-reservation unwound a half-bound CALL. Fixed: any binder placement
   failure with GC on is a fatal. Ledger B22.
4. Idle premark of the builtins dict hid `int` and the exception types,
   whose type dicts are mutable. Fixed: extra roots at
   `PYCORE_GC_EXTRA_ROOTS`, traced once a type dict has been handed out
   (LOAD_ATTR `__dict__` on a type); immutable type dicts for programs that
   cannot reach them. Ledger B23; mutant 45; regression
   `img_gc_builtin_type_dict`.

Other findings and resolutions:
- G3 did not exercise keep-run / rover / cleanup skip: G3 now gives every
  other seed a kept tail window and a next-fit address, and the oracle
  checks the rover count (dumps carry `keep_lo/keep_hi/rover_addr/rover`).
  Cleanup skip stays covered by `img_gc_mutant_44` (G4).
- No oracle check that never-written memory is zero: the new G6 invariant
  covers the allocator-header path that produced finding 1.
- G13 P6a/P6b/P8 passed silently without inputs: now fail closed.
- G14 scans only default-config simulator logs: intended ("default runs
  print nothing new"); the other all-tests suites still gate on exit code.
- G10 threshold n >= 42 with 44 mutants: the runner requires all listed
  mutants killed; n >= 42 only rejects a list shorter than plan + 5 own.
- Makefile default `+GC_EN=1` reaches container/excore-system hex leaves
  only in G14: the default now applies to image macros only; container
  and excore-system suites pass at the default (44/44).
- Docs: gc.md P6b/P7 numbers, plan §4.5 stack size, on-chip storage
  deviation: fixed.

correctness findings: 4

## Review round at 10df31c66a728bbc75e93281d6d7e5c09474ab80 (2026-10-01T16:23:17+00:00)

Reviewer: a fresh general-purpose agent with no prior context (Claude
subagent), given the uncommitted change set on 10b2ba8 (diff HEAD, new files
included) and the round-1 record. Read-only; no simulation.

Correctness findings: 1 verified, 2 plausible (all fixed)

1. GC_CALL_OOM treated every CALL in a protocol method body as the
   container launch (no undo record): `Rec(..)` in `__next__` trapped 7 with
   garbage on the heap. Fixed: only the launch (depth below the protocol
   frame) is exempt. Ledger B25; mutant 47; `img_gc_protocol_body_call`.
2. (plausible, confirmed) cleanup descriptor / immutable type dicts decided
   from co_names only; exec'd source naming `_PYC_G` stored a list that was
   freed. Fixed in the image builder. Ledger B27; `img_gc_exec_pyc_g`.
3. (plausible, confirmed in sim) `_bi_heap_release` handed back unzeroed
   bytes; keep-run removed the accidental re-zeroing. Fixed with GC on (zero
   at the next boundary). Ledger B26; mutant 46; `img_gc_release_zero`.

Other: grant-churn fixture moved to G7 recipe_heap; spike macro appends the
GC image default.

correctness findings: 1

## Review round at 10df31c66a728bbc75e93281d6d7e5c09474ab80 (2026-10-01T16:23:17+00:00)

Reviewer: a fresh general-purpose agent with no prior context (Claude
subagent), given the change set after the round-2 fixes. Read-only.

Correctness findings: 3 verified (all fixed)

1. The release-zero pass wrote the allocator's stale header word, not
   zeros, after a MemoryError that skipped runs. Fixed (data cleared; G6
   invariant on phase-2 data). Ledger B28; mutant 48;
   `img_gc_release_zero_after_oom`.
2. B27 missed strings inside tuple constants. Fixed. Ledger B29;
   `img_gc_exec_pyc_g` now uses tuple constants.
3. `bios` (execs its payload) was not a run-time-source name. Fixed by
   deriving the list from the firmware builtins. Ledger B29.

Also fixed: 16-bit mark epoch widened to 32 bits; unaligned marks fault
with GC on; G10 requires every listed mutant killed. Documented open
hazard: run-time-assembled source spelling `_PYC_G` (master_plan.md).

correctness findings: 3

## Review round at 10df31c66a728bbc75e93281d6d7e5c09474ab80 (2026-10-01T16:23:17+00:00)

Reviewer: a fresh general-purpose agent with no prior context (Claude
subagent), given the change set after the round-3 fixes. Read-only.

Correctness findings: 1 verified (fixed)

1. STRACC wrote pieces past heap_ptr_r before a later piece answered
   NEED_HEAP; heap_zero_r never covered them and a later install handed
   them out unzeroed. Fixed: any non-collector core write into the dynamic
   heap raises heap_zero_r; G6 invariant. Ledger B30; mutant 49
   (`img_gc_stracc_split` fires the invariant).

Also: G10 runs a no-mutant baseline first; docstring exclusion keeps shared
constants that are loaded; G7 recipe heap for `img_gc_release_zero_after_oom`;
plan §6.1 epoch width.

correctness findings: 1

## Review round at 10df31c66a728bbc75e93281d6d7e5c09474ab80 (2026-10-01T16:23:17+00:00)

Reviewer: a fresh general-purpose agent with no prior context (Claude
subagent), given the change set after the round-4 fixes. Read-only.

Verified the B30 rule sees every core-side write (single dmem output mux),
the G6 invariant cannot false-fire, keep-run cannot hand out dirty bytes,
gc_model.py is unaffected, and excore firmware checks its limit before any
slot write at every NEED_HEAP site (list_grow.s).

Correctness findings: 0

Open (test-gap / nit, recorded in gc_progress.md): no invariant on the
excore slot port; mutant 49 is killed only by its own invariant; a FATAL
excore result adopts the result heap pointer before halting (pre-existing);
run-time-source derivation matches direct calls only.

correctness findings: 0

## Review round at 9041c0df8966346237090d960a54cfcdbefec5f7 (2026-10-02T18:43:34+00:00)

Reviewer: a fresh general-purpose agent with no prior context (Claude
subagent), given only the acceptance-speed delta (Makefile -O2 simulator
builds, loop-free bitmap masks in pycore_gc.sv, TEST_JOBS default). Read-only
on the repo; equivalence checked with a width-accurate Python model in its own
scratch directory (all d_mask/m_mask inputs; every sw_b x 8-bit sw_lim x
sw_free_r over edge and random words, plus 200k random cases); old and new
pycore_gc.sv lint to the same 301 Verilator warnings.

Correctness findings: 0

Notes (not correctness): TEST_JOBS ?= $(shell ...) is re-evaluated per use;
docker targets on a Mac may oversubscribe Docker Desktop's VM; a 4-state
simulator would propagate X differently through the new expressions
(Verilator is 2-state). Cloud evidence: quick G1 cycle-identical to G0,
G3/G4/G5/G6/G7 pass, G8 seeds 0-49 identical to the -Os host run.

correctness findings: 0

## Review round at e1256d9f2d3ef5457f4c1ff7b5c9cf93b694a2cc (2026-10-03T11:06:11+00:00)

Reviewer: a fresh general-purpose agent (Claude subagent), given only the
G9 delta (reservation-abort tagging for site statistics, new two-core
targets, img_gc_code_new_churn). Read-only; no simulation.

Correctness findings: 1 (G9 statistics, not architectural)

1. gc_res_abort_r was cleared only on gc_to_fetch, which excludes the
   S_GC_ALLOC -> S_FETCH re-dispatch exit, so a later phase-12 TYPE abort in
   the same re-dispatched CALL would be keyed callres.* (rows 29/30) instead
   of row 27. Fixed in round 8's delta.

Also: the gc_progress.md hunk would have replaced newer handoff text; the
handoff is now inserted rather than overwritten.

correctness findings: 1

## Review round at e1256d9f2d3ef5457f4c1ff7b5c9cf93b694a2cc (2026-10-03T11:06:11+00:00)

Reviewer: the round-7 agent, re-checking the fixed G9 delta. Read-only.

gc_res_abort_r is now cleared on both S_GC_ALLOC exits (phase-3 re-dispatch
and the MemoryError raise), after the testbench reads it at the gc_abort_r
rise; no RTL expression reads it. Row 29/30 crediting is faithful. Fixture
golden (280), recipe heap, two-core recipes and suite membership correct.

correctness findings: 0

## Review round at e1256d9f2d3ef5457f4c1ff7b5c9cf93b694a2cc (2026-10-03T11:06:11+00:00)

Reviewer: the same agent, given the full delta after the 7e410f3 run also
failed G13 (P1 on two release fixtures) and G14 (grant_churn budget at
CACHE_EN=0; make's echo of multi-line raw-hex recipes flagged as output).

Correctness findings: 1 (gate vs plan)

1. The first P1 exemption for release zeroing accepted any cycle difference
   when a mutant-46 rerun matched G0: unbounded, and not recorded under the
   plan's target-revision rule. Fixed in round 10's delta (bounded, recorded
   in gc_plan.md, gc_progress.md and gc.md).

The PLUSARG_ECHO output filter and the new cycle budgets are sound.

correctness findings: 1

## Review round at e1256d9f2d3ef5457f4c1ff7b5c9cf93b694a2cc (2026-10-03T11:06:11+00:00)

Reviewer: the same agent, on the final delta. Read-only.

P1 exemption now applies only when every diff is a cycles diff and the GC
time comes from release zeroing; it requires an exact G0 match with mutant 46
and bounds the mutator at G0 + max(0.5%, 64 per zeroed line). zero_lines
cannot be inflated on a no-collect fixture (run installs need a run list,
which only a collection creates). Round 11 then checked the added bound on
the zeroing pause itself (at most 16 cycles per line + 64): both fixtures pass
with margin, and the gate and the three documents agree.

Process note for the human: clause (2) of the plan's revision rule (implement
a further optimisation) is not met and is stated as such in the deviation row.

correctness findings: 0

## Review round at 0e603aab845104306af25c413d9a2e4f9880a3c2 (2026-10-03T19:11:21+00:00)

Reviewer: the round 7-11 agent (Claude subagent), on the acceptance-speed
delta after the user accepted the P1 revision: GC_POISON sweep writes whole
aligned 64 B lines as one line write when CACHE_EN=1, and larger cycle
budgets for img_gc_iter_short, img_gc_grant_churn (two-core) and
img_gc_code_new_churn. Read-only; no simulation.

Checked: the 6-bit alignment test; a line write stays inside
[base + 16, min(base + size, zero_base)) and never covers the free-run header;
dirty_hi follows the 64 B step; m_line_r cannot leak onto any other engine
request (spill, bitmap, stash, headers); the S_GC_ALLOC zero lines keep
wline = 0; the L1D non-zero full-line install path and the two-core
crossbar/hierarchy handle the write; CACHE_EN=0 and tb_gc are unchanged.

Cloud evidence: quick G1/G3-G8 pass; G8 seeds 0-49 single and 413-416
two-core give peak, heap, collections and dump counts identical to the
7e410f3 host run; both simulator builds add no warnings.

correctness findings: 0

## Review round at 481ed83ac9ca25f963c61b41b9c0353f9ddf3af5 (2026-10-04T09:49:07+00:00)

Reviewer: fresh Claude subagent, on the G9 row 29 fix after the 7273663
full run (G0-G8 pass; G9 failed: row 29 0 aborts on both tops). Read-only
review plus short single-target simulations.

Cause: since B18 the binder reserves the *args tuple and **kwargs dict
before binding; reservation aborts are keyed `callres.kw` (row 30) when the
callee has **kwargs, else `callres.args` (row 29). The only reservation
fixture (`img_gc_call_kw_varargs`) has **kw, so every abort went to row 30.

Fix: new fixture `img_gc_call_varargs` (*args-only callees, 400
iterations, 8 KB heap), single and two-core targets in `pycore-img-gc-sites`
(16M cycles). No gate tool, testbench, RTL, baseline or golden changed.

Checked: gc_call_binder_need only reserves for *args overflow or **kwargs,
neither callee has **kwargs, so every reservation abort is `callres.args`;
placements are `call14.20` (row 29); no other site aborts. Row 29 is "CALL
budget" in the plan (§3.5 as built), same treatment as row 30. G7 (b) K=487
passes with 50 collections and 50 aborts/re-dispatches; G7 (a)/(c) heap
about peak+8192 gives about 25 aborts/collects/re-dispatches per run, and
the 20480 B worst case still gives 10/10/10 per run, so each top gets >= 20
from (a)+(c). Host CPython and the simulation return 90200. Not in G0, G1 or
G13 baselines; two-core CACHE_EN=0 MEM_LATENCY=30 takes 5.04M of 16M.
Minor note: K is 487, not 317 as in the fix notes.

correctness findings: 0

