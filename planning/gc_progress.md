# GC implementation progress

Status: IN PROGRESS            <!-- IN PROGRESS | DONE | BLOCKED -->

## Active handoff — 2026-10-04 (G9 row 29)

- `MODE=full` at `7273663` (8 jobs, poison line writes): G0-G8 and
  G10-G16 pass (G8 1000 seeds per top, 0 failing; G10 49/49; G12 latency
  sweep at `CACHE_EN=0 MEM_LATENCY=30` green; G14 all-tests green). G9
  failed on row 29 (`*args` tuple) with 0 aborts on both tops. Since the
  reservation tag, binder reservation aborts are keyed `callres.kw` when
  the callee has `**kwargs`, else `callres.args` (row 29); the only
  reservation fixture (`img_gc_call_kw_varargs`) has `**kw`, so all its
  aborts went to row 30. No RTL bug: coverage gap.
- New fixture `img_gc_call_varargs` (`*args`-only callees, 400 iterations,
  8 KB heap), single and two-core targets in `pycore-img-gc-sites`
  (16M cycles). Cloud: `callres.args` 25 aborts/collects/re-dispatches per
  run at about peak+8 KB with `GC_EVERY_N_RUNS=1` (12 at 16 KB, 10 at the
  20 KB worst case), both tops; G7 (b) K=487 passes (50 boundary
  collections); `CACHE_EN=0 MEM_LATENCY=30` 5.04M cycles; host CPython and
  the simulation return 90200. Review round 13: 0 findings.
- Next: commit, record round 13, start `MODE=full` again.

## Active handoff — 2026-10-03 (G9 after the speed-up run)

- `MODE=full` at `7e410f3` (8 jobs, -O2): G0-G8 pass (G8 1000 seeds per
  top, 0 failing). G9 failed on 7 rows:
  - Row 30 (`**kwargs` leftover dict) 0 aborts on both tops. Since B18 the
    binder reservation aborts for that dict before the binder runs, so the
    abort was credited to `call25.32` (row 29) or `call25.0` (row 27). The
    core now flags reservation aborts (`gc_res_abort_r`, `gc_res_abort_kw_r`,
    testbench statistics only) and the testbench keys them `callres.kw`
    (row 30) or `callres.args` (row 29). `img_gc_call_kw_varargs`: row 30
    11 aborts/collects/re-dispatches per run on each top.
  - Two-core rows 12, 20, 21, 28, 31 had 7-8 collects: keep-run and next-fit
    (P8) cut collections, and those rows were only covered by single-core
    fixtures. New two-core targets for `img_gc_iter_short`,
    `img_gc_steady_closure`, `img_gc_call_churn`, `img_gc_exc_churn`, and a
    new `img_gc_code_new_churn` (fill to a margin before each `_bi_code_new`,
    39 aborts per run, G7 recipe heap) on both tops. Emulated G7 (a) on two
    core: rows 12/20/21/28 get 11/23/18/12-28 collects per mode.
- Rest of that run: G10 pass (49/49 killed, no-mutant baseline passes), G11
  pass, G12 pass, G15/G16 pass. G13 failed P1 on two release fixtures (B26
  zeroing; revised P1, plan deviations). G14 failed: `img_gc_grant_churn`
  two-core needs 38.7M cycles at `CACHE_EN=0` (budget 30M -> 150M;
  `img_gc_code_new_churn` 40M), and the per-leaf output scan flagged make's
  echo of four multi-line raw-hex recipes (`+PLUSARG=... \` lines; now
  skipped). 0 new warnings.
- Reviews: round 7 found the reservation tag surviving a re-dispatch (fixed:
  cleared on `S_GC_ALLOC` exit and on the MemoryError raise); round 9 found
  the first P1 exemption unbounded and unrecorded (now bounded and recorded
  here, in the plan and in gc.md); round 10 checks the final delta.
- Before the next run (user accepted the P1 revision): `GC_POISON` sweeps
  now write whole aligned 64 B lines as one line write when `CACHE_EN=1`
  (G8 seed 413 measure run 50.1M -> 41.4M cycles, same collections; quick
  G8 50 seeds 2463 s -> 1997 s, every seed's peak/heap/collections/dumps
  identical to the host run). All-tests budgets checked against the
  `7e410f3` G12 latency logs: `img_gc_iter_short` needs 23.2M at
  `CACHE_EN=0 MEM_LATENCY=30` (budget 16M -> 64M, both tops);
  `img_gc_grant_churn` two-core 146.5M there (150M -> 600M). All-tests had
  not reached its latency sweep in any earlier full run. Tried and dropped:
  Verilator `-fno-inline-funcs` (unsupported with the testbench's impure
  tasks), `-fno-inline-funcs-eager` (about 5%), `-O3`.
- Next: commit, record the review, start `MODE=full` again.

## Active handoff — 2026-10-02 (acceptance speed)

- The `MODE=full` run at `a51f529` (started 20:00 UTC 10-01, `TEST_JOBS=2`)
  passed G0-G7 and G8 single-core (1000 seeds, 0 failing) and was stopped by
  the user at 16:48 UTC 10-02, 338 seeds into G8 two-core, to make the gates
  faster. Nothing failed.
- Where the time goes: simulation. The oracle check is ~0.01 s per dump and
  an image build ~0.4 s; a G8 seed is two 50-60M-cycle simulator runs.
  Verilator profile (`--prof-cfuncs`): core sequential block 23%, STRACC
  sequential block 14%, three 128-step comb loops in `pycore_gc.sv` 16%.
- Changes (no gate, seed count or check changed):
  - Simulators build with `-MAKEFLAGS OPT_FAST=-O2` (Verilator's default is
    `-Os`): 3.4x on a 4M-cycle G8 measure run (56 s -> 16.6 s), identical
    results, cycles and GC logs on 7 fixtures.
  - `pycore_gc.sv`: the bitmap range masks and the sweep's first-bit search
    are shift/mask expressions instead of 128-iteration loops (host-checked
    equivalent on 200k random cases): another 1.13x, identical GC logs.
  - `TEST_JOBS` defaults to the online CPU count (`getconf
    _NPROCESSORS_ONLN`); the Python runners default to `os.cpu_count()`.
    CI still passes `TEST_JOBS=2`.
- Cloud check (2 cores): quick G1 117 s (was 361 s; cycle-identical to G0),
  G3 44 s, G4 48 s, G7 44 s (was 208 s); G8 quick seeds 0-49 compared with
  the host's `a51f529` results (peak, heap, collections, dumps).
- Next: commit, then `make pycore-gc-acceptance MODE=full` (8 jobs on the
  4P+4E host).

## Active handoff — 2026-10-01 (second session)

- The `MODE=full` run at `10b2ba8` exited at 11:19 UTC 10-01: G0-G6, G8,
  G11 pass; G7, G9, G10, G12-G16 fail. Causes, all addressed in the next
  commit:
  - G7: B19 (compiler passes run directly) and `img_gc_fragmented_alloc`
    recipe heap.
  - G9: two-core rows 14/15/17 under 10. New `img_gc_grant_churn`
    (recipe-heap list in G7): per run, rows 14/15/17 collect 60/21-30/40-57.
  - G10: mutant 28 survived. New `img_gc_mutant_28` (`_bi_heap_free()`
    drops by the skipped runs).
  - G12: `img_gc_mutant_{8,27,34}` hit their 8M budget at CE=0 LAT=30
    (14.7M-21.4M cycles); budgets are 40M now.
  - G13: P6b 0.286 and P8 1.39 at `10b2ba8`; this tree 0.240 and 0.011.
  - G14: Verilator warnings fixed; the two all-tests failures were
    two-core recipes without `+GC_EN=1` (the image default fixes them);
    recipes no longer pass `+GC_LOG`/`+GC_SITE_STATS`/`+GC_TRACE_DEC`
    (the gates add them), so default runs print nothing new (45 GC leaves
    checked).
  - G15: review round 1 recorded at the commit; round 2 (on the uncommitted
    tree) found B25-B27, fixed with fixtures and mutants 46-47.
  - G16: gc.md Status, README, planning/README Graduated, all-tests, CI.
- B24 (found tuning `img_gc_grant_churn`): a MemoryError left
  `gc_collected_r` set, so the next allocation miss raised without
  collecting.
- Committed as `10df31c` (all of the above plus B24-B30, mutants 46-49).
  Review rounds 1-5 are recorded in `planning/gc_reviews.md`; round 5 (on
  the committed tree) reported 0 correctness findings. Its open test-gaps:
  no invariant on the excore slot port, mutant 49 killed only by its own
  invariant, FATAL excore results adopt the result heap pointer before
  halting (pre-existing).
- Cloud checks on the committed tree (2 cores, Verilator 5.046, Python
  3.14.0rc2): `--mode quick --only G1,G3,G4,G5,G6,G7` 6/6 pass (G1
  cycle-identical; G7 (a) 52 fixtures); both simulator builds add no
  warnings beyond G0; 579 Python tests pass; the 45 GC leaves in the
  default all-tests suites print no new output. Mutants 28 and 38-49 were
  each checked against their killing fixture; `tools/gc_mutants.py` has
  not run them (G10 in the full run will).
- The desktop VM has no Verilator; simulation ran in the cloud copy.
- Next: `make pycore-gc-acceptance MODE=full` on the host at this HEAD.
- Do not edit the stop hook, `.cursor/gc_task_active`, or `status.json`.

Branch: gc/implementation
Current phase: 5               <!-- R, 0, 1, 2, 3, 4, 5, 6 -->
Last acceptance run: MODE=full --only G8 was interrupted after several hours
without observable process/log progress. G0-G7 passed earlier today at
c09384c; status.json was overwritten by the G8-only start and is not a
full-run record. Rerun G8 from the promoted Phase 4/5 checkpoint.

## Handoff (overwrite every session)
- Done: Phases R, 0, 1 RTL. Phase 2 directed fixtures (§6.4) all pass on the
  single-core top. G7-G13 gates wired. MODE=quick G0-G8 green at 08f911b
  (`status.json` head=08f911b dirty=false; G8 50/50 seeds, coverage
  complete). G1 cycle-identical after `fold_ltt` became gc_fuzz-only
  (1317ea4); unconditional fold had changed img_list_to_tuple twocore
  3735→1524.
- Done: B9 proto_iter clear (`img_gc_root_heap_iter`). B9b stale
  `saved_rs2` (`img_gc_stale_saved_rs2`); seed 11 measure PASSES.
- Done: B10. G8 seeds 13/16/34/48 CALL_FILTER (code=6). CALL_KW pops
  the names tuple at phase 16; a later binder/instance phase overwrites
  that RF slot with the kw INT. Unwind only did `tos++`, so re-dispatch
  read INT 43 at tos-1. Plan §3.5 says re-push the names tuple:
  `CALL_PHASE_GC_UNWIND` writes `TUPLE/call_kw_names_r` back to
  `entry_tos-1` (after the BM NULL undo, one write per cycle).
  `gc_call_entry_tos_r` is latched at S_WB. Seed 13 measure PASSES
  (0xb60, 9649022 cycles). Fixture `img_gc_fuzz_13` is in
  `pycore-img-gc-all`.
- Done: G8 coverage. Mapper (cdf48f2) rows 29–31. Fold (66274c6)
  LIST_TO_TUPLE. Prelude (1317ea4) SET_UPDATE TUPLE / DICT_UPDATE /
  DICT_MERGE (EXCORE_EN=0 takes the pycore bulk path) and a live
  exception on non-compile seeds (OBK6). Compile seeds raise only at
  the end (B11).
- Done: G10 at 1b36de3. 36/37 killed, mutant 33 pending Phase 3.
  `make pycore-gc-mutants TEST_JOBS=6` printed
  `G10 mutants=37 killed=36 survived=[] pending=[33]`.
- Done: G11 single-core plateau (cf577f7). TB pads `reason=   alloc`;
  the gate regex now accepts it. list/dict/set/str/exc/closure/compile
  all ≥10 collections, live spread ≤1 KB, free does not fall >1 KB.
  Status pending-phase-3 until two-core and compile-loop exist.
- Done: MODE=quick G0-G8 green at e926484 (`status.json` head=e926484
  dirty=false; G8 50/50 seeds, coverage complete). G7 (b) K=1 failures
  from f326e22 fixed in 5c0fd14.
- Next: MODE=full at e22417e finished. G0-G6 pass; G7/G8/G9/G11
  pending-phase-3 (G8 1000/1000 single-core, G9 single-core ≥10). G12
  `iter-short` CE=0 LAT=30 now PASSES with +GC_AT_EXIT=1 (23.5 M cycles).
  Full cache/latency sweeps not re-run. G13 P4 passes (sweep 2172).
  P5 now passes: max_pause 399009 ≤ 400000 (mark 396350, sweep 2172).
  Line consume of PLAIN pairs, dict slots, list/set headers; T_POP
  issues the first tuple line; T_LINE_W goes to T_POP when empty.
  Dumps exact. P6b/P8 open. G14-G16 not started.
- Done: Phase 3 grant protocol. `MB_HEAP_LIMIT` @0x1C,
  firmware `lw` + `res_need_heap`, PyCore `TRAP_RES_NEED_HEAP` →
  collect + re-dispatch. `GC_EN=0` converts NEED_HEAP to MEM_FAULT.
  `img_gc_excore_need_heap` (LIST_APPEND): need_heap=1, value=3.
  `img_gc_growth_paths`: need_heap=1, value=18. Mutant 33
  `[GC-INV] RES_HEAP_PTR > heap_limit`. `TWO_CORE_RECLAIMS=True`.
  Sweep updates `largest` on omitted <64 B pads (G7 live_exceeds_heap).
  `make excore-cpu-test` PASS (scenario 4/12 NEED_HEAP).
  Mutant 33 killed by G4
  (`python3.14 tools/gc_mutants.py --only 33 --jobs 4`, 159s,
  `killed=1 survived=[] pending=[]`). The prior commits hid the
  `li HEAP_LIMIT` → `lw MB_HEAP_LIMIT` timing change by rewriting 17 G0
  goldens. Those immutable rows are restored. `MB_HEAP_LIMIT` reads retain
  the old two-word-`li` latency and NEED_HEAP responses retain the old
  OOM-to-FATAL latency. MODE=full --only G1 passes all 1,615 leaves and all
  five auxiliary suites. G2-G6 passed on the post-commit sweep. G7
  passed all three modes over 502 fixtures (exact dumps). Full G8
  (`--mode full --only G8`, 1000 single-core seeds) is still running;
  do not touch main-tree RTL, the image builder, or sim_img until it
  exits. Do not flip `GC_EN` default until G1-G12 pass on both tops.
- Committed at `3238cbc`: Phase 4 compiler-cleanup descriptor.
  `img_gc_compile_loop` passes 64 compiles / 10 collections with live back to
  0 and P6a=1.963%; SyntaxError passes 32 iterations. Phase 5 MemoryError
  singleton caught/live-exceeds-heap/fragmented-alloc/recover fixtures pass on
  both tops. Cache-disabled compiler loops pass, and 121 focused Python tests
  pass. The source-identical archive remains at `/tmp/pycpu-phase4.vJ20e6`.
- Done: G10 8/27/34/36 killed by G4 on the quick subset
  (`python3.14 tools/gc_mutants.py --only 8,27,34,36 --jobs 6`,
  `killed=4 survived=[]`). `box.pop("m")(5)` after fill collects with
  `cur_closure_r` as the only FUNCTION-closure root (stash mismatch).
  64 B keep/drop holes + leftover < 64 B + a runtime `(keep, 1)` traps
  7 unless slack is ignored. Eight kwargs with leftover in [1600, 1664)
  traps 7 unless the budget is 96 B short. Mutant 36 also skips the
  empty-list MEM_FAULT (the guard-only mutant was a no-op: both paths
  trapped 7); live-chain HEAP_DYN=8192 then hangs.
- Open RTL bugs (workaround in the generator; fixture not yet in the suite):
  GET_ITER on a list allocated before a caught exception TYPE-traps
  (`img_gc_exc_then_iter.py`). BI_LEN on tuple-mode RANGE TYPE-traps.
  Compile-built CELL/FUNCTION plus a live exception later $fatals
  `[GC-INV] bad_kind` (G8 seed 2 collection 260;
  `img_gc_compile_then_exc.py`).
- Debug aids: `+GC_TRACE`, `+GC_TRACE_MEM`, `+GC_TRACE_OBJS`, `+GC_TRACE_DEC`,
  `+GC_LOG=1`, `+GC_SITE_STATS=1`;
  `python3.14 pycore/tools/gc_model.py --check <dump dir>`.
- Fixture notes: `img_gc_bench_full` n=280 (~502 KB live); CPython list
  displays of constants are LIST_EXTEND (fatal on EXCORE_EN=0) so shared
  strings are a tuple. `img_gc_steady_closure` collects every 80 iterations.

## Phases
| Phase | Status | Exit gates | Evidence (commit, run) |
| --- | --- | --- | --- |
| R | done | doc section, every §2.5 row decided | 6d5906d (+ citations from paper notes) |
| 0 | done | G0-G4 (verify-only) | G0 63f2228; G2/G3 c14bcc6; G4 verify-only 0e1a9dd; G4 full 782 dumps, G5, G6 (Phase 1 exit run below) |
| 1 | done | G1-G6, mutants 1-30 | MODE=quick G0-G8 at 1e657e1; G10 mutants 1-30 all killed (see Mutants) |
| 2 | in progress | G4-G11, G12 single, G13 P1-P5 | P4/P5 measured locally (sweep 2172, max_pause 399009); MODE=full pending |
| 3 | in progress | G1-G12 both tops | Full G1 on working tree based on 6620d7f: 1,615/1,615 plus five aux suites pass; other gates pending |
| 4 | not started | G11 compile rows, G13 P6a | |
| 5 | not started | G4-G11 both tops | |
| 6 | not started | G13 all, G14-G16 | |

## Decisions (Phase R and later)
| Item | Decision | Measurement | Commit |
| --- | --- | --- | --- |
| Static image tracing | Static prune map: the image builder marks every static object whose static subgraph holds no runtime-mutable object (list, set, dict other than a code object's `co_kwdefaults`, cell); the engine preloads the map into the bitmap (`P_PRELOAD`, one read per static bitmap word, dyn_base word masked). Type dicts stay traced: `C.__dict__` hands them to Python. The oracle judges the free set against the unpruned trace. | `img_gc_zero_on_reuse`, CE1/LAT4, one collection with no dynamic live data: pause 81,104 cycles (was ≈190k), 55 objects (was 765), 3,522 mark transactions; ≈3,300 of them scan the hash tables of the large mutable static dicts (one line miss per 64 B slot). | this commit |
| Remaining static cost | Keep; revisit only if P5/P6 miss. Option recorded: a store barrier setting a card bit per static 64 B line, so a clean mutable static container is traversed through a builder-precomputed child list instead of its table. | as above | — |

## Bugs
| ID | Found by (gate, seed, mutant, review) | Regression fixture | Fix commit |
| --- | --- | --- | --- |
| B1 | Phase 0 design check: dict/set tables rely on never-written (zero) memory; a reused run would show stale keys | `img_gc_reuse_after_collect` | 194eb01 (zero at run pop) |
| B2 | G4 `gcall` CE0/LAT4 in the Phase 1 exit run: `img_gc_verify_containers` returned 0x2b7be (expected 0x2b7c0); all dumps exact, so the data, not the graph, was wrong. With `CACHE_EN=0` the L1D forwards only 16 B words (`pycore_mem_hier.sv` leaves `down_line_o` open), so each zeroing "line" write cleared 16 of 64 bytes; a set table reused from a dropped set kept stale keys. Fix: `S_GC_ALLOC` issues line writes only when the cache is enabled. | `img_gc_zero_on_reuse` (fails at CE0 before the fix: 0x6d16c6 vs 0x6e6dbe) | this commit |
| B3 | G8 seed 0: `len()` on a tuple-mode RANGE (stop outside signed 32-bit) TYPE-traps. `pycore_call_fsm.svh` BI_LEN marks this a follow-up milestone. Generator keeps the RANGE1 object as a root but never lens or iterates it. | — (generator; `img_builtin_len_range` covers inline RANGE) | this commit |
| B4 | G8 seed 0: GET_ITER on a list allocated before a caught exception TYPE-traps (`GC_EN=0`). A list built after the handler iterates correctly. Generator emits try/except only after all iteration. | `img_gc_exc_then_iter.py` (not yet in `pycore-img-gc-all`) | open |
| B5 | G8: after a collect, `S_GC_ALLOC` first-fit can install a hole as the current run. The next CALL skips binder reservation (`GC_CALL_FAST_BYTES`) or reserves against that hole; the binder alloc then `$fatal`s `[GC-INV]`. Binder OOM now retries via `GC_CALL_OOM` when the current run is short. | seed 0 measure (pc 2052 / 235) | this commit |
| B6 | G8 seed 3: `str.replace("-", "+-")` dropped the haystack char that landed on a 16-byte dest-word boundary (`consume_unit` flushed and discarded the unit; FSM still advanced). Host/device checksum differed by 133 (`GC_EN=0`). | `img_gc_str_replace_expand` (0xabf vs 0xaef before the fix) | 037e9ce |
| B7 | G8 seeds 0/4: later EVERY_N_RUNS=1 collections reported objects RTL=oracle+5. Extra T_POPs were always the five prune-map bits in bitmap word 0 (TUPLE@0x440/0x480/0x4c0, DICT@0x520, CODE@0x700). Skip-clear PRELOAD issued while an aborted allocation's dmem beat was still outstanding and wrote that rdata into word 0. `S_GC_ENTER` drains the port; skip-clear and mutant 25 stay. | `img_gc_preload_stale` | this commit |
| B8 | G7 `img_gc_stracc_split` at 2.5×+EVERY_N_RUNS=1: trap 7 after two collects at pc 162 with largest still 35728. The §3.3 loop guard treated every second same-pc collect as OOM, including EVERY_N grants of a multi-allocation `split`. Guard now requires `largest < need+64`. `S_GC_ALLOC` also pushes too-small pops and the abandoned remainder onto `run_skipped_head_r` (§4.4). | `img_gc_stracc_split` (G7 plusargs) | e8d90e8 |
| B9 | G8 seed 11 / `img_gc_fuzz_11` collection 399 `[GC-INV] bad_kind=1`. T_HDR_W K_OBJ at a zeroed instance. `container_proto_iter_r` still held the HEAP_ITER from `for p in Counter(2): break` and was scanned on the next protocol CALL. Directed `img_gc_root_heap_iter` fails at collection 8 before the fix. | `img_gc_root_heap_iter` | this commit |
| B10 | G8 seeds 13/16/34/48 CALL_FILTER. CALL_KW phase 16 pops names; a later CALL phase overwrites RF[names]. Unwind only incremented TOS. Re-dispatch saw INT 43. | `img_gc_fuzz_13` (0xb60 after the names write-back; CALL_FILTER before) | c313c46 |
| B11 | G8 seed 2: live exception + compile-built CELL/FUNCTION, collection 260 `[GC-INV] bad_kind=1`. Generator keeps compile seeds exception-free until the checksum raise. | `img_gc_compile_then_exc.py` (not yet in `pycore-img-gc-all`) | open |
| B12 | G7 (a) `img_gc_code_new`: 8× `compile("1")` at 2.5× peak + EVERY_N=1 traps 7. Compile scratch stays reachable (Phase 4). Directed target only; not in `pycore-img-gc-all`. | `img_gc_code_new` | this commit |
| B13 | G7 (b) `img_for_iter_str_empty`: empty SHORT_STR GET_ITER writes ITER STR addr=0; marker treated it as LONG_STR → wild_ptr. | `img_for_iter_str_empty` | 5c0fd14 |
| B14 | G7 (b) `img_heap_release_below_base_trap`: INT 0 has epoch 0; after K=1 collect, epoch mismatch made `_bi_heap_release(0)` a superseded no-op instead of trap 7. | `img_heap_release_below_base_trap` | 5c0fd14 |
| B15 | G7 (b) `img_for_iter_object_nested` collection 60 wild_ptr: `container_call_result_r` was rooted while `active`, so a swept previous `__iter__` list was traced. Root it on `return_valid`. | `img_for_iter_object_nested` | 5c0fd14 |
| B16 | G7 (b) `img_compile_repeat`: mark subtraction across epochs returned 0x3200001440. Fixture now returns 1 after eight compiles; G0 cycles updated. | `img_compile_repeat` | 5c0fd14 |
| B17 | Phase 3 G1 audit: 17 immutable G0 cycle rows had been rewritten after `li HEAP_LIMIT` became `lw MB_HEAP_LIMIT`, hiding a 4-cycle change per grant check; the two legacy OOM leaves were still 4 cycles fast. Restore the G0 rows, match the old read latency only at `MB_HEAP_LIMIT`, and hold NEED_HEAP non-pending for four cycles before presenting the response. | Full G1 (all cache/latency rows, including `pycore-excore-{grow,extend}-oom-fatal`) | this commit |
| B18 | G7 (b) `img_compile_kwargs` K=1153, both tops: trap 1. CODC hit skipped the phase-6 binder reservation; the binder permuted slots, then its `**kw` allocation failed and the unwind could not restore the stack (`c` bound to `*rest`). | `img_gc_call_kw_varargs` | next commit |
| B19 | G7 (b) six `_bi_exec_globals` compiler-pass fixtures, both tops: trap 1. Idle cleanup (`_busy` 0) cleared compiler arrays the program was using. Builder omits the cleanup descriptor for programs naming `_PYC_G`. | existing fixtures unchanged (`img_lexer_count` etc.) | next commit |
| B20 | Review round 1 (finding 1): an abandoned-remainder or skipped-run header written at the old bump pointer lay at or above `heap_zero_r`, so a later install did not zero it and a new dict/set table could read it as a key. `heap_zero_r` now also follows allocator header writes; new G6 invariant `[GC-INV] run header written ... above heap_zero_r`. | `img_gc_memoryerror_caught` under `+GC_EVERY_N_RUNS=1` (G7 a) fires the invariant before the fix | next commit |
| B21 | Review round 1 (finding 2): `len(instance)` rewrote the callable slot (`__len__`) and the NULL slot (`self`) before the binder reservation; an abort re-dispatched `__len__(x, x)` (trap 6). Undo record `gc_undo_len_r` restores `len`; the NULL slot reuses `gc_undo_bm_r`. | `img_gc_len_varkw` (trap 6 before, 0x319 after) | next commit |
| B22 | Review round 1 (finding 3): `GC_CALL_BINDER_OOM` only reached its `[GC-INV]` fatal when the placement *fit*, so it never fired; an under-reservation silently unwound a half-bound CALL (how B18 hid). Now every binder placement failure with GC on is a G6 fatal. | mutants 34 and 38 now die on the invariant | next commit |
| B23 | Review round 1 (finding 4): the idle premark of the builtins dict header hid `int` (and the exception types), whose `tp_dict` is mutable; `int.__dict__["k"] = [..]` was freed. The builder lists the kept builtins values at `PYCORE_GC_EXTRA_ROOTS` (traced every collection) or clears the premark when they do not fit; programs that name none of `__dict__`, `setattr`, `delattr`, `vars`, `compile`, `exec`, `eval`, `_bi_exec_globals` get immutable type dicts (prunable); the engine traces the extra roots only after LOAD_ATTR `__dict__` on a type (`gc_tdict_exposed_r`). Mutant 45. | `img_gc_builtin_type_dict` (dumps SAFETY and trap 7 without the roots; 0x2a0 with) | next commit |
| B24 | A MemoryError raise left `gc_collected_r` set. The next allocation miss (any pc, either core's NEED_HEAP) skipped its collection and raised MemoryError with the dropped data still on the heap; `img_gc_grant_churn` default recipe trapped 17 at STORE_ATTR after a caught fill OOM. The raise branch of `S_GC_ALLOC` now clears the flag and the phase. | `img_gc_memoryerror_again` (+two-core; trap 17 before, 3 after) | next commit |
| B25 | Review round 2 (finding 1): `GC_CALL_OOM` treated every CALL made while a protocol call was active (the whole `__next__`/`__iter__` body) as the container launch, which has no undo record, so `Rec(..)` inside `__next__` trapped 7 with garbage on the heap. Only the launch itself (depth below the protocol frame) is exempt now. Mutant 47. | `img_gc_protocol_body_call` (+two-core; trap 7 before, 20100 after) | next commit |
| B26 | Review round 2 (finding 3): `_bi_heap_release` rewound the bump pointer over written bytes and nothing zeroed them; a dict or set built there saw stale keys (also with `GC_EN=0`, pre-existing). Keep-run (P8) removed the boundary re-zeroing that sometimes hid it. With GC on the release now zeroes `[mark, old ptr)` at the next boundary. Mutant 46. `GC_EN=0` keeps the old behaviour (G1); listed as open in `master_plan.md`. | `img_gc_release_zero` (+two-core; 4 before, 0 after) | next commit |
| B27 | Review round 2 (finding 2): the cleanup descriptor and immutable type dicts were decided from `co_names` only; `exec("_PYC_G['k'] = [..]")` stored a list into the premarked, untraced `_PYC_G` and it was freed. The builder now adds the identifiers in loaded string constants for programs that compile source at run time, and assumes every name for programs that assemble code (`_bi_code_new/blit/patch`). | `img_gc_exec_pyc_g` (trap 1 before, 0x1b after) | next commit |
| B28 | Review round 3 (finding 1): the release-zero pass wrote `gcalloc_wdata_r`, which still held the last skipped-run header after a MemoryError that raised without installing a run; the "zeroed" bytes were header copies. The pass now clears the data word, and G6 checks that every phase-2 word write carries zero. Mutant 48. Also widened the mark epoch to 32 bits (round 3 finding 5: a 16-bit epoch wraps after 65,536 collections and a stale mark would then zero live objects) and fault on a mark that is not 16-byte aligned (finding 8). | `img_gc_release_zero_after_oom` (`+GC_AUTO=0`) | next commit |
| B29 | Review round 3 (findings 2-3): B27 read only `str` constants, so strings folded into tuple constants (`def f(src="_PYC_G[..]"): exec(src)`) were missed, and `bios(payload)` (which execs) was not a run-time-source name. The builder now walks tuple and frozenset constants (docstrings excepted) and derives the run-time-source names from the firmware builtins that call exec/eval/compile. | `img_gc_exec_pyc_g` (string default) | next commit |
| B30 | Review round 4 (finding 1): STRACC writes split/partition/join pieces past `heap_ptr_r` before a later piece answers NEED_HEAP; the aborted op never moved `heap_ptr_r` over them, so `heap_zero_r` stayed below dirty bytes that a later run install handed out unzeroed. Any non-collector core write into the dynamic heap now raises `heap_zero_r`, and a G6 invariant checks it (`[GC-INV] heap write ... above heap_zero_r`). Mutant 49. Excore growth firmware writes through its own port; round 5 read every NEED_HEAP site in `excore/fw/list_grow.s` (dict grow, set grow, dict merge, list grow) and each checks the limit before any slot write. No invariant checks the excore slot port yet (open, round 5 finding 1). Round 4 also: G10 runs the quick gates once with no mutant and fails if they fail; docstring exclusion counts a shared constant that is also loaded; run-time-source builtins are derived transitively. | `img_gc_stracc_split` fires the invariant without the fix (mutant 49) | next commit |

## Mutants
| n | Description | Killed by | Fixture added |
| --- | --- | --- | --- |
| 1 | skip RF resident ring | G4 | — |
| 2 | skip RF spill range | G3 | — |
| 3 | skip frame descriptors | G3 | — |
| 4 | skip only frame globals_base | G3 | — |
| 5 | skip exception-stack nodes | G3 | — |
| 6 | skip active_exc_r | G4 | — |
| 7 | skip container_call_saved_* | G4 | — |
| 8 | skip cur_closure_r | G4 | `img_gc_mutant_8` / `img_gc_root_closure` |
| 9 | skip boot record | G3 | — |
| 10 | skip native-method sidecar | G3 | — |
| 11 | skip cur_code_r / globals_base_r | G4 | — |
| 12 | LONG_STR extent 16 B short | G3 | — |
| 13 | list trace 0..length-2 | G3 | — |
| 14 | list extent length*32 not cap*32 | G3 | — |
| 15 | dict order buffer not marked | G3 | — |
| 16 | dict TOMBSTONE keys traced | G3 | — |
| 17 | dict None-key slots skipped | G3 | — |
| 18 | set table not marked | G3 | — |
| 19 | OBJECT ob_type not traced | G3 | — |
| 20 | CODE_OBJECT skip co_consts | G3 | — |
| 21 | ITER kind 3 spill word unmarked | G3 | — |
| 22 | RANGE mode 1 tuple unmarked | G3 | — |
| 23 | MUT_BYTEARRAY buffer unmarked | G3 | — |
| 24 | sweep swallows next live granule | G3 | — |
| 25 | bitmap not cleared | G3 | — |
| 26 | heap_limit_r not updated on run switch | G4 | — |
| 27 | run switch ignores 64 B slack | G4 | `img_gc_mutant_27` |
| 28 | skipped runs dropped | G7 (returns 0; survived host G10 at `10b2ba8`) | `img_gc_mutant_28` |
| 29 | no CODC/GIC flush | G4 | — |
| 30 | epoch not incremented | G4 | — |
| 31 | re-dispatch at next instruction | G4 | — |
| 32 | STRACC NEED_HEAP as success | G4 | — |
| 33 | excore MB_HEAP_LIMIT stuck | pending Phase 3 | — |
| 34 | CALL **kwargs budget one short | G4 | `img_gc_mutant_34` |
| 35 | UNPACK_EX capacity after tos | G8 | — |
| 36 | OOM loop guard + empty-list MEM_FAULT disabled | G4 | `img_gc_mutant_36` |
| 37 | mark-stack refill drops one | G3 | — |
| 38 | own (B18): CODC-hit CALL skips the binder reservation | `img_gc_call_kw_varargs` trap 1 (cloud) | `img_gc_call_kw_varargs` |
| 39 | own (B19): idle cleanup also clears while `_busy` is set | `img_gc_code_new` under EVERY_N_RUNS=1 trap 1 (cloud) | — |
| 40 | own (B14): release below the heap base treated as superseded | `img_gc_mutant_40` returns instead of trap 7 (cloud) | `img_gc_mutant_40` |
| 41 | own (B1): installed run not zeroed | `img_gc_zero_on_reuse` value mismatch (cloud) | — |
| 42 | own (§4.4 keep-run): kept current run also listed free | `img_gc_mutant_43` dumps: SAFETY (cloud) | — |
| 43 | own (B13): empty-string ITER decoded as LONG_STR at 0 | `img_gc_mutant_43` `[GC-INV] wild_ptr=1` (cloud) | `img_gc_mutant_43` |
| 44 | own: idle-cleanup skip ignores the dirty flag | `img_gc_mutant_44` dumps: SAFETY 638 granules (cloud) | `img_gc_mutant_44` |
| 45 | own (B23): extra roots never traced | `img_gc_builtin_type_dict` trap 7 + dumps SAFETY (cloud) | `img_gc_builtin_type_dict` |
| 46 | own (B26): release does not zero `[mark, old ptr)` | `img_gc_release_zero` returns 4 | `img_gc_release_zero` |
| 47 | own (B25): every CALL in a protocol body treated as the launch | `img_gc_protocol_body_call` trap 7 | `img_gc_protocol_body_call` |
| 48 | own (B28): release-zero keeps the allocator's last header word | `img_gc_release_zero_after_oom` G6 `[GC-INV] zeroing write` | `img_gc_release_zero_after_oom` |
| 49 | own (B30): core heap writes above `heap_zero_r` do not raise it | `img_gc_stracc_split` G6 `[GC-INV] heap write` | `img_gc_stracc_split` |

Replaced candidates: "unwind skips the CALL_KW names re-push" (B10) and
"stale `container_proto_iter_r`" (B9) did not change any result once the
binder reservation runs on both CALL paths (no binder allocation can fail
after the binder writes the popped names slot) and boundary collections
keep the current run; "S_GC_ENTER does not drain" (B7) is confined to the
first PRELOAD now that later ones copy the on-chip prune map.


## Plan deviations
| Section | Old claim | Evidence | Commit that updated the plan |
| --- | --- | --- | --- |
| §0 / A.5 | design target `f5a8eb92` | Branch is `origin/main` 939c8c7 (17 commits later, per A.5 step 1). `git log f5a8eb92..939c8c7 -- pycore/rtl pycore/tools excore Makefile`: RTL changes are `call_bi_id_r` (builtin id no longer parked in `call_entry_slot_r`, `pycore_call_fsm.svh` sub 0-1 dispatch) and code RAM 65,536 → 131,072 slots (`PYCORE_CODE_RAM_BLOCK_COUNT` 256). No [V] row about heap, roots, tags, allocation sites, caches or excore changed. `call_sub_r` is 7 bits (sub 64 in use). | kickoff |
| §1.1, §5.3 | code RAM 65,536 slots, 15,508 free after the compiler | 131,072 slots on 939c8c7; free count re-measured by `make pycore-size-report` in G0 aux log | kickoff |
| §3.3 step 5, §3.6 | re-dispatch = `redirect_pending_r <= 1; redirect_tgt_r <= gc_req_pc_r` | Fetch folds `EXTENDED_ARG` and reports the pc of the final opcode (`pycore_fetch.sv` `pc_o <= pc_r` on the real slot), so a redirect to `cur_pc_r` would drop the prefix (e.g. `LOAD_ATTR` method bind with namei ≥ 128). Fetch is stalled for the whole instruction and still presents it (`instr_valid_o`, folded `arg_o`), so re-dispatch is `fetch_skip_r <= 0`: the next `S_FETCH` cycle re-latches the held instruction with its full argument. A G6 check asserts fetch holds the aborted instruction. The existing `TRAP_RES_RETRY` redirect has the same latent bug when `fetch_skip_r` is 1; it is unexercised (no firmware emits RETRY). | P0 core integration |
| §4.7 "objects are written into fresh memory" | allocation sites need no change | `BUILD_MAP` (and every RTL dict/set table allocation) never clears its hash table: it relies on the bump allocator only ever handing out never-written (zero) memory. Reused memory would present stale key tag words as live keys. Fix: the allocator keeps the invariant. `heap_zero_r` tracks the highest byte ever allocated or written by the sweep; when `S_GC_ALLOC` makes a free run current it zeroes `[base, min(end, heap_zero_r))` (and the header granule) with full-line writes (`dmem_line_o`; `pycore_cache.sv` installs a written line without a fill). Poison never goes above `heap_zero_r`. `_bi_heap_release` keeps its GC_EN=0 behaviour (P1), so reallocating a table over released memory remains the pre-existing hazard it is today. **Superseded by B26** (review round 2): with GC on, a rewinding release now zeroes `[mark, old ptr)`; P1 revised for those fixtures (next row). | P0 core integration |
| §10.2 G13 P1 | every no-collect fixture identical to G0 with `GC_EN=1` | B26 makes a rewinding `_bi_heap_release` zero the bytes it hands back (an `S_GC_ALLOC` visit with no collection). Full run at `7e410f3`: `img_heap_mark_release` 3441 -> 3535 (zeroing 30 cycles, 2 lines), `img_compile_release_realloc` 423129 -> 426993 (zeroing 4888 cycles, 349 lines, about 14 cycles per 64 B line; the mutator part is 422105, below G0). With the zeroing disabled (mutant 46) both match G0 exactly. Memory-bound: the pass is one full-line write per 64 B line (`dmem_line_o`, no fill) plus at most two word writes for the unaligned ends; tried after the miss: the zeroing already uses line writes, and deferring it to the next allocation that lands in the window still costs the same writes. Revised P1 for a no-collect fixture whose only difference is cycles and whose `total_pause` comes from release zeroing: identical to G0 with mutant 46, and mutator cycles (total minus `total_pause`) at most G0 + max(0.5%, 64 per zeroed line) for the cache lines the pass displaces, and the zeroing pause at most 16 cycles per line + 64. Clause (2) of the revision rule (implement a further optimisation) was not met: the pass already uses line writes, and B26 requires the zeroing; a deferred, reuse-only zeroing was not tried. Every other no-collect fixture stays identical. | next commit |
| §4.2, §4.3 | bitmap bit g ⇔ `0x440 + 16g`; 61,372 bits | bit g ⇔ granule `addr >> 4` (no subtraction on the mark path); 480 words × 128 bits cover `[0, 0xF0000)` | Phase R |
| §5.1 | tracing the pinned static image is cheap | Measured: a verify-only collection of `img_containers` at exit (0 live dynamic bytes) takes 187,371 cycles, 9,785 mark transactions over 765 static objects (≈380 KB static firmware image in every fixture, larger than L2, so most reads miss). Planned optimization (Phase 2 perf work): prune static subgraphs that cannot reach a runtime-mutable object (code objects, their tuples and `co_kwdefaults` dicts, type dicts, strings), via a per-image static prune map preloaded into the mark bitmap at collection start; the oracle keeps checking the unpruned live set. | P0 measurement |
| §10.2 G7 (b) | K=1 for every `pycore-img-gc-all` fixture | Still true. 1000-iter `steady_*` and `bench_*` (and the G9 churn loops) moved to `pycore-img-gc-sites` so they get the prime-K rule. Evidence: G7 (b) `steady_list` at K=1 ran 95 min with `MAX_CYCLES_SCALE=4980` and had not finished; six such sims in parallel. | this commit |
| §10.2 G7 (a)/(c), G8 | heap = 1.25 ×, then 2 ×, peak live | G8 seed 0 at 1.25 ×: trap 7 (largest 544 B). 2 × PASSES seed 0. G8 seed 2 at 2 ×: live 63 KB, free 67 KB in 183 runs, largest 11 KB, trap 7; 2.25 × PASSES (14 collections). Adopted 2.5 ×. | this commit |
| §3.3 step 6 | second same-pc collection with unchanged largest is OOM | G7 `img_gc_stracc_split` at 40960+EVERY_N=1: two collects at pc 162, largest 35728 ≥ need+64, trap 7. Guard now also requires `largest < need+64`. | this commit |
| §10.2 G10 n=36 | "OOM loop guard disabled" changes behaviour | After a fruitless collect, `S_GC_ALLOC` MEM_FAULTs on an empty run list even when `retry_count==0`, so skipping only the guard still trapped 7. Mutant 36 now also skips that empty-list fault (hangs). | this commit |
| §4.4 run list | every maximal free run is listed | `bench_full` had 844 runs, 282 of them < 64 B. `ensure_run` needs `size >= need+64`, so those pads are never installed. Sweep now skips listing them (562 runs, sweep 45585→30872). Oracle `expected_runs` matches; `free` still includes the pads. | this commit |
| §4.3 headers | `{MAGIC,size,next,0}` in the first 16 B of each free run | Scattered in-place writes were ~55 cyc each. Sequential table at `0x148400` (`{MAGIC,size,next,base}`) cut `bench_full` sweep 30872→7784. Dumps exact (reuse/cycle/zero). P4 still 7784>5292: cold line fills. | 2bc5e1f |
| §4.3 / P4 | sequential table writes in the pause | First 1024 runs stay on-chip; allocator peeks by index. `bench_full` sweep 7784→2172 ≤ 5292. Dumps exact. | this commit |
| §10.2 G13 (on-chip storage) | justify on-chip storage above 16 KB | Bitmap 61,440 + run table 65,536 + mark stack 17,152 + prune-map copy 32,768 = 176,896 bits (21.6 KB). Run table: `bench_full` sweep 7,784 → 2,172 (P4). Stack and prune-map copy: `bench_churn` P6b 0.283 → 0.240 with the cleanup skip. Recorded in gc.md Performance. | next commit |
| §4.4 | a collection rebuilds the run list and the next allocation selects a fresh run | G8 single-core measure runs: 1.43 run pops per site allocation, 6-10 per collection. Boundary and exit collections keep the current run (engine premark + split listing; `keep_lo/keep_hi` in dumps); explicit collections still re-select first-fit. | next commit |

| §5.1 | tracing the pinned static image is cheap (and the planned prune treats type dicts as immutable) | Implemented as the static prune map (Decisions). Type dicts are *not* treated as immutable: `STORE_ATTR` requires an instance, but `LOAD_ATTR __dict__` on a type returns the type dict, which `STORE_SUBSCR` can mutate. | this commit |
| §1.3 row 11, §3.4 | `UNPACK_EX` adjusts `tos` before its bump, so it needs a reorder | The capacity check (`pycore_cont_list.svh` `CP_SRC_HDR`) already precedes `tos_r <= tos_r - 1`; the abort exits from the check before any commit. No reorder needed. Mutant 35 becomes "capacity check moved after the `tos` change". | 194eb01 |
| §3.5 | CALL reserves its whole budget in one new phase before phase 7 | As built: allocations *before* the binder (bound-method unwrap, instance/exception/range/set/code objects, sites `GC_CALL_OOM`) abort individually; the prelude's commits are undone by `CALL_PHASE_GC_UNWIND` from an undo record (`gc_undo_bm_r`: restore the NULL slot; `gc_undo_kw_r`: re-push the KW names tuple; `gc_undo_ex_r`: rewrite the `*args`/`**kwargs` operands), then `GC_ABORT_COMMON`. Only the binder's own allocations (`*args` tuple, `**kwargs` dict) are reserved, in phase 6 before the binder permutes slots: `tuple(extra)+64` and `dict_place_end(min_slots(n_kw))+64`, where `n_kw` for `CALL_FUNCTION_EX` comes from the dict's `order_len` (read only when the current run is below `GC_CALL_FAST_BYTES` = 17,408, so the common case costs no cycle). A binder allocation failing after its reservation is a `[GC-INV]` fatal. | 194eb01 |
| §3.4 (ceiling) | every allocation site restarts at the instruction boundary | A CALL issued by a container protocol call (`container_call_active_r`: `__next__`, `__iter__`, `__init__`, `__len__` launched from `FOR_ITER` etc.) cannot be undone (the outer container operation is suspended in the one register bank), so an allocation failure there is `PY_TRAP_MEM_FAULT`. Known ceiling; reported in the final report. | 194eb01 |
| §4.7 | `_bi_gc_*` builtins are seeded in every image's builtins dict | Seeding them in every image changes the builtins dict size and so the cycles of every GC_EN=0 fixture (G1). `image_from_source.py` seeds each `_bi_gc_*` name only if the program's code tree references it. | 194eb01 |
| §4.7 zeroed allocation | zeroing uses full-line writes | Full-line writes only with `CACHE_EN=1`; with `CACHE_EN=0` the hierarchy carries 16 B words (bug B2), so the zeroing loop writes words. | this commit |

## Pre-existing failures at G0
None. `tools/gc_baseline.py --repo build/g0_wt --jobs 6` at 7d86797 (no RTL
change vs `origin/main` 939c8c7): 1,615 simulator runs pass (default 489,
CE0/LAT4 375, CE0/LAT1 375, CE0/LAT30 375, CE1/LAT30 1); all five non-image
`all-tests` steps pass; 400 s wall time on 6 jobs.
