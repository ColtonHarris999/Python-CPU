# Container accelerator

The container accelerator (CA) is the unit that owns list, tuple, dict,
set and bytearray memory. pycore issues a command and waits for two
events. **Data ready** means the instruction's result is final, every
raise has been decided, and every allocation is reserved. pycore retires
the instruction then. **Container ready** means every byte of that
command is in the cache and the object is consistent for the GC or any
other reader. In the hardware that is on `main` today, those two events
are the same cycle (stage A0): the core stays frozen until the command
finishes. The ports already carry a command id so a later pycore can
retire at data ready and keep executing while the CA finishes the copy.

The design this hardware is built from is the second research round of
[`planning/accelerator_split_plan.md`](../../planning/accelerator_split_plan.md)
(commit `199b651` on `origin/claude/modest-mendel-oevips`).

## Where it sits

```text
             ┌──────────── pycore (bytecode hart) ────────────┐
 fetch ─ L1I │ decode / execute                               │
             │ heap_ptr is the only allocator                 │
             └──┬───────────┬───────────────┬─────────────────┘
                │ cmd       │ dr / cr       │ other dmem masters
                ▼           │               │
          ┌──────────┐      │               │
          │    CA    │──────┘               │
          └────┬─────┘                      │
               │ one word port, core frozen │
               ▼                            ▼
          ┌──────────────── L1D ─────────────────────────────┐
          └────────────────────┬─────────────────────────────┘
                               ▼
                         xbar ─ L2 ─ RAM
```

Stage A0 uses the core's dmem port. The CA is the only master while
`S_CA` is the core state, so there is no coherence flush and no second
copy of the line. A later stage gives the CA its own arbitrated port on
the same side of L1D and lets the core keep running after data ready.

`+CA_EN=0` puts list growth back on the excore trap path. `+CA_EN=1`
(the default) handles it in the CA.

## What a command does

`PY_CA_L_APPEND` is the command that is in the hardware. pycore raises
it from `LIST_APPEND` when `len == cap`, which used to be excore trap 9.
The CA:

1. Reads the list header `{capacity, length}` and the `ob_item` pointer.
   The object address does not move.
2. Picks `new_cap = cap == 0 ? 4 : cap * 2` and reserves
   `new_cap * 32` bytes at `heap_ptr`. If that does not fit, it returns
   short-heap and has written nothing. With the collector on, pycore
   collects and retries. With it off, the instruction is a memory fault,
   the same code an excore `NEED_HEAP` produced.
3. Copies `len` elements into the new buffer. Tag slots are written with
   the upper bits clear.
4. Appends the new element, then publishes the header and the new
   `ob_item`. Publish is the last write.
5. Signals data ready. pycore stores the new `heap_ptr`, pops the
   appended value, and fetches the next instruction.

```text
  list object (stable)              element buffer (moves)
  ┌────────────────────┐            ┌────────┬────────┐
  │ cap │ len          │            │ value  │ tag    │  × capacity
  │ 0   │ ob_item ───────────────►  └────────┴────────┘
  └────────────────────┘              stride 32 bytes
```

Spare capacity still uses the existing pycore fast path and does not
enter the CA. `LIST_EXTEND`, mid-list delete, and dict and set growth
are still excore traps. Those are the next commands on the same port.

## Data ready and container ready

| Class | Examples | Data ready | After data ready |
| --- | --- | --- | --- |
| E0 | append, set add, dict set | after the grow decision and the reservation | insert, rehash, copy |
| E1 | list set/delete/pop | after the bounds check and the popped value | shift, tombstone |
| E2 | build, concat | after the reservation | fill the object |
| E3 | get, contains, len | when the value is known | nothing |

Stage A0 waits for the whole command, so E0's copy is finished before
pycore moves on. Splitting the two events is what lets a later core
overlap that copy with arithmetic and `LOAD_FAST`.

## Measured cost

`list-comp-basic` (`[i for i in range(...)]` shape in the hardware
suite) is the program that used to pay an excore trap on every list
growth. Same two-core simulator, cache on, memory latency 4.

| Program | Excore list-grow traps | Cycles |
| --- | ---: | ---: |
| `list-comp-basic`, before the CA | 4 (trap 9) | 6,940 |
| `list-comp-basic`, CA append | 0 | 2,745 |

That is 2.5× on this program. The difference is the coherence handoff
the trap used to pay: pycore wrote back and invalidated L1D, the excore
ran the copy from L2, then pycore refilled L1D. The CA reads and writes
through L1D while pycore is frozen, so those flushes do not happen.

The same command is what makes a single-core machine able to grow a
list at all. `container-list-append-grow` (`[i for i in range(8)]`,
return the last element) completes on the single-core top in 2,632
cycles and returns 7. Before this command that program halted with trap
9.

Checked values, two-core, zero list-grow traps:

| Fixture | Result |
| --- | --- |
| `grow_from_zero` | 55 |
| `alias_stability` | 30 |
| `mixed_tags_preserved` | 1677 |
| `grow_repeated` | 3850 |
| `append_across_call` | 77 |

`+CA_EN=0` still raises trap 9 on a full append when no excore is
present, which is the `container-list-append-full-fatal` and
`excore-disabled` checks.

## Groundwork that landed with it

These are in the same branch because a second data master and a
memory-mapped console cannot be correct on top of them.

- Held dmem masters (container, frame, RF spill, exc stack) drop `req`
  on the ack cycle. L1D was executing that beat twice. Hit counters were
  about 2× high, and a console write would have printed twice.
- An L1I miss is one L2 read. L2 returns the 64-byte line and L1I
  installs it.
- The flush sequencer quiesces L1D before it asserts flush or
  invalidate, and holds the request until L1D leaves idle.
- The excore slot port holds its request until ack. The crossbar locks
  the grant so the level request is not taken twice.
- A store or delete of the active globals or builtins dict flushes the
  global-name cache. `ns[name] = …` used to leave a stale hit.
- STRACC hashes a code unit only when it stores it. Strings longer than
  16 payload bytes now match an equal constant. `rfind` of a missing
  needle and `strip` of two long strings finish.
- Excore `SET_UPDATE` keeps its loop bound in scratch that equality does
  not clobber. Long-string keys use the cached FNV hash and compare by
  payload, not by address.
- An already line-aligned GC request fits a free run of that size.

Containers and the excore area are green on both tops after these
changes (81 container runs, the excore area including the trap-count
updates above). The strings area (36 runs) passed after the STRACC fix.
