# Memory hierarchy (as built)

This is the as-built memory system after P0–P7 of
[`planning/memory_system_plan.md`](../../planning/memory_system_plan.md).
P8 (frame top-of-stack buffer) is **skipped**. P9 re-measured the RTL
counters against [`pycore/tools/memsim/`](../tools/memsim/README.md);
the numbers live in
[`planning/memory_hierarchy_report.md`](../../planning/memory_hierarchy_report.md)
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
> request is outstanding per master port.

`PYCORE_CACHE_EN=0` (`+CACHE_EN=0`) is combinational pass-through to the next
level — the bisect switch and the transparency-test control arm.

Masters: fetch, MEM stage, container FSM, CALL/RETURN frame walk, exception
stack, STRACC, excore (at L2, never at L1D).

---

## Levels

All sizes are named localparams in `pycore_defs.svh`. Line size is 64 B
everywhere.

| Level | Size | Line | Ways | Policy | Hit latency |
| --- | ---: | ---: | ---: | --- | ---: |
| **L1I** | 8 KB | 64 B | 4 | read-only; line refill | 1 cyc (`PYCORE_L1I_HIT_CYCLES`) |
| **L1D** | 8 KB | 64 B | 4 | write-back, write-allocate, LRU | 1 cyc |
| **L2** | 128 KB | 64 B | 8 | unified, write-back, **inclusive** | **1 cyc shipped** |
| **RAM** | 16 MB | — | — | behavioral; `RAM_T_FIRST` / `RAM_T_BEAT` | CI default 4 via `+MEM_LATENCY=` |

The plan table listed L2 hit = 8 cycles. `PYCORE_L2_HIT_CYCLES` is **1**: an
8-cycle L2 hit blew `MAX_CYCLES` on cold-start fixtures, and L1D covers the
hit path. Recorded here so the localparam is not mistaken for a measurement.

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

## Data map (P5)

`DMEM_BLOCK_COUNT = 256` → 1 MB. Constants are mirrored in
`pycore/tools/encoding.py` (`test_memory_map_mirror.py`).

```
0x0000_0000 – 0x0000_03DF   reserved
0x0000_03E0 – 0x0000_043F   boot record (96 B: code / globals / builtins)
0x0000_0440 – 0x000E_FFFF   object heap (~955 KB, bump, 64 B start-align)
0x000F_0000 – 0x000F_0FFF   exception-info arena (4 KB)
0x000F_1000 – 0x000F_8FFF   call-frame stack (32 KB, 1024 frames)
0x0010_0000                 DATA_LIMIT
0x0100_0000 – …             CODE address space (slot-indexed ROM + RAM)
```

The native-method sidecar sits in the exc arena immediately below the
StopIteration latch (`NATIVE_METHOD_TABLE_ADDR = 0xF0DE0`).

---

## Invalidation matrix

The system is not cache-coherent. There is one sharing event (excore
handoff) and it is coarse: pycore is frozen in `S_TRAP_MARSHAL` /
`S_TRAP_WAIT` for the whole window.

| Event | L1I | L1D | L2 | CODC | GIC | FTB |
| --- | :-: | :-: | :-: | :-: | :-: | :-: |
| `trap_req` (grant to excore) | — | wb+inv | — | — | — | — |
| `trap_res` (grant back) | — | inv | — | flush | flush | — |
| code-RAM write (future writers) | inv | — | — | flush | — | — |
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

---

## Performance counters

`tb_container` prints these at the end of every image run (no MMIO):

```
L1I hits=… misses=…
L1D hits=… misses=… wb=… frame_hits=… frame_misses=…
CODC hits=… misses=… fills=… flushes=…
GIC hits=… misses=… fills=… flushes=…
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
