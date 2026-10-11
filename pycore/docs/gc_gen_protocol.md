# Generational GC protocol

Status: specification for review (generational GC plan, Phase 1b). No RTL
implements it yet. Each rule has a number that the oracle
(`pycore/tools/gc_model.py`), the in-RTL `[GC-INV]` checks and the tests
cite. "The plan" means the generational GC plan; `gc.md` is the collector
as it is today.

The design in one paragraph: sticky mark bits. A bitmap bit that a
collection sets survives the sweep and means *old*. A **minor** collection
starts from that bitmap. It marks from the roots and from a remembered set
of old *owners* that the program wrote into since the last collection. The
marker's existing already-marked test stops it at every old object. A
**major** clears the bitmap and marks everything, as today. The barrier logs
owners in hardware at the container operations, at no mutator cycles. A
guard on the data-memory port turns any write into old memory that no
operation declared into a forced major.

## 1. Precision contract

- **P1 (safety).** No reachable granule is ever freed.
- **P2 (minor).** A minor frees exactly the dynamic granules that are
  *clear* at entry and that the minor trace does not reach. The minor trace
  starts from the roots and from the remembered owners, and it does not
  enter any granule that is set at entry. This is `gc_model.trace_minor`.
  - The plan's wording ("every young granule the full trace cannot reach")
    is too strong. A young object that is reachable only from an old
    object which is itself dead, but was logged, is necessarily kept by a
    minor. It is freed by the next major. The oracle checks the precise
    form above.
- **P3 (major).** A major frees every dynamic granule the full trace does
  not reach, exactly as `gc.md` describes today.
- **P4 (tenured garbage).** Unreachable granules that a minor keeps are
  freed by the next major. The major policy (plan §3.6) bounds how many
  accumulate.
- **P5 (barrier).** At a minor's entry, every reference from a set (old)
  granule to a reachable clear dynamic granule starts in an owner that is
  in the remembered set. A missed log that the guard sees forces a major
  (§3.3). One the guard cannot see is a bug, and it is caught by the oracle
  (`BARRIER:`) and by the testbench checker.

`gc.md` invariant 2 ("no floating garbage") holds for majors only. Every
other `gc.md` invariant is unchanged.

## 2. Granule states

Each granule (16 B) of the managed heap is in one of these states. Static
granules, below `dyn_base`, are never freed, so only their bit matters.

| State | Bit | Meaning |
| --- | --- | --- |
| S0 static, premarked | 1 | Set by the static map at a major's preload. Never cleared except by a major's `M_CLEAR`, which the preload sets again. |
| S1 static, unmarked | 0 | Never freed. A static object that a run-time write makes point to dynamic storage is an owner like any other (§4, row "static owners"). |
| D1 old | 1 | Marked by a collection and kept. |
| D2 young | 0 | Allocated since the last collection, or released and reallocated. |
| D3 free | 0 | In the run list. |
| D4 kept | 0 | The kept bump run `[keep_lo, keep_hi)`: free memory the allocator holds. |
| D5 pad | 0 | A free gap shorter than 64 B, not listed (`gc.md` P4). |
| D6 released | 0 | Cleared by `_bi_heap_release`; it becomes D2 or D3 storage again. |

**Transitions between collections:**

- **T1.** A bit is never set between collections. Allocation is white: a
  new object's granules stay 0.
- **T2.** A bit is cleared between collections only by a release (§6).
- **T3.** An abandoned collection, a run-time enable and a reset leave the
  bitmap unconstrained, and the next collection is a major (§8).

**Transitions across a collection.** This table is executable:
`gc_model.STATE_TABLE` checks every dynamic granule of every dump sequence
(`gc_model.py --check DIR --sequence`). `test_gc_model.TestGcModelMinor.
test_state_table` requires all 27 legal rows to occur.

| Bit at entry | Kind | Full trace reaches it | Allowed outcome (exit, bit at next entry) |
| --- | --- | --- | --- |
| 1 | minor | yes | held, 1 |
| 1 | minor | no | held, 1 (tenured garbage, P4) |
| 0 | minor | yes | held, 1 (promoted) |
| 0 | minor | no | free 0, kept 0, pad 0, or held 1 when a remembered owner reaches it (P2) |
| 1 | major | yes | held, 1 |
| 1 | major | no | free 0, pad 0 |
| 0 | major | yes | held, 1 |
| 0 | major | no | free 0, kept 0, pad 0 |

"Held" means neither in the run list nor in the kept run. A release
between the two collections clears the next bit whatever the outcome; those
are the remaining rows.

## 3. Guard and barrier request life cycle

**Terms.** An *operation* is one container op, one container-accelerator
(CA) command, or one excore trap dispatch. Each operation starts with
`bar_op_begin`, which increments `op_epoch_r` and empties the permit
windows. A *window* is an address range `[lo, hi)` that the operation
declares it will write.

- **B1, log.** `bar_log(kind, size, addr, windows)` enqueues an owner
  lookup, and adds the windows to the current epoch's window set. The
  windows are the owner's header and its buffer, table or order array as
  currently allocated.
- **B2, permit.** `bar_permit(windows)` adds windows only. It is for writes
  that cannot create an old-to-young reference (§4).
- **B3, guarded write.** A managed write is any data-memory write with
  `HEAP_BASE <= addr < heap_limit`, the static image included, that does not
  come from a raw master (STRACC on new strings, run zeroing, the GC
  engine). The window match is decided in the write's issue cycle and
  travels with the request. A managed write that matches no window enqueues
  a guard lookup tagged with the current epoch.
- **B4, lookup.** The barrier owns one bitmap read port while the engine
  is idle. It serves one FIFO entry per cycle and registers the result.
  - An owner lookup whose owner is set (old) is checked against the
    dedup filter. The whole entry must match for a hit. A miss writes the
    SSB entry and the filter.
  - An owner lookup whose owner is clear (young) is dropped. A young owner
    is traced anyway.
  - A guard lookup whose address is set sets `force_major_r` and counts a
    `guard_hit`.
- **B5, retirement.** A request retires when its result has been applied.
  `barrier_idle = fifo_empty && !lookup_in_flight`.
- **B6, overflow.** An SSB push into a full SSB is refused. It sets
  `force_major_r` sticky in the same cycle and counts `remset_overflows`.
  Dropping the entry is then safe, because the next collection is a major.
- **B7, FIFO bound.** The FIFO is 4 deep. A push into a full FIFO fires
  `[GC-INV]` (plan §3.7 item 4). The bound is argued in §9 from the site
  table. GG8 checks it with `bar_fifo_hw`.

## 4. Barrier sites

This table comes from an audit of every data-memory write in the RTL and
the excore firmware at `e689235`. Paths are relative to `pycore/rtl/`.
*Log* means the write can store a reference to a younger object into an
existing owner. *Permit* means it writes an existing owner, but only
values already inside it, tombstones, metadata, or a pointer to storage
the same operation allocated. *New* means it writes only storage the same
instruction allocated.

**S1. Pycore container ops (`S_CONTAINER`).** `bar_log` fires in the phase
that latches the buffer, table or order pointer, not at `CP_INIT`, because
the windows are known only there.

| Op | Owner | Class | Windows |
| --- | --- | --- | --- |
| `CONT_STORE_LIST` | the list | log | the buffer slot (`pycore_cont_list.svh:1182-1206`) |
| `CONT_LIST_APPEND`, spare capacity | the list | log | header, buffer slot (`:1367-1397`). A full list goes to the CA |
| `CONT_DELETE_LIST`, last element | the list | permit | header (`:1262`). A middle delete goes to the CA or trap 12 |
| `CONT_STORE_DICT`, `CONT_MAP_ADD` | the dict | log | header (48 B), table, order (`pycore_cont_dict.svh:570-865`, `:2085-2409`) |
| `CONT_DELETE_DICT` | the dict | permit | header, table, order (`:1068-1348`) |
| `CONT_SET_ADD` | the set | log | header (32 B), table (`:1673-1867`) |
| `CONT_STORE_NAME` (`STORE_NAME`, `STORE_GLOBAL`) | the dict at `globals_base_r`, static or dynamic | log | header, table, order (`pycore_cont_object.svh:500-853`) |
| `CONT_STORE_ATTR` | the instance's `__dict__`, never the instance | log | the dict's header, table, order (`:1888-2274`) |
| `CONT_DELETE_ATTR` | the instance's `__dict__` | permit | header, table, order (`:2391-2667`) |
| `CONT_STORE_DEREF` | the cell | log | `[cell+32, cell+64)` (`pycore_cont_closure.svh:178-188`) |
| `CONT_SET_UPDATE`, pycore path | the set | log | header including `table_ptr` at `+16`; the old table when it does not grow (`pycore_cont_bulk.svh:221-437`) |
| `CONT_DICT_UPDATE`, pycore path | the dict | log | header including the pointer word at `+32`; the old table and order when it does not grow (`:801-1126`) |

Overwriting an existing dict key also rewrites the key with the incoming
one, which can be a younger object that compares equal. The dict log
covers it.

**S2. Container accelerator (`S_CA`, `pycore_ca.sv`).** The core is frozen
in `S_CA` and the CA writes through the core's data-memory mux, so the
core-side guard sees every CA write. The owner is always `ca_a_r`. It is
never a decoded operand: a `DICT_GROW` raised from `STORE_NAME` or
`STORE_ATTR` carries the globals dict or the instance `__dict__`
(`pycore_cont_object.svh:563-571`).

| Command | Class | Windows |
| --- | --- | --- |
| `L_APPEND` | log | header (the new buffer is young) |
| `L_EXTEND` | log | header; the old buffer when it extends in place |
| `L_DEL` | permit | header; the old buffer |
| `D_GROW` | log | header (48 B) |
| `S_GROW` | log | header (32 B) |

- **S2a.** The CA logs the owner at command issue, and declares the old
  buffer window itself when it latches the pointer (`LE_ITEM`, `LD_ITEM`).
  The core cannot declare it at issue, because it holds only the handle.

**S3. Excore traps (two-core top).** Pycore is frozen in `S_TRAP_MARSHAL`
and `S_TRAP_WAIT`, and the excore writes through the L2 slot port. That
port bypasses the core's mux, so the guard is duplicated there (plan
§3.4). Only E0 is ever written.

| Trap | Class | Note |
| --- | --- | --- |
| 9 `LIST_GROW`, 10 `LIST_EXTEND`, 11 `DICT_GROW`, 13 `SET_GROW`, 14 `SET_UPDATE`, 19 `DICT_UPDATE` | log E0 | 10, 14 and 19 can write E0's old buffer or table in place |
| 12 `LIST_DELETE` | permit E0 | shifts in the old buffer |
| 16 `BUILTIN_CALL`, 20 `DICT_MERGE` | none | 16 only prints; 20 builds a new dict |
| 18 `SLICE` | none | nothing raises it |

- **S3a.** The core logs E0 at dispatch. The firmware declares windows
  through a new memory-mapped `bar_permit` register once it has read the
  buffer, table or order pointer. That is two stores per window, on a path
  that is already slow. The alternative, a pre-read by the core before
  dispatch, costs pycore cycles on every trap. **Open for review.**
- **S3b.** With the CA on (the default), traps 9-13 go to the CA and the
  excore never sees them.

**S4. Static owners.** These static objects are written at run time:

- the module globals dict (`STORE_NAME`, `STORE_GLOBAL`, dict ops on a
  `globals()` handle, `DICT_GROW`);
- `_PYC_G` (`compile()` stores, compiler `global` statements run through
  `_bi_exec_globals`, and list ops on the arena lists it holds);
- the builtins dict and type dicts, through any dict op given their handle;
- any static list, dict, set or cell.

Each is written only through the S1-S3 sites above, so they need no extra
site. Every static granule is old, and an SSB entry for a static owner is
scanned without the mark test like any other. A logged builtins dict scans
its whole table, which costs performance but is still correct. Nothing
writes the boot record after boot, and the sidecars at `0xF00000` are never
written.

**S5. No barrier needed.** These write only objects allocated by the same
instruction:

- `BUILD_*`, sequence concat and repeat, `UNPACK_EX`, `LIST_TO_TUPLE`;
- the call binder (`*args`, `**kwargs`), instances, cells, bound methods,
  ranges, `set()`, `_bi_code_new`, and new exceptions;
- `CONT_DICT_MERGE`, `CONT_SET_FUNC_ATTR` and `CONT_RAISE`. The plan listed
  these three as log sites; they are not.

No instruction writes an existing exception: there is no `__context__`,
`__cause__` or traceback chaining (`pycore_cont_raise.svh:27-170`). If
chaining is added, it becomes a log site. No bytearray payload store
exists today, so the plan's permit row for it has no site.

**S6. Write masters.** From the mux at `pycore_core.sv:2172-2216`:

| Master | Treatment |
| --- | --- |
| Container leg, CA | sites S1, S2 |
| Excore slot port | sites S3, guard at the L2 port |
| STRACC | raw. It writes new strings, and also the new lists of `str.split` and the new tuples of `str.partition`, all freshly placed |
| GC engine, `S_GC_ALLOC` (zeroing, skipped-run headers) | raw (free memory and engine metadata) |
| `S_MEM` `MEM_STORE_PTR` (opcode 201) | **guarded, never raw.** It writes any aligned address. The compiler does not emit it; removing the opcode is the cleaner fix |
| Frame push, RF spill, exception-info stack | outside the heap |

- **S7. New storage skips the lookup.** A write into `[heap_ptr at op
  start, heap_ptr)` targets storage this operation allocated. It is clear
  in the bitmap, so a lookup could only answer "young". Skipping it keeps
  the many `BUILD_*` and binder writes out of the FIFO. It is an
  optimization; correctness does not depend on it.

## 5. Collection entry ordering

- **E1.** Collections start only at instruction boundaries, from
  `S_GC_ENTER` in `pycore_core.sv`. No operation epoch is open there.
- **E2.** `S_GC_ENTER` waits for every outstanding data-memory beat (as
  today), then for `barrier_idle`. Every write issued before entry has
  then had its guard lookup, and every accepted log is in the SSB.
- **E3.** After E2, the kind is decided in one cycle from
  `force_major_r`, the SSB state and the policy inputs:
  `minor = gen_en && !force_major && !explicit && !at_exit && !major_due`.
  Because E2 drains first, an overflow or guard hit caused by any write
  before entry is visible here. A same-cycle overflow and collection
  request therefore resolve to a major (B6).
- **E4.** The core is stalled in `S_GC_*` until the engine finishes, so
  nothing enqueues during a collection. The engine empties the SSB, the
  filter and the windows after its sweep, and not before.
- **E5.** The dump is written at entry, after E2: `meta barrier_idle` is
  always 1 there, and the oracle checks it.

## 6. Release

`_bi_heap_release(mark)` returns `[mark, heap_ptr)` to the allocator.

- **R1.** The bitmap bits of `[mark, heap_ptr)` are cleared. The two
  partial words at the ends are cleared with masks, so neighbouring
  objects keep their bits. This happens in the zeroing pass the release
  already runs.
- **R2.** Every SSB and filter entry whose address lies in the range is
  invalidated: one compare per entry, overlapped with the zeroing.
- **R3.** If R2 is ever too slow, the fallback is to set `force_major_r`
  and discard the SSB. That is also safe.
- **R4.** The next dump records `event release <lo> <hi>`. The oracle then
  expects the range clear at entry and no SSB entry inside it.

## 7. Kept-run exclusion

- **K1.** The kept bump run holds no object, so in sticky mode it must
  never be painted (that would promote free memory) or listed (that would
  double-book it).
- **K2.** Both sweeps treat `[keep_lo, keep_hi)` as allocated and emit
  runs around it, through the existing `keep_ahead` and `keep_here` tests
  in `pycore_gc.sv`, not by painting bits. The comment there that says
  `M_SW_KEEP` "sets its bits" is stale and is corrected with the RTL change.
- **K3.** The kept range holds no set bit at entry. `[GC-INV]` checks this at
  `S_GC_ENTER`, and so does the oracle (`gen_invariants`).

## 8. Enable, reset and abandon

- **N1.** `force_major_r` resets to 1. The first generational collection
  is therefore a major that clears and preloads. The old set is
  initialized by a collection and never assumed.
- **N2.** A run-time enable (a future configuration bit) sets
  `force_major_r`.
- **N3.** A reset while a lookup is pending empties the FIFO and sets
  `force_major_r`.
- **N4.** An abandoned collection (rescan list full, data-memory fault)
  raises `MemoryError` as today, sets `force_major_r` and discards the
  SSB. In generational mode the idle-time bitmap clear runs only after an
  abandon.
- **N5.** The next dump records `event abandon`, `enable` or `reset`. The
  oracle then requires a major and does not constrain the entry bitmap.

## 9. FIFO bound

Inputs, from the audit:

- At most one data-memory write per cycle system-wide: one core port, and
  the excore slot port is exclusive with it through `mem_owner_r`.
- Guard-eligible writes (container leg, CA, `S_MEM`) are at least two cycles
  apart. A held master issues its next beat only after the acknowledgement
  (inferred from the handshake at `pycore_core.sv:2173-2180, 3929-3933`).
- Each instruction writes at most one existing owner (S1-S3). A pycore op
  and the CA command or trap it raises write the same owner, so at most two
  log pulses arrive per instruction, and never in the same cycle as each
  other.

Argument:

1. Arrivals: at most one log pulse and one guard lookup in any cycle.
   Guard lookups come at most every other cycle.
2. Service: one lookup per cycle, as long as the barrier owns the bitmap
   port. It does whenever the engine is idle and the idle-time clear is
   off. In generational mode that clear runs only after an abandon.
3. From 1 and 2, the FIFO holds at most 2 entries after any cycle, plus one
   lookup in flight. The 4-deep FIFO has one entry of slack.
4. After an abandon, `force_major_r` is set (N4) while the idle clear owns
   the port. Every lookup result is then irrelevant: a guard hit would only
   set `force_major_r` again, and the SSB is discarded by the major. The
   barrier therefore drops requests instead of queueing them until the
   next major completes.
5. A push into a full FIFO fires `[GC-INV]`. `bar_fifo_hw` is reported per
   run, and GG8 checks it stays at or below 3.

S7 is not needed for this bound. It only keeps the FIFO mostly empty.

## 10. Dump format

A generational dump adds to the format in `gc_model.py`:

| Line | Meaning |
| --- | --- |
| `meta gen 1`, `meta minor 0/1` | mode and kind |
| `meta old_hi <addr>` | exclusive bound on set bits |
| `meta force_major`, `meta remset_n`, `meta barrier_idle` | entry state |
| `remset <kind> <size> <addr-hex>` | one SSB entry |
| `oldbm <word> <bits-hex>` | the entry bitmap, nonzero 128-bit words |
| `event <name> [<lo-hex> <hi-hex>]` | `release`, `abandon`, `enable` or `reset` since the previous dump |

The plan proposed `[GC-GEN] event=...` log lines for events. Writing them
into the next dump instead keeps a dump directory self-contained. The log
lines are still printed for people reading the log.
