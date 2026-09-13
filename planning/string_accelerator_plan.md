Graduated to [`pycore/docs/string_accel.md`](../pycore/docs/string_accel.md)
(as-built). This file is the design history; do not treat its "will be" /
"today `string_mem`" language as current.

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
| `len(s)` for any string | `nchars` is in the handle (§3.2) |
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

### 3.1 Representation: fixed-width code units, as CPython does

**Decision (open question 1, resolved for maximum program coverage).** Payloads
are **fixed-width code units**, not UTF-8, selected by the string's maximum
code point exactly as CPython's `PyUnicodeObject` does:

| kind | width | covers | example |
| ---: | ---: | --- | --- |
| 1 | 1 byte | U+0000–U+00FF (Latin-1) | ASCII, Western European |
| 2 | 2 bytes | U+0100–U+FFFF (BMP) | Greek, Cyrillic, CJK, Hebrew |
| 4 | 4 bytes | U+10000+ | emoji, rare scripts |

An earlier draft stored UTF-8 with an ASCII flag and a stride map for
indexing. Fixed width is better on every axis that matters here:

* **Indexing is O(1) for every string**, not just ASCII. No stride map, no
  threshold to guess, no O(n) cliff for non-ASCII programs. That is the direct
  answer to "support the largest number of Python programs".
* **Every code unit is word-aligned.** 1, 2 and 4 all divide 16, so a
  character can never straddle a 128-bit word or a 64-byte line. This deletes
  an entire class of hardware (the UTF-8 decoder in the datapath) and an
  entire class of bugs.
* **It is usually smaller.** Measured on representative samples: ASCII 31 B
  either way; Latin-1 accented text 23 B fixed vs 29 UTF-8; CJK 20 B fixed vs
  30 UTF-8. It loses only when one high code point widens an otherwise narrow
  string (mixed-script Greek, an emoji in ASCII prose) — the same trade CPython
  accepts, for the same reason.
* **Semantics match CPython exactly**, including `ord()`, indexing and
  iteration, because it is the same model.

The cost is a transcode from the UTF-8 source bytes, paid once at image build
(§11) or at construction, and a widening step when concatenating mixed kinds
(§4.2).

### 3.2 Handle (register file / stack entry)

Report finding F4 says the interpreter's cost is *chain length*, not miss
latency — so every hot field lives in the handle and the header is never read
for metadata:

```
LONG_STR value[127:0]:
  [31:0]    addr        object base address in dmem
  [63:32]   nchars      character count        → len(), bounds checks, O(1) index
  [95:64]   hash        32-bit content hash    → dict/set probe, fast reject
  [119:96]  nbytes      payload bytes = nchars * kind
  [121:120] kind        1 / 2 / 4 encoded as 0 / 1 / 2
  [127:122] flags       bit0 INTERNED, bit1 ALL_LOWER, bit2 ALL_UPPER, rest reserved
```

`len()`, `hash()`, `bool()`, bounds checks, the kind test and the equality fast
reject are all zero-memory operations on the handle. Only the payload needs
dmem. `nbytes` at 24 bits caps one string at 16 MB, above the whole data map.

The `ALL_LOWER` / `ALL_UPPER` hints are set at construction and drive the
no-op fast paths in §7.

SHORT_STR is unchanged in shape: `size` in `value[127:124]`, 15 bytes in
`value[123:4]` — and is **kind-1 only**.

> **Canonical-representation invariant (load-bearing).** A string is SHORT_STR
> iff `kind == 1 and nchars <= 15`. Every other string is a heap object. Two
> equal strings therefore always get the same representation, cross-tag
> comparison is always false, and hashing stays consistent. STRACC must return
> SHORT_STR for every qualifying result and must never emit a short LONG_STR.

### 3.3 Object in dmem

Strings are immutable, so unlike a list there is no relocatable buffer and no
indirection — header and payload are contiguous:

```
obj + 0    header  { flags[127:122], kind[121:120], nbytes[119:96],
                     hash[95:64], nchars[63:32], reserved[31:0] }
obj + 16   payload code units  0..(16/kind - 1)
obj + 32   next 16 bytes of payload
   ...                              (padded to a 16-byte multiple)
```

The header mirrors the handle so the object is self-describing for the
accelerator, the image builder, and anything walking the heap. The handle is
the fast path; the header is the source of truth.

Allocation uses `pycore_heap_place` (P1 line alignment), so a string ≥ 64 bytes
starts on a cache line and streams one line per fill.

`hash`, `nchars`, `kind` and the case flags are computed **eagerly at
construction** — by the image builder for constants, by STRACC for runtime
results. There is no lazy-hash state machine and no "not yet valid" case.

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
which is what §10 does.

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
             widening funnel shifter (32B → 16B, unit-granular,
                      kind-1→2, kind-1→4, kind-2→4 widen in flight)
                              │
        ┌────────────┬────────┴────────┬──────────────┐
        ▼            ▼                 ▼              ▼
   compare lane   map lane        classify lane   hash accumulator
   (16/8/4 units) (Latin-1 LUT)   (Latin-1 LUT)   (rolling, 32b)
        │            │                 │              │
        └────────────┴────────┬────────┴──────────────┘
                              ▼
                    dst window ──► dmem wdata + wstrb
```

The **widening funnel shifter** is the one substantial new datapath block. It
does two jobs at once: realign the source to the destination's byte phase
(concatenating strings whose lengths are not multiples of 16), and widen
code units when the operands' kinds differ (`kind-1 + kind-2 → kind-2`). Both
are unit-granular selects, not the byte-serial UTF-8 decoder the earlier draft
needed — fixed-width units are always word-aligned, so there is no
variable-length decode anywhere in the pipeline.

Throughput per cycle, limited by the single 128-bit dmem port:

| kind | units/cycle |
| ---: | ---: |
| 1 | 16 |
| 2 | 8 |
| 4 | 4 |

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
| **COMPARE** | `SA_CMP` | **three-way**: returns `-1 / 0 / +1`. All six operators and `sorted`/`min`/`max` derive from one command (open question 3, resolved yes) |
| **SEARCH** | `SA_SEARCH` | `FIND RFIND COUNT CONTAINS STARTSWITH ENDSWITH` (+ start/end) |
| **MAP** | `SA_MAP` | `UPPER LOWER SWAPCASE CAPITALIZE TITLE TRANSLATE` |
| **CLASSIFY** | `SA_CLASSIFY` | `ALNUM ALPHA ASCII DIGIT LOWER SPACE TITLE UPPER` |
| **TRIM** | `SA_TRIM` | `LEFT RIGHT BOTH` (+ character set) |
| **SPLIT** | `SA_SPLIT` | `SPLIT RSPLIT SPLITLINES PARTITION RPARTITION` → LIST/TUPLE |
| **HASH** | `SA_HASH` | internal; runs on every construction |

Plus two element ops the container FSM hands over: `SA_CHAR_AT` (subscript —
now a single indexed read at `addr + 16 + i*kind`, O(1) for every kind) and
`SA_ITER_NEXT` (one character for `for c in s`).

**Two-pass sizing is the standard protocol** for every op whose output size is
not known from the operands (open question 2, resolved for maximum coverage).
Pass 1 measures — counts matches, sums element lengths, determines the result
kind — and validates operand types. Pass 2 allocates exactly once and fills.
This is what lets `replace` handle a length-changing needle, `join` handle any
iterable, and `split` size its list, all without reallocation, and it means a
type error or an out-of-heap condition is detected **before** the heap pointer
moves. Ops on this protocol: `replace`, `join`, `split` / `rsplit` /
`splitlines`, `expandtabs`, `translate` (which can delete), and any op whose
operands differ in kind (pass 1 determines the widened result kind).

Ops with a computable output size — `concat`, `repeat`, `slice`, `pad`, `trim`,
`upper`/`lower`/`swapcase` — allocate directly and run single-pass.

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

## 6. Unicode coverage and the one remaining ceiling

Fixed-width code units (§3.1) mean **every structural operation is exact for
all of Unicode**, with no ceiling at all: `len`, indexing, slicing, iteration,
concat, repeat, compare, search, hash, split, partition, trim, pad and `ord`
operate on code points and are correct for any input CPython accepts.

The only remaining ceiling is **case mapping and character classification**,
which need Unicode property tables:

* **Hardware covers Latin-1** (U+0000–U+00FF) with a 256-entry LUT in the map
  and classify lanes. That is ASCII plus Western European, at full throughput.
* **Code points above U+00FF raise a recoverable trap** handled in firmware,
  which does the table lookup. Slower, but **correct** — no program is ever
  silently wrong, which is the difference from the earlier ASCII-only draft.
* The firmware table can grow toward full Unicode over time without any RTL
  change, because the trap boundary is already there.

Affected methods: the MAP family (`upper` `lower` `swapcase` `capitalize`
`title` `casefold`) and the CLASSIFY family (the eleven `is*` methods).
`isidentifier` additionally needs the XID_Start/XID_Continue properties and is
firmware-only in v1.

Record this in `pycore/docs/bytecode_support.md` next to the 64-bit `int`
ceiling — but note it is a *performance* boundary for non-Latin-1 text, not a
correctness one.

## 7. Fast paths

Open question 4 was "should there be a small-result bypass" — yes, and the same
reasoning turns up a family of them. Every one of these produces the answer
with **zero allocations**, and most with **zero memory accesses**, so they are
checked in the command-decode cycle before the engine starts.

### 7.1 Answered from the handle alone — no memory at all

| Fast path | Applies to | Result |
| --- | --- | --- |
| **Identity** — `addr_a == addr_b` | `==` `!=` `<=` `>=` `in` `find` `startswith` `endswith` `count` | equal / found at 0 / 1 occurrence |
| **Fast reject** — `(hash, nbytes, nchars, kind)` differ | `==` `!=`, dict/set probe, list `in` | unequal |
| **Length reject** — `len(needle) > len(haystack)` | `find` `rfind` `index` `count` `in` `startswith` `endswith` `replace` | miss (−1 / False / 0 / receiver) |
| **Kind reject** — needle kind > haystack kind | all SEARCH variants | miss: a code point that cannot occur in the haystack's kind cannot be in it |
| **Empty operand** — `len == 0` | `"" + s`, `s + ""`, `s * n≤0`, `s[i:i]`, `"".join`, empty needle | receiver handle or `""`, no work |
| **`len`, `hash`, `bool`, `ord` of a 1-char string** | — | straight from the handle (§2) |
| **Already-normalised** — `ALL_LOWER` / `ALL_UPPER` flags | `lower()` on lowercase, `upper()` on uppercase | **return the receiver handle** |

The kind reject is worth calling out: searching for a CJK needle in an ASCII
haystack is answered in one cycle with no memory traffic, purely from the kind
fields. Fixed-width representation is what makes that test exist.

### 7.2 Answered without allocating — return the receiver

Python strings are immutable, so an operation that would produce an identical
string may return the *same object*. The map, trim and search lanes detect this
during their measuring pass and skip pass 2 entirely:

| Fast path | Example that hits it |
| --- | --- |
| MAP produced no change | `s.upper()` on already-uppercase text, `s.translate(t)` with no mapped character |
| TRIM found nothing to strip | `line.strip()` on already-clean input |
| SEARCH found no match | `s.replace(a, b)` where `a` does not occur |
| PAD width ≤ current width | `s.ljust(4)` on a 10-character string |
| SPLIT with no separator present | `s.split(",")` on a comma-free string (one-element list, receiver reused as the element) |

This matters for real programs: normalisation loops that call `.strip()`,
`.lower()` or `.replace()` on already-clean data do **no allocation at all**,
where the naive implementation allocates a copy per call and churns the bump
heap toward OOM.

### 7.3 Answered without touching the heap — build in registers

| Fast path | Condition | Behaviour |
| --- | --- | --- |
| **Small result** | result is kind-1 and ≤ 15 characters | assemble in the destination register, return SHORT_STR, no allocation — the §3.2 canonical invariant *requires* this, and it is now universal across `concat` `slice` `repeat` `strip` `pad` `upper` `lower` `replace` `join` `partition`, not just concat |
| **Single-word operands** | both payloads ≤ 16 bytes | one read each; compare, search and hash complete in the first engine cycle |
| **Medium result** | result ≤ 64 bytes (≤ 4 words) | allocate, then one burst write — no loop, no line straddle |

### 7.4 Early-out inside the engines

| Fast path | Engine |
| --- | --- |
| First differing word ends the comparison | COMPARE — a 1 MB string pair that differs in byte 3 answers in one cycle |
| First non-matching classify unit ends the pass | CLASSIFY — `isdigit()` on `"a..."` is one cycle |
| Match at position 0 ends the scan | SEARCH `find` / `startswith` |
| Scan from the correct end | SEARCH `rfind` / `rindex` / `rstrip` / `rsplit` walk backwards rather than scanning forward and keeping the last hit |
| Stop at `end`, start at `start` | SEARCH with explicit bounds never reads outside them |

### 7.5 What is deliberately *not* fast-pathed

Interning of runtime results. It would need a hash table and a probe on every
construction to save an allocation that tier-1 equality (§3.4) already makes
cheap to compare. Revisit only if measurement shows duplicate runtime strings
dominating the heap.

## 8. Container interaction

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

## 9. Allocation and traps

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

## 10. Verification — standalone first

The unit is verified **as its own design against real memory**, before a single
line of the core changes. This is the phase that de-risks the cutover.

### 10.1 `tb_str_accel.sv`

`pycore_str_accel` + `pycore_ram` (and optionally an L1D, to measure the
write-full-line path). Commands are driven directly; no core.

Directed cases, per engine:

* **Boundaries:** empty string; 1 byte; exactly 15 and exactly 16 bytes (the
  SHORT/LONG boundary — a 16-byte result must be LONG, a 15-byte result must be
  SHORT); exactly one line (64 B); one byte over a line.
* **Alignment:** every source/destination byte phase 0..15 through the funnel
  shifter; a copy whose source and destination overlap in the same line.
* **Kinds:** every operand-kind pair (1×1, 1×2, 1×4, 2×2, 2×4, 4×4) through
  concat and compare, checking the widened result kind; a string that is
  Latin-1 except for its last character (kind 2 with a single wide unit); a
  kind-4 string; `ord()` at the top of each kind's range (U+00FF, U+FFFF,
  U+10FFFF). Because every unit is word-aligned there is no straddle case —
  assert that instead: no engine ever issues an unaligned unit read.
* **Allocation:** OOM exactly at `PYCORE_HEAP_LIMIT`; OOM mid-`join` (heap
  pointer must not move); line alignment of every result.
* **Search:** needle longer than haystack; empty needle; needle at position 0,
  at the end, spanning a word boundary; overlapping matches for `count`;
  needle of a wider kind than the haystack (§7.1 kind reject).
* **Fast paths (§7):** each one exercised *and* verified not to fire when it
  must not — an identity compare on distinct-but-equal strings must reach the
  content compare, `s.upper()` on mixed case must allocate, `s.strip()` on
  padded input must allocate. A fast path that fires wrongly returns a wrong
  answer; a fast path that never fires is only slow. Both are tested.

### 10.2 The differential harness — the real test

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

### 10.3 Integration verification

* Every existing string fixture (`img_str_*`, `img_build_string`,
  `img_sorted_str`, `img_for_iter_str_*`, `img_slice_str_clamp`,
  `img_list_repeat_jaro`) stays green through the cutover.
* New: `img_str_dict_key_runtime` — `d[a + b]` where `a + b` is built at
  runtime and equals an interned constant key. **This fails on today's main**
  and is the fixture that proves §3.4.
* One image fixture per method batch in P5e.
* The transparency and latency gates from P0/P2 keep applying — STRACC must
  produce identical results at `CACHE_EN` 0 and 1 and at every `MEM_LATENCY`.

## 11. Memory map

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

## 12. Compile-time strings

`encoding.py::StringHeapBuilder` is replaced by
`HeapImageBuilder.alloc_str(text)`, which takes a Python `str`, picks the kind
from `max(ord(c))`, **transcodes to fixed-width code units**, and emits a §3.3
object into the object heap with `hash`, `nchars`, `nbytes`, `kind` and the
case flags filled in. Interning stays (dedupe by content) and sets
`flags.INTERNED`.

The transcode is the one new cost, and it is paid once at build time. The host
model and the RTL must agree bit-for-bit on the resulting payload, which the
§10.2 differential checks directly.

`--string-hex`, the `STRING_HEX` plusarg, `pycore/programs/string_mem.hex` and
the `string_heap` parameter threaded through `tag_constant` all disappear. One
image, one heap.

This is also the hook the future on-device `compile()` needs: it allocates
string constants with the same routine, so a compiled-on-device module and an
image-built module produce byte-identical string objects. Note that in
`planning/compile_plan.md`.

## 13. Phases

Each ends with the full regression green.

**P5a — the unit, standalone.** `pycore_str_accel.sv`, `tb_str_accel.sv`,
`strmodel.py`, `strgen.py`. Not wired into the core; the core still uses
`pycore_string_mem.sv`, so the regression is green by construction. Gate: the
§10.2 differential passes over the full corpus for COPY, COMPARE, SEARCH,
CHAR_AT, ITER_NEXT and HASH, across **every operand-kind pair**, with every §7
fast path both exercised and proven not to fire when it must not.

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

## 14. Downstream effects

| Phase / artefact | Effect |
| --- | --- |
| **P3 (done)** | STRACC is a new dmem master. It is active only while the core is frozen in `S_STRACC`, so the §4 invalidation matrix is unchanged — but add a row saying so, and assert that `cmd_valid` never overlaps an excore-owned window. |
| **P4 (done)** | No effect. STRACC never touches the code address space. |
| **P6 CODC** | No effect. |
| **P7 GIC** | Global names are interned constants, so lookups stay tier 1 — the GIC still never enters STRACC. Confirm in the P7 tests. |
| **P9 re-measure** | New traffic class. Extend `memsim` with string workloads and a STRACC access model; re-run E1/E3/E7 with strings in dmem, which is what the L1D was sized for. |
| **`compile_plan.md`** | On-device `compile()` allocates string constants through `alloc_str`; add the cross-reference. |
| **`bytecode_support.md`** | Record the §6 case/classification boundary next to the 64-bit `int` ceiling — note it is a performance boundary, not a correctness one. |
| **`tags.md`** | Rewrite the LONG_STR row for the §3.2 handle (kind field, cached hash). |
| **`object_model.md`** | Add the §3.3 STR object; remove the string-memory section. |

## 15. Decisions taken, and what is still open

### Resolved

1. **Representation — fixed-width code units, not UTF-8 with a stride map.**
   The original question was where to set a stride-map threshold; the answer
   "support the largest number of Python programs" makes the threshold question
   go away entirely. Fixed width gives O(1) indexing for every string, matches
   CPython's model exactly, is usually smaller, and word-aligns every code unit
   so the UTF-8 decoder disappears from the datapath (§3.1).
2. **Two-pass sizing is the standard protocol** for every op whose output size
   is not computable from its operands — `replace` with a length-changing
   needle, `join`, `split`, `expandtabs`, `translate`, and any mixed-kind
   operation. Exact, never reallocates, and detects type errors and OOM before
   the heap pointer moves (§4.3).
3. **`SA_CMP` is three-way**, returning `−1 / 0 / +1`. All six comparison
   operators and `sorted` / `min` / `max` derive from one command (§4.3).
4. **Fast paths everywhere**, not just the small-result bypass: a full family
   in §7 — handle-only answers, receiver reuse when an operation would produce
   an identical string, register-built small results, and early-outs inside
   every engine.

### Still open

* **Firmware Unicode tables.** §6 traps to firmware above U+00FF for case and
  classification. How much of the Unicode property database goes into ROM, and
  whether it ships in P5e or later, is a size question for the ROM budget —
  not a design question for this unit.
* **`isidentifier`** needs XID_Start / XID_Continue and is firmware-only in
  v1. If it turns out to be hot, it earns a hardware table.
* **`SA_SPLIT` result shape.** `split` returns a LIST, `partition` a TUPLE.
  Whether the accelerator allocates both directly or hands the core a run
  vector to materialise is a P5a implementation call; the differential does
  not care which.
* **Whether `SA_HASH` should be exposed as a standalone command.** It runs
  implicitly on every construction; a separate command is only needed if
  something outside STRACC wants to hash a byte range.
