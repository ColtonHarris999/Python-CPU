# String Accelerator (STRACC) — design

A tightly-coupled accelerator inside pycore, alongside the container FSM, that
owns every non-trivial string operation. Small operations on small strings stay
on the existing string ALU path; everything else is one STRACC command.

This replaces the "relocate the bytes, keep a copy engine" shape of P5 in
[`memory_system_plan.md`](memory_system_plan.md). It is a larger change and a
much better end state: it retires `pycore_string_mem.sv` entirely, closes a
real semantic hole in long-string equality, and turns the O(n·m) firmware
string methods into hardware scans.

Graduates to `pycore/docs/string_accel.md` when it is built.

---

## 1. Why

Today long strings live in a 64 KB private byte array (`pycore_string_mem.sv`)
with combinational whole-string concat and slice, and everything beyond
`join` / `startswith` / `endswith` / `find` is either missing or firmware
Python. Three problems:

**It is slow where it matters.** `pycore_firmware/builtins/str_find.py` is an
interpreted O(n·m) loop whose body is ~20 dynamic opcodes per haystack
position, *and* allocates a fresh slice each position:

```python
while i < limit:
    if self[i:i + n] == sub:   # BINARY_SLICE → CONT_SLICE_STR → UTF-8 walk + alloc
        return i
    i = i + 1
```

At the report's baseline CPO of 12.5 that is **≈250 cycles per position**
before the slice's own character walk and allocation. A 100-character
haystack costs ~25,000 cycles. A 16 B/cycle hardware scan does the same
search in roughly 30. Two to three orders of magnitude, and the same argument
applies to `replace`, `split`, `count`, and `in`.

> Derivation, not measurement: opcode count is from `dis` on the actual
> firmware source; CPO is `memory_hierarchy_report.md` E1. Re-derive against
> real RTL counters in P9.

**Long-string equality is wrong in principle.** `pycore_dict_key_rich_eq`
compares LONG_STR by `{size, addr}` descriptor, and
`pycore_dict_key_hash` hashes `addr ^ len`. Both are correct *only* because
`StringHeapBuilder` interns every compile-time constant. The moment a runtime
concat or slice produces a string, two equal strings can have different
addresses — so they hash differently and compare unequal. `d[a + b]` silently
misses. §4 fixes this.

**It does not scale to the language.** `str` has **47 public methods** in
CPython 3.14. Four are implemented. Adding the rest as firmware Python would
make each one cost thousands of cycles.

## 2. Scope: ALU vs accelerator

The split is **by result size and operand kind, not by operation**.

| Stays on the pycore string ALU (no STRACC) | Why |
| --- | --- |
| `SHORT + SHORT` where the result is ≤ 15 bytes | already inline-combinational; no memory touched |
| `SHORT` vs `SHORT` compare (`==`, `!=`, `<`, `≤`, `>`, `≥`) | both payloads are in the handles |
| `len(s)` for any string | `nchars` is in the handle (§3) |
| `hash(s)` for any string | SHORT: inline XOR; LONG: cached in the handle |
| `bool(s)` | `nchars != 0`, from the handle |
| identity (`is`) | address compare |
| equality *fast reject* for LONG strings | `(hash, nbytes, nchars)` from the handle — no memory |

Everything else is a STRACC command: any operation touching a LONG payload,
any operation whose result exceeds 15 bytes, any search / map / classify /
split / trim, and all 47 methods.

**Canonical-representation invariant (load-bearing, keep it):** a string of
*n* bytes is SHORT_STR iff *n ≤ 15*. STRACC must return a SHORT_STR for any
result of 15 bytes or fewer and must never emit a short LONG_STR. This is what
makes cross-tag comparison trivially false and keeps hashing consistent.

## 3. New STR object and handle

### 3.1 Handle (register file / stack entry)

The current handle is `{ nbytes[127:64], addr[63:0] }`. Report finding F4 says
the interpreter's cost is *chain length*, not miss latency — so put every hot
field in the handle and never read the header for metadata:

```
LONG_STR value[127:0]:
  [31:0]    addr        object base address in dmem
  [63:32]   nchars      character count        → len(), bounds checks
  [95:64]   hash        32-bit content hash    → dict/set probe, fast reject
  [119:96]  nbytes      payload byte count     → fast reject, slicing
  [127:120] flags       bit0 ASCII, bit1 INTERNED, bit2 HAS_STRIDE, rest reserved
```

`len()`, `hash()`, `bool()`, the ASCII test, and the equality fast reject all
become zero-memory operations on the handle. Only the payload needs dmem.

`nbytes` at 24 bits caps a single string at 16 MB, which is above the whole
data map. SHORT_STR is unchanged: `size` in `value[127:124]`, 15 bytes in
`value[123:4]`.

### 3.2 Object in dmem

Strings are immutable, so unlike a list there is no relocatable buffer and no
indirection — header and payload are contiguous:

```
obj + 0    header  { flags[127:120], nbytes[119:96], hash[95:64],
                     nchars[63:32], stride_ptr[31:0] }
obj + 16   payload bytes   0..15
obj + 32   payload bytes  16..31
   ...                              (padded to a 16-byte multiple)
```

The header duplicates the handle's metadata so the object is self-describing
for the accelerator, the image builder, and anything that walks the heap. The
handle is the fast path; the header is the source of truth.

Allocation is `pycore_heap_place` (P1 line alignment), so a string ≥ 64 bytes
starts on a cache line and streams at one line per fill.

**`hash` and `nchars` are computed eagerly at construction**, by the image
builder for constants and by STRACC for runtime results. There is no lazy-hash
state machine and no "hash not yet valid" case. `flags.bit1 HASH_VALID` is
reserved for a future lazy path but is always 1 in v1.

### 3.3 The ASCII flag and the stride map

`flags.ASCII` is set when `nbytes == nchars`. For an ASCII string, character
index *i* is byte *i* — `s[i]` and `s[a:b]` are O(1) with no UTF-8 decode.
This is the overwhelmingly common case and it is worth the one flag bit.

For non-ASCII strings longer than `PYCORE_STR_STRIDE_MIN` (default 256 bytes),
the builder also allocates a **stride map**: a `uint32` byte-offset for every
16th character, at `stride_ptr`. Character index *i* then starts from
`stride[i >> 4]` and decodes at most 15 characters forward, so indexing is
O(1) amortised instead of O(n). Below the threshold, and when `HAS_STRIDE` is
clear, STRACC decodes from the start. Bounded worst case, no cost in the
common case.

### 3.4 Equality and interning

Interning survives, but **as an optimisation rather than a correctness
requirement**. Equality becomes three tiers, cheapest first:

| Tier | Test | Cost | Resolves |
| --- | --- | --- | --- |
| 1 | `addr_a == addr_b` | 0 cycles, no memory | all interned constants — globals, `co_names`, attribute names |
| 2 | `(hash, nbytes, nchars)` differ | 0 cycles, no memory | almost every inequality |
| 3 | STRACC `SA_CMP EQ` over the payloads | ~nbytes/16 cycles | genuinely equal, non-identical strings |

Tiers 1 and 2 are pure handle arithmetic and cover essentially all hot
traffic. Tier 3 is what makes `d[a + b]` correct, which it is not today.

## 4. The unit

`pycore/rtl/pycore_str_accel.sv` — a standalone module, not an include. It has
its own dmem master port so it can be verified against memory on its own,
which is what §9 does.

### 4.1 Ports

```
  command       cmd_valid_i, cmd_ready_o, cmd_op_i[5:0], cmd_var_i[3:0],
                cmd_a_i[127:0], cmd_b_i[127:0], cmd_c_i[127:0],
                cmd_heap_ptr_i[31:0]
  result        res_valid_o, res_entry_o[127:0], res_heap_ptr_o[31:0],
                res_trap_o, res_trap_code_o[4:0]
  dmem master   req_o, we_o, wstrb_o[15:0], addr_o[31:0], wdata_o[127:0],
                ack_i, rdata_i[127:0], fault_i          (§0 port contract)
  perf          bytes_scanned_o, bytes_written_o, cmd_count_o
```

Three tagged operands cover every op: receiver, argument, and a second
argument (`start`/`end`, fill character, count, width).

The core gains `S_STRACC`, entered from `S_EXEC` when decode asserts
`dec_is_straccel`, mirroring `S_CONTAINER`. The core is frozen for the
duration and the accelerator drives the dmem port through the existing
arbitration (`stracc_dmem_active`, next to `container_dmem_active`). One
instruction is in flight, so there is no coherence question.

### 4.2 Datapath

```
   dmem rdata (128b) ──► src window (2 × 128b)
                              │
                        byte funnel shifter (32B → 16B, byte-granular)
                              │
        ┌────────────┬────────┴────────┬──────────────┐
        ▼            ▼                 ▼              ▼
   compare lane   map lane        classify lane   hash accumulator
   (16 × byte)    (16 × LUT)      (16 × predicate) (rolling, 32b)
        │            │                 │              │
        └────────────┴────────┬────────┴──────────────┘
                              ▼
                    dst window ──► dmem wdata + wstrb
```

The **byte funnel shifter** is the one substantial new datapath block:
concatenating strings whose lengths are not multiples of 16 needs the source
realigned to the destination's byte offset. One 32-byte-in / 16-byte-out
funnel handles every op.

Target throughput is **16 bytes per cycle on an L1D hit** for copy, compare,
search, hash and classify — one 128-bit word per cycle, limited by the single
dmem port.

> **L1D interaction.** Building a result writes whole lines. A write-allocate
> L1D would fill each line from memory immediately before overwriting all of
> it. P5 adds a **write-full-line / no-allocate** path to `pycore_cache.sv`:
> when `wstrb` is all-ones across a complete line, install the line without a
> fill. Without this, every 64 bytes written costs a pointless 64-byte read.

### 4.3 Primitive engines

47 methods are not 47 hardware ops. Eight primitives cover the whole surface:

| Engine | Op | Variants |
| --- | --- | --- |
| **COPY** | `SA_CONCAT`, `SA_REPEAT`, `SA_JOIN`, `SA_SLICE`, `SA_PAD` | gather N ranges → one new string |
| **COMPARE** | `SA_CMP` | `EQ NE LT LE GT GE` |
| **SEARCH** | `SA_SEARCH` | `FIND RFIND COUNT CONTAINS STARTSWITH ENDSWITH` (+ start/end) |
| **MAP** | `SA_MAP` | `UPPER LOWER SWAPCASE CAPITALIZE TITLE TRANSLATE` |
| **CLASSIFY** | `SA_CLASSIFY` | `ALNUM ALPHA ASCII DIGIT LOWER SPACE TITLE UPPER` |
| **TRIM** | `SA_TRIM` | `LEFT RIGHT BOTH` (+ character set) |
| **SPLIT** | `SA_SPLIT` | `SPLIT RSPLIT SPLITLINES PARTITION RPARTITION` → LIST/TUPLE |
| **HASH** | `SA_HASH` | internal; runs on every construction |

Plus two element ops the container FSM hands over: `SA_CHAR_AT` (subscript,
ASCII or decoded) and `SA_ITER_NEXT` (one character for `for c in s`).

## 5. Coverage: every operator, builtin and method

**Operators and protocol** — `+` COPY · `*` COPY · `in` SEARCH ·
`==`/`!=`/`<`/`≤`/`>`/`≥` COMPARE · `s[i]` CHAR_AT · `s[a:b]` COPY ·
`for c in s` ITER_NEXT · `hash` handle · `len` handle · `bool` handle.

**f-strings** — `FORMAT_SIMPLE`, `CONVERT_VALUE`, `BUILD_STRING` → COPY.

**Builtins** — `str()` COPY/convert · `ord()`/`chr()` on-core ·
`min`/`max`/`sorted` COMPARE · `repr`/`ascii` COPY+MAP.

### The 47 methods

| Engine | Methods |
| --- | --- |
| **COPY** (12) | `join` `center` `ljust` `rjust` `zfill` `expandtabs` `removeprefix` `removesuffix` `partition` `rpartition` `format` `format_map` |
| **SEARCH** (8) | `find` `rfind` `index` `rindex` `count` `startswith` `endswith` `replace` |
| **MAP** (7) | `upper` `lower` `swapcase` `capitalize` `title` `casefold` `translate` |
| **CLASSIFY** (11) | `isalnum` `isalpha` `isascii` `isdecimal` `isdigit` `isidentifier` `islower` `isnumeric` `isprintable` `isspace` `istitle` `isupper` |
| **TRIM** (3) | `strip` `lstrip` `rstrip` |
| **SPLIT** (3) | `split` `rsplit` `splitlines` |
| **Deferred** (3) | `encode` (needs `bytes`), `maketrans` (returns a dict — firmware), `format`/`format_map` full mini-language |

`isidentifier` and `isprintable` are listed under CLASSIFY but need more than a
byte predicate; see §6. `partition`/`rpartition` are SEARCH followed by three
COPYs and return a TUPLE.

## 6. Unicode ceiling — stated, not hidden

v1 is **byte-exact for all UTF-8** and **semantically complete for ASCII**:

* `len`, indexing, slicing, iteration, concat, compare, search, hash, split and
  trim are correct for any valid UTF-8 input, because they are byte or
  code-point operations.
* MAP (case conversion) and CLASSIFY use **ASCII tables**. A non-ASCII code
  point passes through MAP unchanged and returns `False` from alphabetic and
  case predicates.
* `isdecimal` / `isnumeric` / `isidentifier` / `isprintable` / `casefold` are
  ASCII-subset only.

This is the same class of documented deviation as 64-bit `int`, and belongs in
`pycore/docs/bytecode_support.md` next to it. A `STRACC_UNICODE_STRICT`
parameter (default 0) raises `PY_TRAP_TYPE` on a non-ASCII input to MAP or
CLASSIFY instead of approximating, for programs that would rather fail loudly.

## 7. Container interaction

This is where the design has to fit the machine that already exists.

**dict / set with string keys.** The probe's hash comes from the handle (free).
At `CP_DICT_CHK_VAL` the candidate is resolved by the §3.4 tiers: address
equal → hit; `(hash, nbytes, nchars)` differ → miss, next probe; otherwise the
dict FSM issues `SA_CMP EQ` and waits. Because tier 1 catches interned
constants and tier 2 catches essentially every miss, the accelerator is rarely
entered from a probe at all — which matters, because globals lookup is the
hottest path in the machine (report F4).

**`CONTAINS_OP`.** On a string receiver → `SA_SEARCH CONTAINS`. On a
list/tuple/set of strings → per-element three-tier equality, accelerator only
on tier 3.

**`sorted` / `min` / `max` over strings** → `SA_CMP LT`, same tiers.

**`FOR_ITER` over a string** → `SA_ITER_NEXT`. This *removes* code: the
`cont_str_win` combinational window, `string_read_addr`/`string_read_data` and
the duplicated UTF-8 decode in `pycore_core.sv` and `pycore_cont_list.svh` all
go away, replaced by one accelerator op that both string tags share.

**`str.join(iterable)` and `split` → LIST.** The accelerator reads LIST/TUPLE
element handles directly from dmem and allocates LIST objects for `split`
results. It therefore depends on the LIST/TUPLE layout — a deliberate,
documented coupling, justified because the alternative (the core feeding
elements across the command interface one at a time) costs a handshake per
element. **STRACC never touches dict or set layout**; that boundary stays.

`join` is two passes: pass 1 sums element lengths and validates that every
element is a string (`TYPE` trap otherwise); pass 2 allocates once and copies.
Two passes mean no reallocation and no partial allocation on a type error.

**excore.** Strings are immutable and never relocate, so excore's relocating
list/dict/set grow moves handles, never payloads. No interaction, no new trap
codes, no change to the mailbox.

## 8. Allocation and traps

STRACC receives `heap_ptr` with the command and returns the updated pointer —
the same contract excore already uses (`trap_res_heap_ptr`), so there stays
exactly one allocator of record. Sizing is computed before any allocation, so
an out-of-heap condition returns `PY_TRAP_MEM_FAULT` with the heap pointer
**unmoved**.

New trap surface: none. STRACC reuses `PY_TRAP_TYPE` (non-string operand) and
`PY_TRAP_MEM_FAULT` (OOM / bad address). There is no `PY_TRAP_VALUE` in the
taxonomy and this plan does not add one: `index` / `rindex` return the SEARCH
miss sentinel (-1) to the core, which raises `ValueError` through the existing
firmware raise path (`PY_TRAP_RAISE` / `OBK_EXCEPTION`), exactly as the
firmware `str.find` wrapper does today.

## 9. Verification — standalone first

The unit is verified **as its own design against real memory**, before a single
line of the core changes. This is the phase that de-risks the cutover.

### 9.1 `tb_str_accel.sv`

`pycore_str_accel` + `pycore_ram` (and optionally an L1D, to measure the
write-full-line path). Commands are driven directly; no core.

Directed cases, per engine:

* **Boundaries:** empty string; 1 byte; exactly 15 and exactly 16 bytes (the
  SHORT/LONG boundary — a 16-byte result must be LONG, a 15-byte result must be
  SHORT); exactly one line (64 B); one byte over a line.
* **Alignment:** every source/destination byte phase 0..15 through the funnel
  shifter; a copy whose source and destination overlap in the same line.
* **UTF-8:** a multi-byte code point straddling a 16-byte word boundary and a
  64-byte line boundary; a 4-byte code point; indexing with and without a
  stride map; a string that is ASCII except for its last character.
* **Allocation:** OOM exactly at `PYCORE_HEAP_LIMIT`; OOM mid-`join` (heap
  pointer must not move); line alignment of every result.
* **Search:** needle longer than haystack; empty needle; needle at position 0,
  at the end, spanning a word boundary; overlapping matches for `count`.

### 9.2 The differential harness — the real test

47 methods cannot be covered by hand-written directed tests. CPython 3.14 *is*
the oracle:

```
pycore/tools/strgen.py
  corpus   ASCII, Latin-1, CJK, emoji, empty, 1 char, 15/16/63/64/65 bytes,
           strings with repeated substrings, whitespace-heavy, mixed case
  generate random (op, variant, operands) triples over the corpus
  run      CPython 3.14 → expected result
  run      tb_str_accel via a command trace → actual result
  compare  value, tag, SHORT/LONG classification, nchars, nbytes, hash
```

Every mismatch is a bug in the accelerator until proven otherwise. Seeded and
reproducible; CI runs a fixed seed set, and a longer sweep runs on demand. This
is the acceptance gate for P5a — not "the directed tests pass".

A Python model of the accelerator (`pycore/tools/strmodel.py`) sits alongside,
so the same generator can diff *model vs CPython* quickly and *RTL vs model*
under Verilator, and a failure localises immediately to spec or implementation.

### 9.3 Integration verification

* Every existing string fixture (`img_str_*`, `img_build_string`,
  `img_sorted_str`, `img_for_iter_str_*`, `img_slice_str_clamp`,
  `img_list_repeat_jaro`) stays green through the cutover.
* New: `img_str_dict_key_runtime` — `d[a + b]` where `a + b` is built at
  runtime and equals an interned constant key. **This fails on today's main**
  and is the fixture that proves §3.4.
* One image fixture per method batch in P5e.
* The transparency and latency gates from P0/P2 keep applying — STRACC must
  produce identical results at `CACHE_EN` 0 and 1 and at every `MEM_LATENCY`.

## 10. Memory map

Strings become ordinary heap objects, so the old plan's dedicated string
regions are **not needed** — that part of P5 disappears. But ~64 KB of string
payload now competes for a 106 KB heap, so the data region grows:

```
0x0000_0440 – 0x000E_FFFF   object heap (~955 KB)          ← grows
0x000F_0000 – 0x000F_0FFF   exception-info arena (4 KB)     ← moves
0x000F_1000 – 0x000F_8FFF   call-frame stack (32 KB)        ← moves, 1024 frames
0x0010_0000                 DATA_LIMIT                      ← widened from 128 KB
```

This is the map move the earlier plan deliberately deferred. P5 is the right
time: `DATA_LIMIT` has to widen anyway (`pycore_ram.sv` already says so), and
the P0 mirror test plus the new placement mirror now guard the constants that
made the move risky. The one hand-written literal to fix is
`excore/tb/tb_excore.sv`'s `BLOCK_SHIFT(17)`, which sizes its bank to span
`PYCORE_HEAP_LIMIT`.

## 11. Compile-time strings

`encoding.py::StringHeapBuilder` is replaced by
`HeapImageBuilder.alloc_str(bytes)`, which emits a §3.2 object into the object
heap with `hash`, `nchars`, `nbytes` and `flags` filled in, plus a stride map
when the thresholds are met. Interning stays (dedupe by content) and now sets
`flags.INTERNED`.

`--string-hex`, the `STRING_HEX` plusarg, `pycore/programs/string_mem.hex` and
the `string_heap` parameter threaded through `tag_constant` all disappear. One
image, one heap.

This is also the hook the future on-device `compile()` needs: it allocates
string constants with the same routine, so a compiled-on-device module and an
image-built module produce byte-identical string objects. Note that in
`planning/compile_plan.md`.

## 12. Phases

Each ends with the full regression green.

**P5a — the unit, standalone.** `pycore_str_accel.sv`, `tb_str_accel.sv`,
`strmodel.py`, `strgen.py`. Not wired into the core; the core still uses
`pycore_string_mem.sv`, so the regression is green by construction. Gate: the
§9.2 differential passes over the full corpus for COPY, COMPARE, SEARCH,
CHAR_AT, ITER_NEXT, HASH.

**P5b — layout and tooling.** §3 handle and object in `encoding.py`,
`heap_image.py`, `image_from_source.py` and the RTL helpers; §10 memory map;
placement- and map-mirror tests extended. Host-side only — the core does not
yet use the new handle. Gate: host tests green, and `strmodel.py` reads
image-built objects correctly.

**P5c — cutover.** The core adopts the new handle, gains `S_STRACC`, wires
STRACC to the dmem port, and `pycore_string_mem.sv` is deleted along with the
`cont_str_win` plumbing. Add the write-full-line path to `pycore_cache.sv`.
Gate: every existing string fixture green at `CACHE_EN` 0 and 1.

**P5d — container integration.** Three-tier equality in dict/set probe,
`CONTAINS_OP`, `sorted`/`min`/`max`, `FOR_ITER`, `join`/`split` over LIST.
Gate: `img_str_dict_key_runtime` passes; all container fixtures green.

**P5e — method rollout**, in batches, each with fixtures and a differential
sweep:
1. SEARCH — `find` `rfind` `index` `rindex` `count` `startswith` `endswith`
   `replace` (replaces the firmware versions)
2. TRIM + CLASSIFY — `strip` family, the `is*` family
3. MAP — `upper` `lower` `swapcase` `capitalize` `title` `translate`
4. COPY/SPLIT — `join` `split` `rsplit` `splitlines` `partition` `rpartition`
   `center` `ljust` `rjust` `zfill` `expandtabs` `removeprefix` `removesuffix`

Method dispatch extends `pycore_native_method_id`: all 47 names are ≤ 12
bytes, so they are SHORT_STR constants and dispatch is a direct name compare
to a 6-bit id — no dict probe. Widen the id field from 4 to 6 bits.

**P5f — retire the firmware string builtins.** Delete `str_find.py`,
`str_join.py`, `str_startswith.py`, `str_endswith.py` once the hardware paths
are green, and reclaim their ROM slots.

## 13. Downstream effects

| Phase / artefact | Effect |
| --- | --- |
| **P3 (done)** | STRACC is a new dmem master. It is active only while the core is frozen in `S_STRACC`, so the §4 invalidation matrix is unchanged — but add a row saying so, and assert that `cmd_valid` never overlaps an excore-owned window. |
| **P4 (done)** | No effect. STRACC never touches the code address space. |
| **P6 CODC** | No effect. |
| **P7 GIC** | Global names are interned constants, so lookups stay tier 1 — the GIC still never enters STRACC. Confirm in the P7 tests. |
| **P9 re-measure** | New traffic class. Extend `memsim` with string workloads and a STRACC access model; re-run E1/E3/E7 with strings in dmem, which is what the L1D was sized for. |
| **`compile_plan.md`** | On-device `compile()` allocates string constants through `alloc_str`; add the cross-reference. |
| **`bytecode_support.md`** | Record the §6 Unicode ceiling next to the 64-bit `int` ceiling. |
| **`tags.md`** | Rewrite the LONG_STR row for the §3.1 handle. |
| **`object_model.md`** | Add the §3.2 STR object; remove the string-memory section. |

## 14. Open questions

* **Stride-map threshold.** 256 bytes is a guess. Measure once real non-ASCII
  workloads exist; until then the flag makes it free to change.
* **`replace` with a length-changing needle** needs either two passes (count,
  then build) or a growable output. Two passes is consistent with `join` and
  avoids reallocation — confirm the cost is acceptable on long strings.
* **Should `SA_CMP` return a three-way result** (`<`, `=`, `>`) so `sorted`
  needs one command instead of two? Cheap in hardware; decide in P5a.
* **Small-result bypass.** A concat of two SHORT strings whose result is 16–31
  bytes still needs an allocation. Worth a fast path that builds the result in
  registers and writes one or two words without entering the full engine?
