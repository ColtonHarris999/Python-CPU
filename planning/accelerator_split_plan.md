# Accelerator split plan: container accelerator, console, bytes, and the excore as emulator

Status: **plan, not started.** Snapshot: `main` @ `5335a22`, 2026-10-07.

This plan moves every container operation out of the excore and out of
pycore's `S_CONTAINER` FSM into a new **container accelerator (CA)**. It
also makes `print` a plain memory write by pycore, adds `bytes` /
`bytearray` / `int.from_bytes` / `int.to_bytes`, and leaves the excore
with one job in the optimal design: running Python that pycore does not
implement yet. Startup configuration registers turn each accelerator on
or off. When an accelerator is off, the excore does its work, so each
accelerator's speedup can be measured.

The current state was measured on the simulators before this plan was
written: probe programs ran on the single-core (`EXCORE_EN=0`) and
two-core builds, with a mailbox trace hook. The results are in §2 and
Appendix B. Bugs found along the way are listed in Appendix A. Every
entry there says whether it was reproduced or found by reading code.

Opcode, type and builtin support stays in
[`pycore/docs/bytecode_support.md`](../pycore/docs/bytecode_support.md),
[`pycore/docs/exception_support.md`](../pycore/docs/exception_support.md),
[`pycore/targets/pycore.json`](../pycore/targets/pycore.json) and
[`pycore_firmware/builtins/builtins.md`](../pycore_firmware/builtins/builtins.md).
Update those in the same PR as the RTL change. This plan does not copy
them.

---

## 1. Goals

| # | Goal |
| --- | --- |
| G1 | In the optimal design the excore handles only Python that pycore does not implement: unimplemented opcodes, type combinations and builtins. It does no container, string or console work. |
| G2 | One container accelerator owns every container operation. That covers what the excore does today, plus every pycore container op that belongs there. |
| G3 | The CA interface separates **data ready** (the result pycore waits for) from **container ready** (background bookkeeping done). It is shaped for a scoreboarded, pipelined pycore later. |
| G4 | The CA's interaction with L1D, L2 and DRAM is designed explicitly. The memory interactions of the existing accelerators (STRACC, GC, excore, CODC, GIC, frame and RF spill, code RAM writes) are reviewed and fixed where wrong. |
| G5 | pycore supports `bytes`, `bytearray`, `int.from_bytes` and `int.to_bytes`. |
| G6 | Startup configuration registers enable or disable each accelerator. A disabled accelerator's work goes to the excore. There are two excore firmware builds (minimal, full) and two pycore ROM builds (accelerated, soft). Together they measure each accelerator's speedup. |
| G7 | `print` is a pycore memory write to a console address held in a per-process register. The excore takes no part in it. STRACC converts every value type to text, including `str()` of containers and of objects with `__str__` / `__repr__`. |
| G8 | All configurations give identical program results. Every new unit has a golden model, randomized tests, and counters that explain its cycles. |

Non-goals here: a pipelined pycore (this plan only shapes interfaces for it),
generators and `async` (they need suspendable frames, not an emulator),
arbitrary-precision `int`, and running the excore concurrently with pycore.

---

## 2. Where we start (measured)

### 2.1 What the excore does today

Each row was checked twice. On single-core, pycore halts with the code,
so it cannot do the work itself. On two-core, the mailbox trace shows the
trap and the program passes.

| Trap | Raised by | Single-core (`EXCORE_EN=0`) | Two-core cost |
| --- | --- | --- | --- |
| 9 `LIST_GROW` | `LIST_APPEND` (comprehensions) on a full list | halts, code 9 | ~3.8k cycles per grow |
| 10 `LIST_EXTEND` | **every** non-empty `LIST_EXTEND`, including one that fits in spare capacity. That includes `lst += x`, ROM `list.append` (`self += [value]`), every constant list literal of 3+ items (CPython emits `BUILD_LIST 0; LOAD_CONST tuple; LIST_EXTEND`), and one trap per element in ROM `list.extend`, `list()`, `sorted`, `map`, `zip`, `tuple`, `filter`, `range` and the dict views | halts, code 10 | ~2.0k per call (20 `.append()` calls = 20 traps, 40k cycles of wait) |
| 12 `LIST_DELETE` | mid-list `del lst[i]`. Last-element delete stays on pycore | halts, code 12 | ~2.2k |
| 11 `DICT_GROW` | a new key at ≥ 2/3 load, from `STORE_SUBSCR`, `MAP_ADD`, `STORE_ATTR` (an instance's 4th attribute) or `STORE_NAME` / `STORE_GLOBAL` | halts, code 11 | 12–14k |
| 13 `SET_GROW` | `SET_ADD` at ≥ 2/3 load | halts, code 13 | ~7.9k |
| 16 `BUILTIN_CALL` | any `OBK_BUILTIN` id the CALL FSM does not run itself. Firmware implements only `BI_PRINT` (one int (low 32 bits) / bool / None / ≤15-byte string per call) | `CALL_FILTER` (6). Single-core has **no console at all** | ~1.5k per printed piece |

Three more traps are offloads that pycore does not need. With
`EXCORE_EN=0`, uncontaminated `SET_UPDATE` (14), `DICT_UPDATE` (19) and
`DICT_MERGE` (20) run entirely in pycore's bulk engine
(`pycore_cont_bulk.svh`). That engine is 4–6× faster: 4,984 vs 23,780
cycles for `{**a, **b}`, 11,748 vs 68,432 for an update that grows twice,
and 11,248 vs 59,418 for a 24-element `{*list}`.

Some calls reach the excore and fail there. `bytearray(...)` and
`int.to_bytes(...)` (and `int.from_bytes`, which takes the same route)
come back `FATAL(ILLEGAL_OPCODE)`. Trap 18 (`SLICE`) is marked
recoverable, but nothing raises it and the firmware has no case for it.

### 2.2 Why excore work is slow

Measured with an instrumented two-core testbench:

| Event | Flush L1D | Firmware | Post-trap L1D refill |
| --- | ---: | ---: | ---: |
| `list.append` | 289 (3 dirty lines) | 1,143 | ~640 (12 misses) |
| `DICT_GROW` | 705 (11 dirty) | 11,273 | 22 misses |
| `SET_GROW` | 549 (8 dirty) | 7,320 | 17 misses |

About 40% of a small op's excore cost is the coherence handoff. The
excore attaches at L2, so pycore writes back and invalidates the whole
L1D before every trap, invalidates it again after, and flushes CODC and
GIC. A full flush costs 132 cycles plus ~52 per dirty line, up to 6,788
with 128 dirty lines.

### 2.3 Bugs this plan must fix or route around

Appendix A lists 25 items with their evidence. The ones that shape the
design are:

- **Excore firmware correctness.** `SET_UPDATE` corrupts its loop bound on
  a duplicate or collision: it hangs or drops elements (A1, A15).
  `LONG_STR` keys hash differently on the excore and pycore, so lookups
  miss after an excore rehash to ≥ 64 slots (A2). Excore bulk ops compare
  `LONG_STR` keys by handle, which creates duplicate keys (A3).
- **Memory system.** Every held-request dmem master is executed twice at
  L1D (A6). That is harmless for cached data, but a memory-mapped console
  write would print twice. The GIC serves stale globals after a mutation
  that is not `STORE_NAME` (A7).
- **Container FSM.** `in` hangs over more than 256 elements (A8). Name
  indexes ≥ 128 are truncated (A9). `set(iterable)` mishandles `None`
  (A10). Bulk dict ops walk hash-slot order instead of insertion order
  (A11). `1.0 in [1]` is False (A12). The 4th instance attribute needs an
  excore grow (A14).

---

## 3. Target architecture

### 3.1 Who owns what

| Work | Optimal owner | When that owner is disabled |
| --- | --- | --- |
| List, tuple, dict, set and bytearray operations: build, get, set, delete, append, extend, insert, pop, contains, len and truth, element iteration, unpack, concat and repeat, list→tuple, update and merge, every grow / rehash / shift | **CA** | excore (`excore_full`, trap 22 `FALLBACK`) |
| Dict probes and inserts for namespaces and attributes: globals and builtins load/store, instance `__dict__`, `tp_dict` MRO probes | **CA** services. pycore keeps the GIC, the MRO walk control and bound-method allocation | as above |
| String ops, number and string formatting, `repr`, bytes payload ops, int↔bytes conversion | **STRACC** | excore (`excore_full`) |
| Console output | a **pycore** store, or a STRACC sink-mode stream, to `CONSOLE_BASE` | never the excore. With STRACC off, only the *formatting* falls back |
| Garbage collection | GC engine | `GC_MODE`: off (bump allocation only) or excore software collector (optional, §12) |
| Code-object and global-lookup result caches | CODC, GIC | uncached pycore path |
| Python pycore does not implement | **excore** (trap 21 `EMULATE`) | fatal if no excore |

### 3.2 Rules that hold in every configuration

| # | Rule |
| --- | --- |
| R1 | The excore runs only while pycore is frozen and the CA is idle (container ready for every command). |
| R2 | In the final design only the CA mutates container internals. Every other unit either issues CA commands or waits for the CA to be idle. |
| R3 | The CA never writes the register file. pycore writes CA results into the RF when data is ready. |
| R4 | `heap_ptr_r` in pycore stays the only allocator. A CA allocation is reserved before data ready. Work after data ready never allocates and never raises. |
| R5 | Every condition that can raise is decided before data ready. If one fires, nothing has been committed. |
| R6 | Hash and equality have one specification: one SystemVerilog package plus one host model. Every implementation (CA, excore fallback, image builder, GC model) passes the same generated vectors. |
| R7 | Console writes are uncached and never duplicated, and they reach the device in program order. The target address is the per-process `CONSOLE_BASE` register. |
| R8 | `ACCEL_CFG` is loaded at boot and does not change during a run. Every configuration gives the same program results. |
| R9 | Container object addresses never move: growing relocates buffers only. A dict table moves only on an insert-driven grow, because the GC compiler-cleanup descriptor holds absolute `_PYC_G` slot addresses. Alternatively, that descriptor becomes base-relative (§6.11). |
| R10 | No unit writes the code region (`0x0100_0000+`) through the data path. L1I is not coherent with dmem writes. |

### 3.3 Picture

```text
             ┌──────────── pycore (bytecode hart) ────────────┐
 fetch ─ L1I │ decode/exec, CALL FSM, micro-sequencer         │
             │ ACCEL_CFG, CONSOLE_BASE, heap_ptr (allocator)  │
             └──┬───────────┬───────────────┬──────────────┬──┘
     cmd/opnd   │  dr/cr    │ STRACC cmds   │ GC run       │ trap_req/res
                ▼           │               ▼              ▼
          ┌──────────┐      │         ┌──────────┐   ┌───────────┐
          │    CA    │──────┘         │  STRACC  │   │  mailbox  │── excore (RV32)
          └────┬─────┘                └────┬─────┘   └───────────┘   min / full fw
               │ CA port + NB line port    │ core port               │ slot port
               ▼                           ▼                         ▼ (D3, §11)
          ┌───────────────────── L1D (arbiter) ─────────────────────┐
          └──────────────────────────┬──────────────────────────────┘
          IO window ◄── decoded before L1D: console channels (uncached)
                                     ▼
                              xbar ─ L2 ─ RAM
```

---

## 4. Startup configuration registers

### 4.1 Machine-configuration page

The boot record (`0x3E0`–`0x43F`) is full and the heap starts right after
it, so the configuration lives in the unused data-window hole above the
frame stack. The image builder writes it and `S_BOOT` reads it.

```text
0x00F0_9000  MCFG header    {version = 1, magic 'MCFG' = 0x4746434D}
0x00F0_9010  ACCEL_CFG      (§4.2)
0x00F0_9020  CONSOLE_BASE   reset value of the per-process console register (§7.3)
0x00F0_9030  ROM_ID         {variant: 0 = accel, 1 = soft; ROM build hash}
0x00F0_9040  FW_CAPS copy   written by pycore at boot, for software and reports
0x00F0_9050 – 0x00F0_9FFF   reserved, zero
```

If the magic is missing (`BOOT_EN=0` fixtures, old images), pycore uses the
defaults. In simulation `+ACCEL_CFG=<hex>` overrides the page; the PERF
line prints the effective value. `pycore/tools/encoding.py`,
`pycore_defs.svh`, `memory_hierarchy.md` and `code_loading.md` change
together, and `test_memory_map_mirror.py` gates them (memory-map lock).

### 4.2 `ACCEL_CFG` bits

```text
[0]    CA       1 = container accelerator; 0 = container commands go to the excore
[1]    STRACC   1 = string accelerator;    0 = string commands go to the excore
[3:2]  GC       0 = no collection (bump only), 1 = GC engine, 2 = excore collector, 3 = reserved
[4]    CODC     1 = code-object field cache; 0 = always miss
[5]    GIC      1 = global-lookup cache;     0 = always miss
[6]    CACHE    1 = L1/L2 on; 0 = pass-through (today's +CACHE_EN, now architectural)
[7]    STRICT   1 = halt at boot if a disabled unit has no fallback in FW_CAPS
[15:8] reserved, zero
```

The default matches today: everything on, and `GC = 0` until
[`gc.md`](../pycore/docs/gc.md) makes the collector the default. The
`+GC_EN` and `+CACHE_EN` plusargs stay as overrides for existing tests.

### 4.3 Boot sequence and capability check

1. At reset the excore firmware writes `FW_CAPS` into a new mailbox
   register and sets `FW_CAPS_VALID`. The bits are `[0]` EMULATE, `[1]`
   CA fallback, `[2]` STRACC fallback and `[3]` software GC; `[15:8]` hold
   the firmware ABI version and `[31:16]` the variant id.
2. `S_BOOT` reads the MCFG page and latches `accel_cfg_r` and
   `console_base_r`. If `EXCORE_PRESENT`, it waits up to 4,096 cycles for
   `FW_CAPS_VALID` and copies `FW_CAPS` into the page.
3. pycore halts with new fatal trap **23 `CONFIG`** if any of these holds:
   a unit is disabled and its fallback bit is missing; `GC = 2` without
   software GC; anything needs the excore and none is present; or the ABI
   version differs. `STRICT = 0` defers the failure to the first fallback
   trap (for bring-up).
4. The excore reads `ACCEL_CFG` from a read-only mailbox mirror
   (`MB_ACCEL_CFG`). It never reads the MCFG page, because it sits behind
   L2 and cannot see dirty L1D lines.

### 4.4 One routing function

Today 27 sites decide `EXCORE_EN && pycore_trap_recoverable(code)` with a
compile-time parameter (`pycore_cont_*.svh`, `pycore_call_fsm.svh`). They
become calls to one function in `pycore_defs.svh`:

```systemverilog
// LOCAL: the unit runs it. EXCORE: trap 21/22. FATAL: trap 23 or the old fatal code.
function automatic route_e pycore_route(input route_class_e cls,
                                        input logic [15:0] accel_cfg,
                                        input logic excore_present);
```

`EXCORE_EN` becomes a topology strap, `EXCORE_PRESENT`, which is 1 on
`pycore_excore_system` and 0 on `pycore_system`. Tests select a
configuration with plusargs and never rebuild Verilator. This lands
`cleanup_report.md` D1 on the way.

### 4.5 Software and test visibility

- A new builtin, `_bi_accel_cfg()`, returns `ACCEL_CFG | FW_CAPS << 16`
  as an INT, so benchmark harnesses can label their output.
- `hw_tests.toml` gains named profiles under `[accel.profiles]` (§12.1)
  and an optional per-test `accel = "<profile>"`. `hw_tests.py --accel`
  selects one profile or a sweep.

---

## 5. Firmware builds

### 5.1 Excore: `excore_min` and `excore_full`

Both are built from one source tree:

| Build | Contains | `FW_CAPS` |
| --- | --- | --- |
| `excore_min` | reset and `FW_CAPS`, a jump-table dispatch, and `EMULATE` handlers for unimplemented features (§10). No container, string or console code | EMULATE |
| `excore_full` | `excore_min`, plus a fallback handler for **every** CA command (§6.1) and **every** STRACC command (§8.1), plus the optional software GC (§12.4) | EMULATE, CA, STRACC (, GC) |

Until the CA lands (P3), `CA = 1` still means today's path: pycore's
container arms plus excore growth. Every profile therefore runs
`excore_full`, which carries today's growth handlers. `excore_min` becomes
the `all-on` firmware once the CA exists.

Layout: `excore/fw/entry/` (reset, dispatch, mailbox helpers),
`excore/fw/emulate/`, `excore/fw/fallback/ca/`,
`excore/fw/fallback/stracc/`, `excore/fw/lib/` (slot-port DMA and the
generated key spec, §6.9) and `excore/fw/gc_soft/`. The build writes
`build/excore_fw/{min,full}.hex`. Runs pick one with `+FW_HEX`; the
Makefile, the `hw_tests.py` default and the hardcoded path in
`pycore_exec.py` change together. Shared constants are generated from
`pycore_defs.svh` (`cleanup_report.md` C3) instead of copied as `.equ`.

### 5.2 pycore ROM: `rom_accel` and `rom_soft`

"Pycore firmware" here means the ROM Python builtins and native-method
bodies under `pycore_firmware/builtins/`. Both ROMs expose the same API
and are correct under every `ACCEL_CFG`.

- **`rom_accel`** bodies use accelerator-native operations:
  - `list.append` is seeded as a `LIST_APPEND` opcode body, the way
    `set.add` is seeded as `SET_ADD` today.
  - `list.extend`, `list()` and `tuple()` issue one CA bulk command when
    the source is CA-iterable.
  - `print`, `str`, `repr`, `hex`, `oct` and `bin` call STRACC natives.
- **`rom_soft`** bodies use only the base instruction set: Python loops,
  per-element operations and digit-by-digit formatting.

The hardware still routes their primitive operations through whatever
`ACCEL_CFG` enables. `rom_soft` separates the gain of the native-builtin
layer from the gain of the accelerator hardware, and it is the reference
behaviour for the natives.

`image_from_source.py --rom accel|soft` picks bodies (a `_soft.py` sibling
or a `# rom: soft` marker) and records the choice in `ROM_ID`.
`rom_accel` is the default.

This is how this plan reads "two versions of the pycore firmware"; it is
decision D1 in §15.

### 5.3 Excore resources and toolchain

The current firmware is 9,236 bytes, 56% of the 16 KB IMEM. Scratch is
1 KB with no stack. The vendored hart computes BLT/BGE wrongly on signed
overflow, executes MUL as ADD, and treats SYSTEM and unknown instructions
as silent NOPs. The assembler has no byte or halfword access, no M
extension, no `.include` / `.macro` / `.ifdef`, and a forward-reference
`li` sizing bug.

`excore_full` does not fit that. It needs about 55 CA commands and about
27 STRACC commands, including string algorithms and float formatting.
Required:

- Plumb `IMEM_WORDS` and `SCRATCH_WORDS` through `pycore_excore_system`:
  64 KB IMEM for `excore_full`, 16 KB scratch with a real stack, and a
  read-only data path for tables.
- Fix BLT/BGE. Implement the M extension or fault on it, and fault on
  unknown or SYSTEM instructions (A17).
- Firmware language, decision D2. The default is **C with a pinned RV32I
  GCC in the Docker image**, keeping assembly only for the trap entry. The
  alternative is to extend `asm_rv32.py` with byte ops, `.include`,
  `.macro`, `.ifdef` and branch relaxation, and fix the `li` bug (A18).
  Writing all CA and STRACC fallbacks in hand assembly is not practical.

---

## 6. Container accelerator

### 6.1 Scope and commands

The CA replaces the container arms of `S_CONTAINER`, the container pieces
of the CALL FSM, and excore traps 9–14 and 19–20.

| Group | Commands (v1) | Replaces |
| --- | --- | --- |
| List | `L_NEW(n)` (operands streamed), `L_GET`, `L_SET`, `L_DEL` (any index), `L_APPEND`, `L_EXTEND`, `L_INSERT`, `L_POP`, `L_CLEAR`, `L_LEN`, `L_CONTAINS`, `L_TO_TUPLE`, `SEQ_CONCAT`, `SEQ_REPEAT`; `L_SLICE` later | `CONT_BUILD_LIST`, `SUBSCR_LIST`, `STORE_LIST`, `DELETE_LIST`, `LIST_APPEND`, `LIST_EXTEND`, `LIST_TO_TUPLE`, `SEQ_REPEAT`, `SEQ_CONCAT`, `CONTAINS_LIST`; traps 9, 10, 12 |
| Tuple | `T_NEW(n)`, `T_GET`, `T_CONTAINS` (and the `SEQ_*` commands) | `BUILD_TUPLE`, `SUBSCR_TUPLE`, `CONTAINS_TUPLE`; the CALL `*args` tuple |
| Dict | `D_NEW(n)`, `D_GET`, `D_GET_DEFAULT`, `D_SET`, `D_DEL`, `D_POP`, `D_CONTAINS`, `D_LEN`, `D_UPDATE`, `D_MERGE` | `BUILD_MAP`, `SUBSCR` / `STORE` / `DELETE` / `CONTAINS_DICT`, `MAP_ADD`, bulk arms; traps 11, 19, 20; the CALL `**kwargs` dict; instance-dict creation |
| Set | `S_NEW(n)`, `S_NEW_FROM(src)`, `S_ADD`, `S_CONTAINS`, `S_UPDATE`, `S_LEN`; `S_DISCARD` later | `BUILD_SET`, `SET_ADD`, `CONTAINS_SET`, `SET_UPDATE`, `BI_SET`; traps 13, 14 |
| Bytearray | `BA_NEW(n \| src)`, `BA_GET`, `BA_SET`, `BA_DEL`, `BA_APPEND`, `BA_EXTEND`, `BA_INSERT`, `BA_POP`, `BA_LEN`, `BA_CONTAINS` | new (§9) |
| Iteration, unpack | `IT_SNAPSHOT` (dict/set `GET_ITER`), `IT_NEXT`, `UNPACK(n)` (element stream), `UNPACK_EX` | the memory half of `GET_ITER`, `FOR_ITER`, `UNPACK_SEQ`, `UNPACK_EX`; `CALL_FUNCTION_EX` expand |
| Namespaces | `NS_LOAD(globals, builtins, name)`, `NS_STORE(dict, name, value)` | dict probes of `LOAD_GLOBAL` / `LOAD_NAME`, `STORE_NAME` / `STORE_GLOBAL` |
| Attributes | `A_LOAD(obj, name)` walks the instance dict, then up to 8 `tp_dict`s, and returns the value plus where it was found; `A_STORE`, `A_DEL` | dict probes of `LOAD_ATTR` / `STORE_ATTR` / `DELETE_ATTR` |
| Call support | `KW_LOOKUP` (binder kwargs and kwdefaults probes), `LEN` / `TRUTH` | binder probes, `BI_LEN`, the container half of `TO_BOOL` |

The remaining `S_CONTAINER` arms go to three places:

- **Stay in pycore**, in a small micro-sequencer: `LOAD_CONST`, the
  RF-only pair ops (`LFB_PAIR`, `SWAP`, `SFLF`, `SFSF`, `LFAC`), exception
  ops, closure ops, object-head reads, MRO control and bound-method
  allocation.
- **Move to STRACC**: `FORMAT_SIMPLE`, `CONVERT_VALUE`, `BUILD_STRING`.
- **Delete**: `CONT_SUBSCR_STR` and `CONT_SLICE_STR`, which are
  unreachable because STRACC routes first.

Each command is one entry in a single opcode table,
`pycore/rtl/pycore_ca_defs.svh`. Python, C and assembly headers are
generated from it.

### 6.2 Data ready and container ready

**Data ready (DR)** for a command means all four of these hold:
1. Every value the instruction produces is final and has been delivered.
2. Every condition that can raise has been decided. If one fired, nothing
   is committed.
3. Every allocation the command needs is reserved.
4. Every operand has been captured, so pycore may pop or overwrite those
   RF slots.

After DR, pycore retires the instruction.

**Container ready (CR)** means all three of these hold:
1. Every memory write of the command has been accepted by L1D, or by L2
   for a write-around line.
2. Every container the command touched is self-consistent in memory:
   header, meta, pointers, order sidecar and tags agree. The GC, the
   excore or any reader sees a valid object.
3. The command's busy-container entries are released.

Invariants:
- CR follows DR. CR cannot fail; a hardware fault after DR is a fatal
  machine check.
- Commands that touch the same container complete in issue order.
- Before DR a command has committed nothing. It can be squashed by
  dropping it, which a speculating pipeline will need.

### 6.3 Interface

All channels use valid/ready handshakes. Stage A uses one outstanding
command, but the fields already carry ids so later stages need no
format change.

```text
cmd    pycore→CA  {id[3:0], op[6:0], mod[7:0], pc[31:0], n_opnd[1:0], opnd[0..2] (132 b), n_stream[15:0]}
opnd   pycore→CA  stream of 132-bit entries when n_stream > 0 (BUILD_* n, BUILD_MAP 2n)
alloc  CA→pycore  {bytes, line_align}  →  reply {ok, base} | {short, need_bytes}
dr     CA→pycore  {id, status: OK | RAISE(exc_code) | SHORT_HEAP(need) | FALLBACK, n_res, res[0..1]}
res    CA→pycore  element stream (UNPACK n, bulk IT_NEXT)
cr     CA→pycore  {id} in issue order; ca_idle level
ctl    pycore→CA  drain_req (fence); desc_flush (§6.10)
bct    pycore→CA  query {addr} → {busy}                      (Stage B)
gic    CA→pycore  gic_flush pulse (namespace-dict write, §6.11)
mem    CA↔L1D     CA port + non-blocking line port (§6.8)
```

The descriptor `{op, mod, pc, opnd[], stream}` is also what the excore
fallback receives (§6.14). The fallback is therefore a different consumer
of the same command, not a second encoding.

### 6.4 Operands and results

- pycore reads RF operands as it does today: one per cycle through the
  rs1 override. It streams them to the CA. For `BUILD_*` n, the CA writes
  each element as it arrives, so it needs no large operand buffer.
- At DR, pycore writes the results through its single RF write port.
  `UNPACK(n)` results arrive as a stream, and pycore pushes one per cycle.
- The RF ring spills and fills on CALL and RETURN, and `tos` moves after
  retire. That is why the CA never holds an RF address (R3). In Stage C, a
  pending result carries a destination tag, and CALL, RETURN, spill and
  exception unwind wait until no DR is pending.

### 6.5 Allocation and the GC

- pycore's allocator (`heap_ptr_r`, `heap_limit_r`, and the GC run logic)
  stays the only allocator. The CA uses the `alloc` channel only before
  DR, while pycore waits.
- If the heap is short, the CA abandons the command with nothing
  committed and returns `SHORT_HEAP(need)`. pycore takes
  `GC_ABORT_COMMON` and re-dispatches, exactly like excore `NEED_HEAP`
  today. GC invariant 4 holds.
- `gc_start` and `S_GC_ENTER` require `ca_idle`. After CR, the CA holds no
  pointers, so it adds no GC roots.
- The copy source of a grow stays reachable from its container until the
  CA publishes the new buffer pointer. Publish is the last write before
  CR, and the GC waits for CR.
- CA heap writes must feed `heap_zero_r`, the `gc_pyc_dirty_r` watch and
  the GC-INV write checks. All three snoop only the core dmem port today.
  The plan replaces that with one heap-write event bus fed by every master
  (A19 in §11).
- The CA initializes every slot the GC traces: empty dict and set slots
  get tag 0, and the upper bits of tag slots are zero. It writes content
  lines directly and never uses zero-line writes, which bypass both caches
  to DRAM (§6.8).
- Every CA allocation path gets a key in `tools/gc_sites.py` and is
  covered by the G-gates. `gc_model.py` learns the new object kinds (§9).

### 6.6 Where data ready falls

| Class | Commands | DR at | Work after DR |
| --- | --- | --- | --- |
| E0: no result, only `MemoryError` can happen | `L_APPEND`, `S_ADD`, `D_SET`, `NS_STORE`, `A_STORE` (the CA reads the object head and instance-dict field itself; a non-instance receiver raises `TypeError` before DR) | after the hashability check, the header (from the descriptor cache, §6.10) and any reservation a grow needs | insert, order-sidecar append, grow + rehash + copy |
| E1: a decision, then bookkeeping | `L_SET`, `L_DEL`, `L_POP` (result: the value), `D_DEL`, `A_DEL`, `D_POP` | after the bounds or presence decision, and the value read for pop | list shift; tombstone plus order-sidecar scan and shift |
| E2: a handle, then filling | `*_NEW`, `L_TO_TUPLE`, `SEQ_*`, `UNPACK_EX`'s list | after reservation and operand capture. For dicts and sets, also each key's hashability, checked as it streams in | element writes, probes and inserts, copies |
| E3: the result is the work | `L_GET`, `T_GET`, `D_GET`, `*_CONTAINS`, `NS_LOAD`, `A_LOAD`, `IT_NEXT`, `UNPACK`, `LEN`, `TRUTH` | when the value is known | none (CR = DR) |
| E4: the decision needs the whole walk | `S_UPDATE` / `D_UPDATE` (an unhashable element raises mid-way; CPython also leaves a partial update), `D_MERGE` (a duplicate key raises `TypeError`) | after the walk | none |

E0 with a grow: whether a new key needs a grow depends on whether the key
is new. When the header says the next *new* key would cross the
threshold, DR waits for the probe. Otherwise DR does not wait. Lists know
from the header alone (`len == cap`).

### 6.7 Hazards, in stages

| Stage | pycore behaviour | CA | Purpose |
| --- | --- | --- | --- |
| **A0** | waits for CR (DR = CR) | one command | bring-up: replaces `S_CONTAINER` and the excore with identical semantics |
| **A1** | retires at DR and keeps executing. An instruction that *touches container memory* (Appendix D) waits for `ca_idle` | one command; background CR | overlap of bookkeeping with non-container work |
| **B** | the address-precise busy-container table (BCT) replaces the coarse predicate, so only real conflicts stall | 4-deep command queue. A lookup engine serves read commands on non-busy containers while the background engine finishes another's CR | real overlap between independent containers |
| **C** | pipelined pycore with an RF scoreboard and tagged, out-of-order DR. Commands are squashed before DR on redirect or exception | several engines | the long-term target; this plan only fixes the interfaces for it |

BCT entry: `{valid, object base, mode (write | read-lock), extra ranges:
old buffer and new buffer}`. A write entry blocks every other access to
that container. A read lock (the source of a copy, extend or update)
blocks writers only. Container object addresses are stable (R9), so the
key is the object base `value[31:0]`, with the kind and contamination
bits masked off.

### 6.8 Memory attachment and cache policy

The CA attaches **on the pycore side of L1D**. One coherence point means
no flushes and no range-invalidate operations.

1. **Port.** A logical CA port goes into a new L1D arbiter beside the core
   master mux. The core has priority. A starvation counter grants the CA a
   slot after N cycles of waiting. pycore spends most cycles in fetch,
   decode and execute, which do not use L1D, so background work finds free
   cycles. A true dual-port L1D is decision D13; the default is an
   arbitrated single port.
2. **Line reads** use the L1D non-blocking port (4 fills in flight, 15
   cycles on an L2 hit, against 53 for an ordinary miss). Both tops tie
   `nb_ack`, `nb_line` and `nb_id` off today; they must be wired. Size a
   CA response buffer for `RQ_DEPTH` lines, because NB responses have no
   backpressure. Ordinary misses still wait for NB fills to drain.
3. **Bulk traffic does not pollute L1D.** L1D has 128 lines; a 64-slot
   dict table is half of it. Copies, rehashes and order shifts mark their
   accesses *streaming*:
   - A read miss returns the line without installing it.
   - A full-line write that misses goes around L1D to L2. This
     generalizes the existing `ZERO_LINE_BYPASS` path to non-zero lines.
   - Hits update in place.

   The container header and the next-append line install normally.
4. **No zero-line writes** for CA buffers; write the content lines. Zero
   lines bypass both caches to DRAM, so the next read costs a full DRAM
   round trip.
5. **Address guard.** Every CA address must be below `DATA_LIMIT` and
   outside the GC metadata region (`0xF8_0000+`). A violation is a fatal
   machine check.
6. **Acceptance.** After a 4 KB rehash with streaming on, the core's
   frame and RF-spill hit rate drops by less than 5 points (de-duplicated
   counters, §11).

### 6.9 Hash and equality: one specification

- `pycore/rtl/pycore_keyspec.svh` holds hash, rich equality,
  hashability, the "needs a payload compare" predicate, and element
  equality for `in`. The CA uses it, as does anything left in pycore.
- `pycore/tools/keyspec.py` is the host model. It takes over
  `encoding.dict_key_hash` and is used by `heap_image.py`, the image
  builder and `gc_model.py`.
- `tools/gen_key_vectors.py` generates hash vectors and pairwise equality
  vectors. They cover INT/BOOL/FLOAT cross-equality, NaN, ±0.0, `-1 → -2`,
  SHORT and LONG strings of every kind, BYTES vs STR (equal hash, never
  equal), OBJECT identity and None. A unit testbench, the excore fallback
  testbench and host tests all check them.
- Semantics fixed on the way:
  - `in` on lists and tuples uses rich equality (A12), and tuple equality
    is element-wise.
  - Tuple keys become hashable (CPython tuple hash) in CA v2.
  - OBJECT keys keep identity semantics. A class that defines `__eq__`
    or `__hash__` gets a type flag at image build. Its instances as keys
    go to `EMULATE` until a protocol path exists.
- **LONG_STR compare lane.** The CA has its own payload comparator. It
  streams both payloads, 16 B per cycle, over its own port; tier 2 has
  already proven the kind and length equal. It does not borrow STRACC, so
  background inserts never race pycore's string instructions.

### 6.10 Descriptor cache

An 8-entry cache maps an object address to its header fields:
`{cap, len, ob_item}` for a list, or `{slots, used, version, order_len,
table_ptr, order_ptr}` for a dict. Bounds checks, grow decisions,
`len()`, truth and iterator snapshots can then reach DR without a memory
read. It is write-through.

It is flushed:
- at the end of a GC collection;
- on excore `trap_res`;
- on `_bi_heap_release`;
- whenever a non-CA master writes a container header. Until the migration
  removes those writers (STRACC split and partition, which build lists),
  the CA snoops L1D writes.

### 6.11 Coherence with the other units

| Event | CA action |
| --- | --- |
| `S_GC_ENTER` | drain (CR for all); flush the descriptor cache after the collection |
| `trap_req` (any excore trap) | drain before the handoff; flush the descriptor cache on `trap_res` |
| `_bi_heap_release`, `_bi_code_new` / `blit` / `patch` / `release` | drain; flush the descriptor cache on release |
| STRACC command with a container operand (join, repr walk) | A1: drain. B: BCT check |
| CA write to a dict at `globals_base_r` or `builtins_base_r` | pulse `gic_flush` **at DR**, not at CR, because a `LOAD_GLOBAL` that hits the GIC does not wait for the CA (Appendix D). This also fixes the existing GIC bug (A7) for every dict-writing path |
| CA never writes code objects or `co_consts` | CODC unaffected |
| halt or program end | drain, so results and memory dumps are final |

The `_PYC_G` cleanup descriptor stores absolute table-slot addresses
(`image_from_source.py`). The CA must not relocate that table except on an
insert-driven grow. Better: make the descriptor base-relative as part of
this work, which removes the constraint.

### 6.12 Inside the CA

- **Front end**: command queue, operand intake, the DR/CR sequencer, the
  BCT, raise-code mapping.
- **Descriptor cache** (§6.10).
- **Probe engine**: key spec, the LONG_STR compare lane, tombstone
  handling.
- **Insert/delete engine**: dict order-sidecar append and shift, and
  `version` bumps.
- **Copy/move engine**: a memmove at 32 B element granularity, or byte
  granularity for bytearray, with line-granular streaming above a
  threshold. It serves list grow, extend, insert and delete shift; concat
  and repeat; list→tuple; and the order shift.
- **Rehash engine**: scans the old table and inserts into the new one.
  This reuses `pycore_cont_bulk.svh`'s resize decision, rehash scanner and
  shared probe/insert sub-FSM.
- **Walk service**: elements in insertion order for `IT_NEXT`, `UNPACK`,
  STRACC join and repr, the `CALL_FUNCTION_EX` expand and the kwargs
  binder.
- **Memory interface**: the arbiter port, the NB line port, a write
  buffer and the streaming attributes.

### 6.13 Semantics the CA ships with

The rewrite fixes these (Appendix A):
- 32-bit element indexes; `in` no longer hangs (A8).
- Full-width name indexes in pycore's name reads (A9).
- `None` in `set()` (A10).
- Insertion-order walks for bulk sources (A11).
- Rich equality for `in` (A12).
- No reliance on the contamination bit, which is retired (A22).
- Counts beyond 127 for `BUILD_*`, `UNPACK*`, `LIST_TO_TUPLE` and `set()`
  (A23).
- **Negative indexes** for list, tuple and bytearray, wrapped as in
  CPython. Today every negative index is a `MEM_FAULT`.
- **Instance dicts presized** from a per-class attribute-count hint the
  image builder computes, with a minimum of 8 slots. Today the 4th
  attribute costs an excore grow (A14).
- `L_EXTEND` accepts list, tuple, dict, set, bytes, bytearray and range.
  Other iterables go through a ROM loop.

The CA returns raise codes for `KeyError`, `IndexError`, `TypeError`,
`ValueError` and `RuntimeError` (dict changed during iteration). Until
`master_plan.md` T6 lands, pycore maps them to today's fatal codes. After
T6, they raise seeded exception objects through `CONT_RAISE`, the way GC
`MemoryError` does now.

### 6.14 When `CA = 0`

- **Transitional (phases P3 to P7).** `CA = 0` selects the *legacy path*:
  today's `S_CONTAINER` arms plus excore growth. The repo stays green, and
  today's behaviour remains measurable.
- **Final (phase P8).** The legacy arms are deleted. `CA = 0` sends every
  CA command to `excore_full` as trap 22 `FALLBACK` with
  `{unit = CA, op}` and the same descriptor.
  - Operands beyond the 4 mailbox entries, and streamed operands, are
    staged by pycore in the CA staging page (`0x00F0_B000`–`0x00F0_EFFF`,
    16 KB) before the trap.
  - Result streams larger than 2 entries come back through that page.
- The fallback must match the CA exactly: the same key spec (R6), the
  same placement, alignment and growth policy, and the same
  insertion-order walks. Heap dumps then compare across configurations
  (`gc_model.py`), which is a strong differential check.
- Decision D4: keeping the legacy arms permanently as a second "off"
  path would cost area and a duplicate implementation. The default is to
  delete them, as asked.

### 6.15 Area, timing, synthesizability

- Use the GC engine's flow (`tools/gc_timing.sh`, the logic-depth script
  and an ECP5 post-placement estimate) as a gate for the CA. Record area
  and Fmax in the as-built doc.
- Rules: iterative engines; small CAMs for the BCT and descriptor cache;
  no `real` arithmetic; no combinational divide or modulo loops.
- Two existing violations move off the critical path in this work:
  - `BI_MAX` uses `real` and `$bitstoreal` (`pycore_call_fsm.svh`).
  - `pycore_int_to_short_str` is a combinational loop of fifteen 64-bit
    divides by 10. §8 replaces it with an iterative STRACC engine.

---

## 7. Console and `print`

### 7.1 IO window

- **Address.** `PYCORE_IO_BASE = 0x0200_0000`, 64 KB. It sits outside the
  data window and the code region (`0x0100_0000`–`0x0110_FFFF`), so no
  existing address changes meaning.
- **Decode.** `pycore_mem_hier` decodes it **before L1D** on both tops,
  with the cache on or off. Accesses never allocate in L1D or L2. They are
  posted, kept in program order and acknowledged.
- **Width and faults.** Writes are 16 B with byte strobes; reads are
  16 B. An unmapped IO address faults.
- **Prerequisite.** The duplicate-request fix (§11, A6) lands first,
  otherwise every console byte prints twice.

### 7.2 Console device (`pycore_console.sv`)

There are 16 channels at `IO_BASE + ch × 0x100`. Channel 0 is stdout and
channel 1 is stderr. Each channel has four registers:

| Offset | Register | Behaviour |
| --- | --- | --- |
| `+0x00` | `TX_STR` | write 16 B laid out as a `SHORT_STR` value (`{size[127:124], bytes…}`); emits `size` bytes. A `SHORT_STR` register value goes out in one store, unconverted |
| `+0x10` | `TX_RAW` | write 16 B with byte strobes; emits the strobed bytes in address order. pycore's copy loop and STRACC `SA_EMIT` stream payloads here |
| `+0x20` | `MARK` | write an id; the testbench prints a `PHASE_MARK` line (out of band) |
| `+0x30` | `STATUS` | read `{space, overflow}`, for real hardware with a FIFO |

The stream is UTF-8. In-band bytes `0x01`–`0x07` (`PHASE_MARK` with
`+PHASE_MARKS=1`) and the `0x0e` / `0x0f` metadata brackets keep their
current meaning, so `pycore_exec.py`, `gc_gates.py` and the stdout tests
keep working. `tb_container` captures channel 0 to `+STDOUT_PATH` on both
tops; today only the two-core top can print.

### 7.3 `CONSOLE_BASE`: a per-process register

`console_base_r` is part of the process context, like `globals_base_r`.
For now it is constant from the MCFG page (default `IO_BASE`, channel 0).
When an OS arrives:
- Each process gets its own channel, or its own device page.
- The OS saves and restores the register on a switch, after draining the
  CA.
- The host or testbench demultiplexes channels into per-process streams.

A cacheable ring buffer per process is a different device contract
(pointer and doorbell). If that model is chosen later, it is a new
channel type, not a change to these registers.

### 7.4 Who writes

- **`_bi_write(s)`** (new native, `BI_WRITE`). The console write is always
  a pycore store, whatever `ACCEL_CFG` says:
  - A `SHORT_STR` is one 16 B store to `TX_STR`, issued from the CALL FSM.
  - A kind-1 `LONG_STR` or a `BYTES` payload is a CALL-FSM copy loop:
    16 B load, then a 16 B store to `TX_RAW` with byte strobes for the
    tail.
  - Kind-2 and kind-4 strings need UTF-8 transcoding. That is STRACC
    `SA_EMIT`, which streams straight to `TX_RAW`. With `STRACC = 0`, the
    excore fallback returns the UTF-8 encoding as a `BYTES` object, and
    pycore streams that with the copy loop.
- **`_bi_print(x)`** formats a primitive straight into the console
  (STRACC sink mode, §8.2) and returns True. Primitives are str, int,
  float, bool, None and bytes; nothing is allocated, so there is no
  `NEED_HEAP`. For any other value it returns False without side effects.
  The name stays, so the `pycore_exec.py` harness's
  `_bi_print("\x0e")` calls keep working.
- **ROM `print`** (`rom_accel`):

  ```python
  def print(*args, sep=" ", end="\n"):
      if sep is None:
          sep = " "
      if end is None:
          end = "\n"
      n = len(args)
      i = 0
      while i < n:
          if i > 0:
              _bi_write(sep)
          if not _bi_print(args[i]):
              _bi_write(str(args[i]))     # containers and objects, §8.4–8.5
          i = i + 1
      _bi_write(end)
  ```

  `rom_soft` always calls `_bi_write(str(a))`. `file=` (channel 1 for
  `sys.stderr`) and `flush=` come later.

The excore `BI_PRINT` handler leaves the console path. Excore
`CONSOLE_TX` stays as a firmware debug port, logged to a separate
`+EXCORE_LOG` file. The `CONSOLE_TX at 0xF0` memory-map lock entry is
reworded to match.

---

## 8. STRACC: conversions, `str()`, `repr()`, f-strings

### 8.1 New commands

STRACC uses 20 of 64 opcodes (`PY_SA_*`). Added:

| Command | Does | Replaces |
| --- | --- | --- |
| `SA_FMT_INT` | any 64-bit int to text, in radix 2/8/10/16, with optional `0b`/`0o`/`0x` prefix and sign. Iterative (target ≥ 1 digit per cycle) | `pycore_int_to_short_str` (combinational, ≤ 15 chars), the ROM `hex` / `oct` / `bin` / `str` digit loops, A4 |
| `SA_FMT_FLOAT` | CPython `repr(float)`: shortest round-trip digits (Ryū with the small-table variant, about 1 KB of ROM, using the existing 64×64 multiplier iteratively). CPython layout rules: fixed when `1e-4 ≤ abs(x) < 1e16`, otherwise `e±XX`; `.0` on integral values; `inf`, `-inf`, `nan`, `-0.0` | today's TYPE trap on float formatting |
| `SA_REPR_STR` | quoting (single quotes unless the text has `'` and no `"`) and escapes (`\\ \' \n \r \t`, `\xhh`, `\uhhhh`, `\Uhhhhhhhh`). Printability uses the Latin-1 LUT; strings with code points above U+00FF return `FALLBACK` until a Unicode printable table is added (D11) | |
| `SA_REPR_BYTES` | `b'…'` with the same quote rule, and `\xhh` for non-printable bytes | |
| `SA_EMIT` | stream a string or bytes payload to a console channel; kind 2/4 → UTF-8 | |
| `SA_BUILD_STRING(n)` | concatenate n pieces, any mix of `SHORT_STR` and `LONG_STR` | `BUILD_STRING` (≤ 15 bytes total today) |
| `SA_INT_TO_BYTES`, `SA_BYTES_TO_INT` | §9.4 | |

Results with kind 1 and ≤ 15 characters are `SHORT_STR`, which keeps the
canonical invariant.

### 8.2 Sink mode

Every `SA_FMT_*`, `SA_REPR_*` and copy command can target the console
channel at `CONSOLE_BASE` instead of the heap. A print of a 20-digit int
then allocates nothing.

### 8.3 `str()` and `repr()` dispatch

The `str` type's hardware path becomes a dispatcher:

| Value | `str(x)` / `repr(x)` |
| --- | --- |
| str | `str`: identity; `repr`: `SA_REPR_STR` |
| int | `SA_FMT_INT` |
| float | `SA_FMT_FLOAT` |
| bool, None | constants |
| bytes | `SA_REPR_BYTES` |
| complex | `(re+imj)` from two floats, later |
| anything else | ROM `_str_slow(x)` / `_repr_slow(x)` (§8.4–8.5) |

`repr` becomes a seeded builtin with the same dispatch. `ascii` follows
from it.

### 8.4 Containers

A ROM walker (`rom_accel` and `rom_soft` alike) builds container text
from CA iteration and STRACC join:

- list: `[a, b]`; tuple: `()`, `(a,)`, `(a, b)`.
- dict: `{k: v}` in insertion order.
- set: `set()` or `{a, b}`; bytearray: `bytearray(b'…')`.
- range: `range(a, b[, c])`.
- Elements use `repr`. Self-reference prints `[...]` or `{...}`, using an
  id stack of the objects being printed.

Set display order follows PyCore's probe order, which can differ from
CPython for colliding hashes. Tests sort, or print sets that do not
collide. The hardware fast path (STRACC walks a flat list of primitives
through the CA walk service) is a later optimisation.

### 8.5 Objects: "call the string function"

`str(obj)` resolves `__str__` through `A_LOAD` on the type's MRO and makes
a protocol call, using the same machinery as `__len__`, `__iter__` and
`__next__` today. If `__str__` is absent it uses `__repr__`. If that is
absent too, it uses CPython's default text:

| Object | Default text |
| --- | --- |
| instance | `<__main__.C object at 0x…>` |
| class | `<class '__main__.C'>` |
| function | `<function f at 0x…>` |
| builtin | `<built-in function len>` |

Exceptions follow CPython: `str(e)` from `args`, and `repr(e)` as
`ValueError('x')`. The differential harness normalizes `0x[0-9a-f]+`,
because addresses differ from CPython.

### 8.6 f-strings

- `FORMAT_SIMPLE` uses the §8.3 dispatch, so `f"{obj}"` works for every
  type.
- `CONVERT_VALUE` handles `!s`, `!r` and `!a`.
- `BUILD_STRING` uses `SA_BUILD_STRING`.
- `FORMAT_WITH_SPEC` goes to `EMULATE` (`excore_min`) first. A STRACC
  format-spec engine (fill, align, sign, width, precision and
  `d x o b f e g %`) is a later item.

### 8.7 When `STRACC = 0`

Every STRACC command becomes trap 22 `FALLBACK` with `{unit = STRACC,
op}`, served by `excore_full`. The CA's LONG_STR compare lane belongs to
the CA, so dict lookups do not depend on STRACC being on.

Sink mode has no fallback, because the excore never writes the console.
With `STRACC = 0`, `_bi_print(x)` formats through the fallback into a heap
string, then writes it the way `_bi_write` does (§7.4).

---

## 9. `bytes`, `bytearray`, `int.from_bytes`, `int.to_bytes`

Today the linter rejects `bytes` constants (`Unsupported constant b'ab'`).
The image builder cannot serialize them, the on-device lexer has no `b''`,
the GC treats `TAG_BYTES` as reserved, and the three builtins reach the
excore and come back `FATAL`.

### 9.1 Representation

- **`bytes`** is tag `1100`. Its handle uses the `LONG_STR` layout with
  `kind = 1`: `addr[31:0]`, `len` in `[63:32]`, the FNV-1a hash in
  `[95:64]` and `nbytes` in `[119:96]`. The object is a 16 B header plus
  payload. There is no inline short form, because only one tag value is
  available; `b''` is a 16 B header. The GC traces it like `LONG_STR`
  (extent `16 + pad16(n)`, no children). `TAG_BYTES` leaves the reserved
  set in `pycore_gc.sv` and `gc_model.py`.
- **Hash and equality.** `hash(b'abc') == hash('abc')`, as in CPython,
  but `bytes` never equals `str`. The key spec (§6.9) encodes both.
- **`bytearray`** is `MUT_COLLEC` kind 4. By default (D8) its object uses
  the compact list layout: `{capacity, length}` at `+0` and `{0, buf}` at
  `+16`. The CA's list engines then serve it with a byte stride. The GC
  gets a `K_BYTEARRAY` kind (32 B object plus a capacity-byte buffer that
  is marked, not scanned), and `gc_model.py` matches. The other option is
  to keep the 128 B `OBK_BYTEARRAY` object the GC already traces. That
  needs no GC change, but the CA could not reuse the list engines.

### 9.2 Operations and owners

| Operation | Owner |
| --- | --- |
| `bytes(n)`, `bytes(iterable of ints)`, `bytes(bytes)`; `bytearray()`, `bytearray(n \| iterable \| bytes)` | CA (allocate, fill, range-check 0..255 → `ValueError`) |
| `len`; bytes index → int (negatives wrap); iteration yields ints | handle / STRACC `SA_CHAR_AT` / a new `ITER` kind for bytes |
| slicing, `+`, `*`, `==` and ordering, `in` (an int or a sub-bytes), `hash` (bytes only; bytearray → `TypeError`) | STRACC (`SA_SLICE`, `SA_CONCAT`, `SA_REPEAT`, `SA_CMP`, `SA_SEARCH`, `SA_HASH`) with a BYTES result tag |
| bytearray `[i] = v`, `del`, `append`, `extend`, `insert`, `pop`, `clear` | CA (`BA_*`) |
| `bytes.hex()`, `bytes.decode()` (UTF-8 / ASCII / Latin-1), `str.encode()` | STRACC; later items |
| `repr`, printing | `SA_REPR_BYTES` |

### 9.3 Method calls on `int`

- `n.to_bytes(...)` type-traps today in `LOAD_ATTR` on an INT receiver.
  `LOAD_ATTR` on a primitive (INT, FLOAT, STR, BYTES) must resolve
  through that builtin type's `tp_dict`. `int.from_bytes(...)` resolves
  on the `int` type object, as it does today.
- `OBK_BUILTIN` calls are positional-only in the CALL FSM. The excore
  marshal also drops the middle argument and keyword names (A20). So both
  methods become ROM wrappers that bind keywords as ordinary Python, then
  call positional natives:

  ```python
  def to_bytes(self, length=1, byteorder="big", *, signed=False):
      return _bi_int_to_bytes(self, length, _byteorder(byteorder), signed)

  def from_bytes(bytes_obj, byteorder="big", *, signed=False):
      return _bi_bytes_to_int(bytes_obj, _byteorder(byteorder), signed)
  ```

### 9.4 Conversion commands (STRACC)

- **`SA_INT_TO_BYTES(n, length, little, signed)`** writes `length` bytes.
  Lengths above 8 are sign- or zero-extended. A value that does not fit
  raises `OverflowError`; a negative value with `signed=False` raises
  `OverflowError` too.
- **`SA_BYTES_TO_INT(b, little, signed)`** reads up to the full length. A
  result outside int64 raises `OverflowError`. This is a documented
  deviation: CPython returns a big int, and PyCore's `int` is 64-bit.
- `byteorder` other than `"little"` or `"big"` raises `ValueError`.
- `OverflowError` is seeded as a type (T5-B in `master_plan.md`).

### 9.5 Tooling

- `pycore.json` and the linter accept `bytes` constants.
- `image_from_source.py` and `heap_image.py` serialize them.
- The on-device lexer and parser learn `b''`; this is a compiler-track
  item (`compiler.md`). Until then, `compile()` of `b''` is a
  `SyntaxError`.
- `tags.md`, `object_model.md` and `bytecode_support.md` are updated.

---

## 10. The excore as emulator of unimplemented Python

### 10.1 What reaches it

Today unimplemented Python never reaches the excore:
- Undecoded opcodes halt with `ILLEGAL_OPCODE` (5). Examples:
  `BUILD_SLICE`, `STORE_SLICE`, `FORMAT_WITH_SPEC`, `GET_LEN`,
  `DELETE_GLOBAL`, `DELETE_NAME`, `CALL_INTRINSIC_2`, `MATCH_*`,
  `LOAD_SPECIAL`, `IMPORT_*`.
- About 153 container `TYPE` sites and about 69 `CALL_FILTER` sites use
  one code for both "Python error" and "not built".

New:

1. **Trap 21 `EMULATE`**, recoverable, with a reason register
   `MB_REASON = {class[3:0], detail[27:0]}`. The classes are `OPCODE`,
   `TYPE_COMBO`, `CALL_SHAPE`, `BUILTIN(id)` and `FEATURE(id)`.
   - It can be raised from decode/`S_EXEC`, `S_CONTAINER`, `S_CALL`,
     `S_STRACC` and the CA's `FALLBACK` status. Today only the
     `CP_DONE` and `CALL_PHASE_DONE` exits can marshal.
   - Trap **22 `FALLBACK`** is the same mechanism with
     `{unit, op}`, for disabled accelerators. Trap **23 `CONFIG`** is fatal.
2. **Audit every `TYPE` and `CALL_FILTER` site.** A real Python error
   raises on pycore: a fatal code now, a Python exception after T6. A
   missing feature routes to `EMULATE`. The two never share a code again.
3. **Context page** at `0x00F0_A000` (4 KB). pycore writes it before
   `trap_req`, and the handoff makes it visible:
   - stack and frame state: `tos`, `rf_wm`, `cur_locals_base`,
     `spill_sp`, frame depth, exc-stack sp;
   - code and namespaces: `cur_code_r`, `consts_base_r`, `names_base_r`,
     `globals_base_r`, `builtins_base_r`, `cur_closure_r`;
   - `active_exc`, `next_pc` (after the `CACHE` entries), heap ptr and
     limit, `ACCEL_CFG`.
4. **RF window.** pycore is frozen while the excore runs, so its RF port
   is free. New MMIO registers `RF_IDX`, `RF_VAL0..3`, `RF_TAG` and
   `RF_CTRL` read or write `RF[tos - k]`, bounds-checked against
   `[rf_wm, tos + push_limit)`. This removes the 4-in / 2-out ceiling that
   `BUILD_STRING n`, calls with `argc > 2` and `UNPACK` hit.
   - The excore MMIO decode grows beyond `addr[7:0]` into pages: mailbox,
     result, slot port, context and RF window, config and caps, debug
     console.
   - Widening entries in place is not possible: a 5th entry would overlap
     `RES_CODE` and a 3rd result `RES_GO`.
5. **New result codes.**
   - `JUMP(target)` uses `redirect_pending_r`.
   - `RAISE(exception handle)` enters `CONT_RAISE` the way `gc_oom_raise`
     does.
   - `UPCALL(callable, nargs, continuation)` runs a Python call and
     re-traps or resumes. It reuses `container_call_pending`.
   - `COMPLETED`, `RETRY`, `NEED_HEAP` and `FATAL` stay.
6. **Result hygiene.**
   - Adopt `heap_ptr` only when the result marks it valid (A21).
   - Clear the result staging at each trap.
   - Check that `pop ≤ resident` and that `push` does not exceed the
     entries provided.
   - Size arrays from `MAX_*_ENTRIES`.
7. **First emulated features** (stack-local, verified missing):
   - list and tuple slicing (`BUILD_SLICE` / `BINARY_SLICE` /
     `STORE_SLICE`), until the CA's `L_SLICE`; read parked PR #94 first;
   - `FORMAT_WITH_SPEC`, until STRACC;
   - `GET_LEN`, `DELETE_GLOBAL`, `DELETE_NAME`, `CALL_INTRINSIC_2`;
   - non-Latin-1 `repr`;
   - unsupported binary-op type combinations from the audit.

   Each handler is deleted from `excore_min` once the feature is built in
   hardware.
8. **Out of scope** for the excore: generators and `async`, which need
   suspended frames on pycore, and anything that would run concurrently
   with pycore.

---

## 11. Memory-system review: what is wrong today, and the fixes

Found while planning (Appendix A has the evidence). Most must land before
any second concurrent data master or memory-mapped IO.

| # | Finding | Fix | Phase |
| --- | --- | --- | --- |
| A6 | **Held-request masters execute twice at L1D.** Container, frame, RF spill/fill and exc-stack keep `req` high in the ack cycle, and L1D re-captures it. Results and cycles are unaffected, but L1D hit counters are about 2× inflated: `img_recursion` really has 1,128 hits, not 2,282, so the P8 frame-buffer decision used an inflated rate. Unsafe for any side-effecting IO write or shared port | Pulse discipline for every master, or drop `req` in the ack cycle. Add per-master response routing (owner id latched at issue). The exc stack must capture `rdata` in its ack cycle; gate STRACC's `ack_i`; add an L1D assertion. Re-measure and correct the P8 table | P0 |
| A7 | **Stale GIC.** Rebinding a global with `ns['x'] = …` on the active globals dict returned 111 instead of 156 with the cache on, and passed with it off | Flush the GIC on every dict write whose base equals `globals_base_r` or `builtins_base_r`. The CA's `gic_flush` pulse takes this over in P3 | P0 |
| — | **Flush/invalidate sequencer** samples `l1d_idle` and pulses `flush_all` a cycle later. L1D consumes it only in `ST_IDLE` and drops a request issued in that same cycle. A concurrent master can make the handoff hang | Hold `flush_all` / `inv_all` as levels until L1D acknowledges, and block new accepts (core, CA, NB) from the idle check onward | P0 |
| — | **Excore slot port** sends a one-cycle request that is lost if the xbar is busy (safe only while every other L2 master is frozen) | valid/ready slot port | P0 |
| A19 | **`heap_zero_r`, the `gc_pyc_dirty_r` watch and GC-INV checks** snoop only the core dmem port | One heap-write event bus from every master | P0 / P3 |
| — | **Code region reachable through the data path** (`0x0100_0000+` via L1D/L2) with no L1I coherence | Address guard: data-path writes to the code region fault (R10) | P0 |
| A19b | Excore `sp_write` never checks the fault status | Check it; a fault returns `FATAL(MEM_FAULT)` | P0 |
| — | **Every excore trap flushes CODC and GIC**, even for pure container work | Flush CODC only when the excore wrote code; flush GIC only when it wrote a namespace dict (reported in the result) | P7 |
| — | **The excore attaches at L2**, so every trap pays a full L1D write-back and invalidate plus a cold refill (§2.2) | Decision D3: mux the excore slot port into the L1D arbiter while pycore is frozen. That removes the flush, the invalidate and the refill, and keeps the excore's view coherent by construction. Keep the L2 attach selectable so both baselines can be measured | P7 |
| — | **The ordinary L1D miss path is word-serial** (4 × L2 requests per line, 53 cycles on an L2 hit vs 15 on the NB path) | Whole-line pipelined fills and write-backs for ordinary misses. This lowers every master's cost and makes baselines fair | P0 (perf; optional) |
| — | **Zero-line writes bypass L2 to DRAM** (`ZERO_LINE_BYPASS` at both levels), so GC allocation zeroing makes the first touch a DRAM round trip | Set L2 `ZERO_LINE_BYPASS = 0`. The CA writes content lines and never zero lines | P3 |
| — | **STRACC never writes full lines**, so fresh destination lines pay a write-allocate fill | Full-line destination writes in STRACC | P2 |
| — | **The CI latency model inverts the hierarchy**: DRAM first beat is 4 cycles, an L2 hit 8. `T_BEAT` and `L2_HIT` are compile-time | Measurements run at `+MEM_LATENCY=30` and `100` too; expose `L2_HIT` and `T_BEAT` as plusargs | P0 |
| — | **The xbar has fixed priority** (L1D > excore > L1I) and assumes L1D and L1I never request together | Round-robin or aging if anything besides L1D's own misses is added at the xbar (only when D3 keeps the L2 attach) | P7 |
| — | **Stale docs**: L2 is called inclusive but nothing back-invalidates L1D; STRACC is also a master in `S_CONTAINER` (dict `SA_CMP`); the GC metadata region is missing from the data map; the hit-rate tables are inflated (A6) | Correct `memory_hierarchy.md` and `architecture.md`, and add CA, IO window and namespace-GIC rows to the invalidation matrix | P0 |

Existing accelerators that reviewed clean: GC sweep and poison writes go
through the ordinary L1D port (coherent). GC prefetch cannot overlap an
excore handoff. Code-RAM writes invalidate the L1I line and the fetch
buffer and flush CODC.

---

## 12. Measuring each accelerator

### 12.1 Configuration profiles

| Profile | `ACCEL_CFG` | Excore firmware |
| --- | --- | --- |
| `all-on` | CA, STRACC, CODC, GIC, CACHE (GC per test) | `excore_min` (from P3; `excore_full` before, §5.1) |
| `no-ca` / `no-stracc` / `no-codc` / `no-gic` | one unit off | `excore_full` |
| `gc-off` / `gc-engine` / `gc-soft` | `GC = 0 / 1 / 2` | `excore_full` for `gc-soft` |
| `all-off` | every accelerator off; the excore does all their work | `excore_full` |

These are crossed with `rom_accel` / `rom_soft`, `+MEM_LATENCY` ∈ {4, 30,
100} and the excore attach point (L2 today, L1D per D3).

### 12.2 Benchmarks

- **Micro**, one per accelerator, under `pycore/programs/bench/`:
  - list append, extend, delete and insert;
  - dict build, lookup, update and delete; sets;
  - attribute-heavy classes;
  - string concat, slice, search and format;
  - print-heavy output;
  - bytes and bytearray;
  - GC churn (`gc_bench.py`).
- **Macro**: on-device `compile()` of the `compile_suite` programs (the
  compiler is the largest real workload on the hart), `demo_exec.py`,
  and the heavy `img_*` programs.

### 12.3 Counters and report

- **On the PERF line**:
  - per-unit busy cycles;
  - CA commands by op, DR-latency histogram, CR latency, overlap cycles
    (CA background work while pycore executes), BCT and idle stalls;
  - STRACC commands and busy cycles;
  - excore traps by code and reason, split into flush, firmware,
    invalidate and post-trap refill misses;
  - fallback commands by unit and op;
  - L1D and L2 counters per master, de-duplicated (A6).
- **`tools/accel_bench.py`** runs the matrix and writes
  `build/accel/report.{csv,md}`. Speedup is `cycles(profile with the unit
  off) / cycles(all-on)`, with the per-unit breakdown and the profile,
  ROM, latency and attach recorded. A baseline CSV is checked in, and a
  nightly workflow (`accel-nightly.yml`, like `gc-nightly.yml`) refreshes
  the report.
- **Fairness**:
  - Remove the artificial 4-cycle delays in the mailbox (`MB_HEAP_LIMIT`
    read, `NEED_HEAP`), or report them.
  - Report "end-to-end" and "compute-only" (handoff excluded) excore
    numbers side by side, so a speedup does not mostly measure coherence
    overhead.

### 12.4 GC fallback (optional)

`GC = 2` is a software mark-and-sweep in `excore_full`, ported from
`gc_model.py`, with roots exported through the context page and RF
window. It is optional (D5). Until it exists, the GC engine is reported
against `GC = 0`: bump allocation, no collection.

---

## 13. Verification

| What | How |
| --- | --- |
| CA unit | `tb_ca.sv`, command-level, against `pycore/tools/ca_model.py`. The model has Python container semantics **and** the exact memory layout (the same placement rules as `heap_image.py` and `gc_model.py`). Randomized command streams over seeds, with a shadow-memory compare (as GC G5) |
| Data ready / container ready | Directed hazard tests: append then iterate; grow then GC; grow then an excore trap; a namespace write then `LOAD_GLOBAL`; STRACC join of a list being built; print of a container being built; an exception right after DR |
| Configuration equivalence | Every hardware test gives the same result under every profile. PR CI runs `all-on` on every area, plus `all-off` on `containers`, `strings`, `objects` and `builtins`. The nightly runs the full matrix and the compile suite under `all-on` and `all-off` |
| Key spec | Generated vectors checked by the RTL unit TB, the excore fallback TB and the host tests (§6.9) |
| GC | G-gates with the CA on. G5's shadow checker covers the CA port. `gc_sites.py` keys for CA allocation sites. `gc_model.py` knows BYTES and BYTEARRAY |
| Memory | `test-caching` with the CA on. The duplicate-request assertion. The pollution acceptance test (§6.8). `tb_mem_nb` extended with a second NB user |
| Console and formatting | stdout tests on both tops; new stdout tests for every type, 64-bit ints, floats, kind-2/4 text (UTF-8), containers and objects. A formatting corpus diffed against CPython 3.14 (ints of every radix including INT_MIN, random and edge-case doubles, quotes and escapes, nested and self-referential containers) |
| Bytes | a `bytes` area in `hw_tests.toml`, diffed against CPython, including `OverflowError` / `ValueError` cases |
| Bugs | Appendix A items become regression tests first, with `xfail` markers until fixed |

Tests that change meaning:
- `dict-grow-fatal` and `set-grow-fatal` (expect 11/13 on single-core)
  become passes under `all-on` and `CONFIG` tests without an excore.
- The `excore-*` integration fixtures with `EXPECTED_TRAP_REQ_COUNT`
  become `no-ca` fallback tests.
- The `BOOT_EN=0` `container-*-fatal` hex fixtures are retired
  (`cleanup_report.md` A4).
- The G0 cycle baseline is re-captured whenever a phase intentionally
  changes cycles (`gc.md` invariant 3). Each phase PR says so.

---

## 14. Phases

Every phase ends with every existing test green under `all-on`, results
unchanged, and the phase's gate below met.

| Phase | Delivers | Gate |
| --- | --- | --- |
| **P0** Groundwork | Regression tests for Appendix A (`xfail`); the §11 P0 rows (duplicate requests, response routing, flush sequencer, slot port, GIC flush, heap-write bus, address guards, docs); `ACCEL_CFG` + MCFG page + `+ACCEL_CFG` + `FW_CAPS` + trap 23 + `pycore_route` at all 27 sites + `EXCORE_PRESENT`; key-spec package and vectors; excore hart and assembler fixes; toolchain decision D2; firmware tree split into `min` / `full` scaffolds; fixes for excore A1–A3, A15, A16, A19b, A21; PERF counters, `accel_bench.py` skeleton and today's baseline captured | Cycles identical except where a fix changes them (documented); L1D counters de-duplicated; default profile behaves exactly as `main` |
| **P1** Console | IO window, `pycore_console.sv`, `CONSOLE_BASE`, `BI_WRITE` (`SHORT_STR` store and the kind-1 / bytes copy loop), `SA_EMIT` for kind-2/4 UTF-8, testbench capture on both tops, ROM `print`, `BI_PRINT` removed from excore | stdout tests pass on **both** tops with zero excore traps; `pycore_exec.py` and PHASE_MARK unchanged for users |
| **P2** Formatting I | `SA_FMT_INT` with sink mode; `str` / `repr` for int, bool, None and str (kind-1 repr); `SA_BUILD_STRING`; `FORMAT_SIMPLE` / `CONVERT_VALUE` via STRACC; `hex` / `oct` / `bin` natives; `repr` seeded; STRACC full-line writes | formatting corpus matches CPython; A4 fixed |
| **P3** CA, stage A0 | The CA: interface, arbiter port and NB wiring, compare lane, alloc channel, drain points, `gic_flush`, descriptor cache; every §6.1 command; §6.13 fixes; ROM `list.append` / `list.extend` / `list()` / `tuple()` on native commands; legacy path behind `CA = 0` | zero container excore traps under `all-on`; G-gates, `test-caching` and compile suite pass; CA area/Fmax recorded; cycles report vs P0 baseline |
| **P4** CA, stage A1 | early retire at DR; the Appendix D container-touch stall; overlap counters | identical results; hazard tests; overlap measured |
| **P5** Bytes | §9: representation, GC kinds, image and linter, CA `BA_*`, STRACC bytes commands, `LOAD_ATTR` on primitives, ROM wrappers, `OverflowError` | bytes area matches CPython |
| **P6** Formatting II | `SA_FMT_FLOAT`, `SA_REPR_BYTES`, container and object `str` / `repr` (§8.4–8.5), print of every type | corpus matches CPython (addresses normalized) |
| **P7** Excore emulator | traps 21/22 and `MB_REASON`, context page, RF window, `JUMP` / `RAISE` (`UPCALL` optional), result hygiene, the `TYPE` / `CALL_FILTER` audit, first `EMULATE` handlers in `excore_min`; D3 (excore at L1D) and the selective CODC/GIC flush | listed features run through `EMULATE`; no regressions |
| **P8** Fallbacks and measurement | `excore_full` implements every CA and STRACC command; the legacy container arms are deleted from pycore (`S_CONTAINER` becomes the micro-sequencer); `rom_soft`; the profile matrix in CI and nightly; the speedup report; optionally `GC = 2` | every profile gives identical results on the whole suite; report published |
| **P9** CA, stage B | the 4-deep command queue, the address-precise BCT, a lookup engine running beside the background engine; a design note for stage C (pipelined pycore) | identical results; measured gain over A1 |

Dependencies: P0 comes before everything. P1 needs P0's duplicate-request
fix and MCFG. P2 needs P1 for sink mode. P3 needs P0. P4 and P5 need P3,
and P5 also needs P2. P6 needs P2 and P3. P7 needs P0. P8 needs P3–P7.
P9 needs P4.

---

## 15. Decisions (defaults chosen; the owner may override)

| # | Question | Default |
| --- | --- | --- |
| D1 | What are the two pycore firmware versions? | `rom_accel` / `rom_soft` (§5.2) |
| D2 | Excore firmware language | C with a pinned RV32I GCC in Docker; assembly only for the trap entry |
| D3 | Excore memory attach | move into the L1D arbiter while pycore is frozen; keep L2 selectable for measurement |
| D4 | What `CA = 0` means in the final design | `excore_full` for every CA command (as asked); legacy arms deleted |
| D5 | GC fallback | `GC = 2` software collector is optional, after P8 |
| D6 | Console address | IO window `0x0200_0000`, 16 channels × `0x100` |
| D7 | `bytes` representation | heap-only, LONG_STR handle layout |
| D8 | `bytearray` layout | compact list-like (GC and `gc_model.py` change) |
| D9 | CA raise codes | real Python exceptions together with T6; fatal codes until then |
| D10 | Float `repr` algorithm | Ryū, small-table variant |
| D11 | `repr` above U+00FF | `EMULATE` first; Unicode printable table in STRACC later |
| D12 | Set display order | PyCore probe order; documented divergence for colliding hashes |
| D13 | L1D port for the CA | arbitrated single port; true dual port only if measurements demand it |

---

## 16. Risks

| Risk | Mitigation |
| --- | --- |
| The CA is large; area and Fmax regress. For scale: the GC engine, with its arrays shrunk to 16 entries, already needs 71% of an LFE5U-85 and places at 11.3 MHz, though `gc.md` estimates ~100 MHz for its logic in sky130 | Iterative engines, the §6.15 gate per phase, stage A0 before any overlap |
| The CA and `excore_full` drift apart semantically | The one key spec (R6), the shared opcode table, exact-layout models, cross-profile heap-dump comparison |
| Speedup numbers measure the handoff, not the work | §12.3 split counters, D3, "compute-only" columns |
| Early retire exposes ordering bugs | A0 → A1 → B in separate phases; directed hazard tests; the shadow-memory checker |
| Firmware size and toolchain churn | D2 decided in P0; 64 KB IMEM; generated headers |
| CI time grows with the profile matrix | PR CI runs `all-on` plus `all-off` on four areas; the full matrix is nightly |
| Cycle-baseline churn breaks GC gate G1 | Re-capture G0 in the PR that changes cycles; every phase PR says whether it does |

---

## 17. Documents to update with each phase

- `pycore/docs/architecture.md`: the three-unit system, the excore
  contract, and the trap taxonomy (21, 22, 23; 9–14 and 19–20 retired
  into `FALLBACK`).
- `pycore/docs/memory_hierarchy.md`: the master table, CA and IO rows in
  the invalidation matrix, corrected counters, the GC region in the map.
- A new `pycore/docs/container_accel.md` (as built), plus
  `string_accel.md` and `gc.md`.
- `tags.md` (BYTES, BYTEARRAY), `object_model.md`, `bytecode_support.md`,
  `exception_support.md` and `builtins.md` (print, repr, bytes, int
  methods).
- `excore/docs/*`: the new MMIO pages, firmware builds, toolchain and
  emulation ABI. `adding_a_trap_handler.md` is stale today.
- `README.md`: the ownership split and the trap table.
- `planning/master_plan.md`: the tracks and memory-map locks (MCFG page,
  CA staging page, context page, IO window, `CONSOLE_TX` reworded).

When this plan lands, move it to `planning/old/` with an "Archived" note
(see `planning/README.md`).

---

## Appendix A. Bugs and hazards found while planning

"Reproduced" means a probe program ran on the simulators built from
`5335a22`, with the evidence shown. "Code reading" means not run.

| # | Symptom | Where | Evidence |
| --- | --- | --- | --- |
| A1 | Excore `SET_UPDATE` hangs or drops elements when a source element hits an occupied slot. `keys_rich_eq` overwrites `SCR_TMP_L0`, the loop bound | `excore/fw/list_grow.s` `keys_rich_eq` vs `su_loop` | Reproduced: `x = 1; {*[x, x]}` hangs; `{*{1, 2}, *[2, 3, 4]}` gives `len` 3 instead of 4. Single-core passes both |
| A2 | Excore hashes `LONG_STR` as `addr ^ hash`; pycore uses `hash` (`value[95:64]`). After an excore rehash to ≥ 64 slots, lookups miss (`MEM_FAULT`) | `hash_lstr` vs `pycore_stracc_hash` | Reproduced: 20 runtime keys `"abcdefghijklmnop" + str(i)` fail on two-core and pass with 8 keys. Four 15-key dicts merged with `{**a, **b, **c, **d}` pass on single-core (pycore rehash) and fail on two-core (excore) |
| A3 | Excore bulk ops compare `LONG_STR` keys by handle bits: equal strings at different addresses become two keys | `keys_rich_eq` → `kreq_bits` | Reproduced: `{*[p + "qr", q + "r"]}` gives 2 (CPython 1); `{**{k1: 1}, **{k2: 2}}` gives 2 entries |
| A4 | `print` of an int above 32 bits prints wrong digits | `bi_print_int` loads `MB_E2_VAL0` only | Known (`cleanup_report.md` J2) |
| A5 | `bytearray()`, `int.to_bytes()` and `int.from_bytes()` reach the excore and come back `FATAL(ILLEGAL_OPCODE)`. `n.to_bytes()` `TYPE`-traps earlier | `do_builtin_call` | Reproduced (bytearray, `int.to_bytes`) |
| A6 | Held-request dmem masters execute twice at L1D. Counters are ~2× inflated; unsafe for IO | `pycore_core.sv` dmem mux, `pycore_cache.sv` `leg_take` | Reproduced in a dedicated testbench (8 requests become 16 lookups and 8 stray acks). On real programs, a scratchpad RTL copy that drops `req` in the ack cycle gives identical cycles and results, with `img_recursion` L1D hits falling from 2,282 to 1,128 |
| A7 | GIC returns a stale global after `ns['x'] = …` on the active globals dict | GIC is flushed only by `STORE_NAME` / `STORE_GLOBAL`, traps, globals switches and GC | Reproduced: 111 instead of 156 with the cache on; 156 with `CACHE_EN=0`; the `global x` control passes |
| A8 | `x in t` over more than 256 elements hangs: the index is 8 bits but the address is 32 | `container_idx_r` | Reproduced: `999 in <300-tuple>` still running at 2M cycles; a hit at index 250 passes |
| A9 | Name index ≥ 128 truncated: name *N* takes the tag of name *N & 127* | `container_idx_r <= namei[6:0]` in `pycore_cont_object.svh` | Reproduced: a LONG_STR-named global at index 128 → `MEM_FAULT`; index 127 passes |
| A10 | `set(iterable)` treats `None` as an empty slot | `BI_SET` in `pycore_call_fsm.svh` | Reproduced: `None in set((None, 5))` is False; `len(set((None, None, 7)))` is 3 |
| A11 | Bulk dict update and merge walk hash-slot order, not insertion order | `pycore_cont_bulk.svh`, `do_dict_update` / `do_dict_merge` | Reproduced: `a = {3: …, 1: …}; {**a}` iterates 1 first (CPython 3) |
| A12 | `in` on list and tuple lacks int/float cross-equality and tuple value equality | `pycore_elem_eq` | Reproduced: `1.0 in [1, 2]` and `(a, 2) in [(a, 2)]` (distinct tuples) are both False |
| A13 | `KeyError`, `IndexError` and `NameError` are fatal `MEM_FAULT`s, not exceptions | container arms | Reproduced; known limitation (T6) |
| A14 | Instance dicts start at 4 slots, so the 4th attribute needs an excore grow on every instance | `CALL_EMPTY_DICT_SLOTS` | Reproduced: 3 attributes pass on single-core, 4 halt with 11 |
| A15 | Excore `SET_UPDATE` keeps the loop index in `SCR_FTI0/1`, which `float_to_int` overwrites | `su_insert` vs `float_to_int` | Code reading |
| A16 | Excore `LIST_GROW` writes the appended element's tag slot with nonzero upper bits | `do_list_grow` append | Code reading |
| A17 | Vendored hart: BLT/BGE wrong on signed overflow; MUL executes as ADD; SYSTEM and unknown instructions are silent NOPs | `riscv32_common.sv` | Code reading |
| A18 | `asm_rv32.py` sizes a forward-referenced `li` as 2 words in pass 1 and emits 1 in pass 2 | `asm_rv32.py` | Reproduced with a 3-line program |
| A19 | `heap_zero_r` and the GC watches snoop only the core dmem port | `pycore_core.sv` | Code reading |
| A19b | Excore `sp_write` ignores `SP_STATUS.fault` | `list_grow.s` `sp_write` | Code reading |
| A20 | The `BUILTIN_CALL` marshal sends only arg0 and the last argument, and drops `CALL_KW` names | `pycore_call_fsm.svh` | Code reading |
| A21 | A `FATAL` result adopts a stale `heap_ptr` (harmless while `FATAL` halts) | `S_TRAP_WAIT` | Code reading |
| A22 | The contamination bit is unreliable: `STORE_DICT` writes the contaminated handle into a slot that is popped | `pycore_cont_dict.svh` | Code reading |
| A23 | `BUILD_*` / `UNPACK_SEQUENCE` take `oparg[6:0]`; `LIST_TO_TUPLE`, `UNPACK_EX` and `set()` `TYPE`-trap at 128+ elements | `pycore_core.sv`, `pycore_cont_list.svh` | Code reading |
| A24 | Not synthesizable or poor timing: `real` in `BI_MAX`; combinational 64-bit divide loop in `pycore_int_to_short_str` | `pycore_call_fsm.svh`, `pycore_defs.svh` | Code reading |
| A25 | Stale docs: L2 "inclusive"; STRACC master states; data map without the GC region; `adding_a_trap_handler.md` free codes; `rv32i_subset.md` M extension | `pycore/docs`, `excore/docs` | Code reading |

---

## Appendix B. Measured numbers (two-core vs single-core, `MEM_LATENCY=4`, cache on)

| Program | Excore traps (code: count) | Excore wait | Total cycles |
| --- | --- | ---: | ---: |
| `[i for i in range(20)]` | 9: 4 | 15,390 | 21,626 |
| 20 × `l.append(i)` | 10: 20 | 40,163 | 61,712 |
| `list(range(10))` | 10: 10 | 19,119 | 26,099 |
| `a.extend(b)` with 8 elements | 10: 9 | 21,840 | 29,114 |
| `d[i] = …` × 10 | 11: 1 | 11,982 | 19,278 |
| class with 7 attributes | 11: 1 | 14,431 | 22,407 |
| `{i for i in range(10)}` | 13: 1 | 7,873 | 14,181 |
| `print(42)` | 16: 2 | 2,978 | 8,313 |
| `{**a, **b}` (small) | 19: 2 | 19,396 | 23,780 (single-core: 4,984, no traps) |
| `{**a, **b}` growing twice | 19: 2 | 60,301 | 68,432 (single-core: 11,748) |
| `{*list}` with 24 elements | 14: 1 | 48,394 | 59,418 (single-core: 11,248) |
| `f(x=1, **kw)` | 20: 1 | 14,081 | 18,609 (single-core: 4,630) |

Latency (separate testbench): an L1D hit takes 1 cycle; an ordinary miss
that hits L2 takes 53; an L1D and L2 miss takes 57 at latency 4 or 83 at
latency 30; an NB-port miss that hits L2 takes 15; a full L1D flush takes
132 cycles plus ~52 per dirty line.

---

## Appendix C. New addresses, registers and codes

| Item | Value |
| --- | --- |
| MCFG page | `0x00F0_9000`–`0x00F0_9FFF` |
| Excore context page | `0x00F0_A000`–`0x00F0_AFFF` |
| CA staging page | `0x00F0_B000`–`0x00F0_EFFF` |
| IO window | `0x0200_0000`–`0x0200_FFFF`; console channel *c* at `+c × 0x100` |
| Traps | 21 `EMULATE` (recoverable), 22 `FALLBACK` (recoverable), 23 `CONFIG` (fatal) |
| pycore registers | `accel_cfg_r`, `console_base_r` (per process), `fw_caps_r` |
| Excore MMIO | `FW_CAPS`, `FW_CAPS_VALID`, `MB_ACCEL_CFG`, `MB_REASON`, the RF window, paged decode beyond `addr[7:0]` |
| Builtins | `_bi_write`, `_bi_print` (new semantics), `_bi_accel_cfg`, `_bi_int_to_bytes`, `_bi_bytes_to_int`; `repr` seeded |

`0x00F0_F000`–`0x00F3_FFFF` stays free.

---

## Appendix D. Stage A1: instructions that wait for the CA to be idle

In stage A1 an instruction waits for `ca_idle` when it:

- issues any CA command (the CA runs one command at a time). That
  includes `TO_BOOL` and `len` on a container, `UNPACK_*` and every
  binder kwargs probe;
- issues a STRACC command with a container operand (`join`, repr walks),
  or any print path that reads a container;
- is a `CALL` that binds `*args` or `**kwargs`, a `CALL_FUNCTION_EX`
  expand, or a call to a builtin that reads a container (`len`, `set`,
  …);
- is `GET_ITER` or `FOR_ITER` on a list, tuple, dict, set or bytearray
  iterator;
- is `LOAD_ATTR`, `STORE_ATTR` or `DELETE_ATTR`, or a `LOAD_GLOBAL` /
  `LOAD_NAME` that misses the GIC;
- needs a drain point anyway: any excore trap, GC entry, heap or code
  release, `_bi_code_*`, or halt.

Everything else proceeds while the CA finishes container-ready work:
ALU and compare ops, `LOAD_FAST` / `STORE_FAST`, branches, `LOAD_CONST`
and `RETURN`. Stage B replaces this list with an address check against
the BCT.
