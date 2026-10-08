# Memory hierarchy (as built)

This is the as-built memory system on `main` after P0–P7 of
[`planning/old/memory_system_plan.md`](../../planning/old/memory_system_plan.md)
(that plan is complete). P8 (frame top-of-stack buffer) is **skipped**.
P9 re-measured the RTL counters against
[`pycore/tools/memsim/`](../tools/memsim/README.md); the numbers live in
[`planning/old/memory_hierarchy_report.md`](../../planning/old/memory_hierarchy_report.md)
§7.

Strings are ordinary heap objects. There is no `pycore_string_mem`.
The accelerator that walks their payloads is [`string_accel.md`](string_accel.md).

---

## Port contract

Unchanged from the 1-cycle SRAM days, and load-bearing: every cache in this
hierarchy drops in under the existing masters **without** changing how the
core waits.

> A request is captured on the cycle `req_i` is high (the master need not
> hold it). `ack_o` pulses for exactly one cycle when the response is ready,
> any number of cycles later. `fault_o` accompanies `ack_o`. At most one
> request is outstanding per master port (except on the opt-in ports below).

`PYCORE_CACHE_EN=0` (`+CACHE_EN=0`) is combinational pass-through to the next
level — the bisect switch and the transparency-test control arm.

Masters: fetch, MEM stage, container FSM, CALL/RETURN frame walk, exception
stack, STRACC, the garbage collector (`pycore_gc.sv`; see [`gc.md`](gc.md)),
excore (at L2, never at L1D).

### Several loads in flight (opt-in)

Beside the ordinary port, L1D has a **non-blocking line-read port** and L2 a
**pipelined port**. Nothing changes for a master that does not use them: an
ordinary request takes exactly as many cycles as before (G1 checks every
existing test cycle for cycle).

- **L1D `nb_*` port** (`pycore_cache` `NB=1`). A request (`nb_req_i`,
  `nb_addr_i`, a 4-bit `nb_id_i`) is accepted when `nb_gnt_o` is high in the
  same cycle. Up to `NB_SLOTS` (4) line fills are in flight. A read answers
  once with `nb_ack_o`, its `nb_id_o` and the whole line: a hit the next
  cycle, a miss when its line arrives, so answers can come out of request
  order. `nb_pf_i` makes it a prefetch: it fills L1D and never answers (a
  prefetch of a line already present or on its way is dropped).
- **While fills are in flight** an ordinary request that hits is served as
  usual. An ordinary miss (or a zero-line write) waits in a one-entry
  holding register until the fills have installed, then runs the ordinary
  miss path, so that path always has the down port to itself. While an
  ordinary request is waiting, `nb_gnt_o` stays low.
- **Install.** Fills install oldest first and pick their victim then. A
  dirty victim goes to a one-line writeback buffer that issues ahead of
  further reads.
- **Down path.** Fills and writebacks go down as whole-line requests on
  the xbar's pipe mode to L2's pipelined port (`pipe_i`, `gnt_o`, `last_o`).
  L2 takes one per cycle while they hit and answers in order, a read as 4
  beats after `PYCORE_L2_HIT_CYCLES`. A pipelined miss stops acceptance,
  waits for the answers ahead of it, and takes the ordinary miss path. The
  xbar stays with L1D until every pipelined request has answered.
- `CACHE_EN=0` turns both off (`nb_gnt_o` is low).
- Covered by `make pycore-mem-nb` (`tb_mem_nb`): ordinary (held and
  one-cycle) and non-blocking requests on conflicting addresses against a
  shadow memory, at memory latency 4 and 30.

The garbage collector is the first user: while marking it prefetches the
line of each object it pushes and the next lines of the range it is
scanning ([`gc.md`](gc.md), Performance). A scoreboarded core can use the
tagged reads.

---

## Levels

All sizes are named localparams in `pycore_defs.svh`. Line size is 64 B
everywhere.

| Level | Size | Line | Ways | Policy | Hit latency |
| --- | ---: | ---: | ---: | --- | ---: |
| **L1I** | 8 KB | 64 B | 4 | read-only; line refill | 1 cyc (`PYCORE_L1I_HIT_CYCLES`) |
| **L1D** | 8 KB | 64 B | 4 | write-back, write-allocate, LRU | 1 cyc |
| **L2** | 128 KB | 64 B | 8 | unified, write-back, **inclusive** | 8 cyc (`PYCORE_L2_HIT_CYCLES`) |
| **RAM** | 16 MB | — | — | behavioral; `RAM_T_FIRST` / `RAM_T_BEAT` | CI default 4 via `+MEM_LATENCY=` |

`PYCORE_L2_HIT_CYCLES` is 8, the plan table's number. It was 1 until the
test cycle budgets were raised to fit an 8-cycle L2. Like every latency
here it is a model parameter, not a measurement.

Fetch still uses Harvard slot addresses (`pc << 3`). The xbar adds
`PYCORE_CODE_ADDR_BASE = 0x01000000` so instruction bytes and data never
alias in the unified L2.

A 64 B fetch line buffer (P4b) folds `CACHE` / `EXTENDED_ARG` inside the
line. RTL `L1I hits/misses` therefore count fills **behind** that buffer, not
per wordcode slot. memsim E2 is still slot-granular; E9 calls this out.

### Result caches (not line caches)

| Structure | Entries | Ways | Key | Payload |
| --- | ---: | ---: | --- | --- |
| **CODC** | 4 | 2 | code-object base `[31:0]`; set index `(addr >> 6)` | 576 b CALL/RETURN fields |
| **GIC** | 16 | 2 | `{code_addr[31:0], namei[15:0]}`; set index `namei[2:0]` | 132 b `pycore_make_entry` |
| **FTB** | 4 frames (localparam only) | — | — | **not built** |

GIC fill is only on a successful `LOAD_GLOBAL` / `LOAD_NAME` resolve. A miss
is never cached. `CACHE_EN=0` is a miss pass-through.

---

## Data map

`DMEM_BLOCK_COUNT = 4096` → a 16 MB data window that ends exactly at
`PYCORE_CODE_ADDR_BASE`, so data and code never alias in the unified L2.
The physical RAM (`PYCORE_RAM_BYTES`) was already 16 MB; only the legal
window and the runtime regions moved (from the P5 2 MB map, where the
heap ended at `0xF0000`). Constants are mirrored in
`pycore/tools/encoding.py` (`test_memory_map_mirror.py`).

```
0x0000_0000 – 0x0000_03DF   reserved
0x0000_03E0 – 0x0000_043F   boot record (96 B: code / globals / builtins)
0x0000_0440 – 0x00EF_FFFF   object heap (~15 MB, bump, 64 B start-align)
0x00F0_0000 – 0x00F0_0FFF   exception-info arena (4 KB)
0x00F0_1000 – 0x00F0_8FFF   call-frame stack (32 KB, 1024 frames)
0x00F0_9000 – 0x00F0_9FFF   machine-configuration page (MCFG, ACCEL_CFG, CONSOLE_BASE)
0x00F0_A000 – 0x00F0_AFFF   excore context page
0x00F0_B000 – 0x00F0_EFFF   container-accelerator staging page
0x00F4_0000 – 0x00F7_FFFF   RF spill LIFO (256 KB, 8192 entries)
0x00F8_0000 – 0x00FF_FFFF   GC metadata (see gc.md)
0x0100_0000                 DATA_LIMIT == CODE address base (ROM + RAM)
0x0200_0000 – 0x0200_FFFF   IO window (console channels; decoded before L1D in P1)
```

The static boot image takes about 380 KB of the heap, so about 15 MB is
free when a program starts. On-device `compile()` keeps its whole
working set (roughly 10–15 KB per source line), so this is what sets the
largest file the hart can compile.

Held dmem masters drop `req` in the ack cycle, so an L1D hit is one
lookup (A6). The flush sequencer holds `flush_all` until L1D leaves
IDLE and blocks new accepts for the whole walk. A data-path store into
the code region (`CODE_ADDR_BASE` .. `IO_BASE`) faults. L2 is not
inclusive: nothing back-invalidates L1D. `+L2_HIT` and `+T_BEAT`
override the L2 hit delay and the DRAM beat spacing; `+MEM_LATENCY`
remains the first-beat latency.

The native-method sidecar sits in the exc arena immediately below the
StopIteration latch (`NATIVE_METHOD_TABLE_ADDR = 0xF00DE0`).

---

## Invalidation matrix

The system is not cache-coherent. There is one sharing event (excore
handoff) and it is coarse: pycore is frozen in `S_TRAP_MARSHAL` /
`S_TRAP_WAIT` for the whole window.

| Event | L1I | L1D | L2 | CODC | GIC | FTB |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| `trap_req` (grant to excore) | — | wb+inv | — | — | — | — |
| `trap_res` (grant back) | — | inv | — | flush | flush | — |
| `_bi_code_blit` / `_bi_code_patch` write | **inv** | — | (write goes through) | **flush** | — | — |
| `_bi_code_new` | — | — | — | **flush** | **flush** | — |
| `_bi_heap_release` | — | — | — | **flush** | **flush** | — |
| `MAKE_FUNCTION` / code release | — | — | — | flush | — | — |
| `STORE_NAME` / `STORE_GLOBAL` | — | — | — | — | flush | — |
| `globals_base_r` change (`_bi_exec_globals`) | — | — | — | — | flush | — |
| reset / boot | inv | inv | inv | flush | flush | — |

A recursive `RETURN` that restores the same `globals_base_r` does **not**
flush the GIC.

STRACC does not change this matrix. It is a dmem master only while the core
is in `S_STRACC`, so it cannot race L1D.

GIC validity is a whole-cache flush on purpose: reading a dict `version` to
do better would itself be a dmem access.

---

## P8 skip (frame buffer)

After P3, L1D already hits the frame-stack region well above the 95% gate
that would have justified `pycore_frame_buf.sv`:

| program | frame hits / (hits+misses) | rate |
| --- | --- | ---: |
| `img_recursion` | 1414 / 1420 | **99.58%** |
| `img_deep_callgraph` | 263 / 276 | **95.29%** |

`PYCORE_FTB_FRAMES = 4` remains as a named localparam. Do not build the
buffer unless a future workload drops under the gate.

RF spill/fill (`S_RF_SPILL` / `S_RF_FILL`, `compiler_design.md` §6.1) uses the
**ordinary dmem master**, so spilled slots land in L1D like any other access.
No extra invalidation row: `trap_req` already write-backs and invalidates L1D
before granting dmem to excore.

---

## Performance counters

`tb_container` prints these at the end of every image run (no MMIO):

```
L1I hits=… misses=…
L1D hits=… misses=… wb=… frame_hits=… frame_misses=…
CODC hits=… misses=… fills=… flushes=…
GIC hits=… misses=… fills=… flushes=…
RF spill_count=… wm=… tos=… resident=…
fetch mem_req=… buf_hit=…
PASS: … cycles=…
```

`pycore/tools/memsim/rtl_measure.py` parses that block. E9 compares it to
the model at the shipped sizes.

---

## What the model does not claim

memsim's L1D stream is interpreter metadata plus the STRACC accesses it
can see. RTL L1D also caches list/dict/iterator/excore traffic. On
`img_recursion` (almost pure metadata) the rates agree to a point; on
heap-heavy or very short programs they need not. See report §7.
