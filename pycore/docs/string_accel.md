# String Accelerator (STRACC) — as built

`pycore_str_accel.sv` owns every non-trivial string operation. Small
results on small strings stay on the pycore string ALU; everything else is
one STRACC command. There is no `pycore_string_mem`.

The design plan this was built from is
[`planning/string_accelerator_plan.md`](../../planning/string_accelerator_plan.md)
(historical; this file is the as-built source of truth).

---

## Handle and object

Canonical invariant: a string is `SHORT_STR` **iff** `kind == 1` and
`nchars <= 15`. Every other string is a heap object. STRACC must return
`SHORT_STR` for every qualifying result and must never emit a short
`LONG_STR`.

### LONG_STR handle (`value[127:0]`)

```
[31:0]    addr        object base in dmem
[63:32]   nchars      character count     → len(), bounds, O(1) index
[95:64]   hash        32-bit FNV-1a       → dict/set probe, fast reject
[119:96]  nbytes      payload bytes = nchars * kind
[121:120] kind        0/1/2 → 1/2/4-byte units
[127:122] flags       INTERNED, ALL_LOWER, ALL_UPPER
```

`len()`, `hash()`, `bool()`, bounds checks and the equality fast-reject are
handle arithmetic. Helpers: `pycore_stracc_*` in `pycore_defs.svh`,
`stracc_pack_long_handle` in `pycore/tools/encoding.py`.

SHORT_STR is kind-1 only: 4-bit size plus 15 inline bytes.

### Object in dmem

Header at `obj+0` mirrors the handle (addr replaced by 0). Payload is
contiguous from `obj+16`, padded to 16 B. Allocation uses `pycore_heap_place`
(64 B start-align when the object is a line or larger).

Fixed-width code units, as CPython `PyUnicodeObject`:

| kind | width | covers |
| ---: | ---: | --- |
| 1 | 1 byte | U+0000–U+00FF (Latin-1) |
| 2 | 2 bytes | U+0100–U+FFFF (BMP) |
| 4 | 4 bytes | U+10000+ |

Indexing and iteration are O(1) / one `SA_CHAR_AT` / `SA_ITER_NEXT` per
character for every kind.

Image constants and on-device `compile()` both go through
`HeapImageBuilder.alloc_str`, so interned payloads are byte-identical.

---

## Equality

Three tiers, cheapest first. Interning is an optimisation, not a
correctness requirement.

| Tier | Test | Resolves |
| --- | --- | --- |
| 1 | `addr_a == addr_b` | interned constants, identity |
| 2 | `(hash, nbytes, nchars, kind)` differ | almost every inequality |
| 3 | STRACC `SA_CMP` over payloads | equal, non-identical objects |

Dict/set probes issue tier 3 at `CP_DICT_CHK_VAL` when meta matches
(`pycore_str_need_payload_cmp`). That is what makes `d[a + b]` correct
(`img_str_dict_key_runtime`).

`COMPARE_OP` `==`/`!=` on strings: identical handles compare equal; mixed
SHORT/LONG is always false (canonical invariant). Same-tag SHORT_STR also
has lexicographic ordering. **LONG_STR ordering still TYPE-traps.**
`COMPARE_OP` equality of two distinct LONG objects with matching meta is
not the dict-probe path — interned constants that share a handle compare
equal (`img_str_eq`); a runtime concat vs an interned copy of the same
text does not, unless they happen to be the same object.

Dict hash for LONG_STR is the cached content hash in `value[95:64]`, not
`addr XOR len`.

---

## The unit

Own dmem master, same port contract as
[`memory_hierarchy.md`](memory_hierarchy.md). The core freezes in
`S_STRACC` for the duration (`stracc_dmem_active`). One instruction in
flight, so no extra coherence.

Engines in the RTL (`eng_e` in `pycore_str_accel.sv`):

COPY, CMP, SEARCH, HASH, CHAR, REPLACE, JOIN, TRIM, CLASSIFY, MAP, AFFIX,
EXPAND, SPLIT.

Throughput is limited by the single 128-bit dmem port: 16 / 8 / 4 code
units per cycle for kind 1 / 2 / 4.

ALU (no STRACC): `SHORT+SHORT` whose result is ≤15 bytes; SHORT vs SHORT
compare; `len` / `hash` / `bool` / identity; LONG equality fast-reject.

---

## Unicode ceiling

Structural ops (`len`, index, slice, iter, concat, compare, search, hash,
split, trim, pad, `ord`) are exact for all of Unicode.

**Case mapping and character classification are Latin-1 in hardware**
(U+0000–U+00FF, 256-entry LUT in the MAP/CLASSIFY lanes). Code points
above U+00FF raise a **recoverable firmware trap** — a performance
boundary, still correct. Affected: `upper` / `lower` / `swapcase` /
`capitalize` / `title` / `casefold` and the `is*` family.
`isidentifier` is firmware-only in v1 (XID_Start / XID_Continue).

This sits next to the 64-bit `int` ceiling in
[`bytecode_support.md`](bytecode_support.md): `int` is a correctness
ceiling (overflow wraps); the STRACC LUT is a performance ceiling.

---

## Fast paths (as built)

Answered from the handle, no memory: identity, `(hash, nbytes, nchars)`
reject, `len` / `hash` / `bool`, empty operands, `ALL_LOWER` / `ALL_UPPER`
no-ops for `lower()` / `upper()`.

Small result (kind-1, `nchars <= 15`): assemble in the destination
register, return SHORT_STR, no allocation — required by the canonical
invariant.

Runtime results are not interned. Revisit only if duplicate runtime
strings dominate the heap.

---

## Tests

`tb_str_accel.sv` covers the engines standalone against real memory, the
15/16-byte SHORT/LONG boundary, UTF-8/kind widening across word and line
boundaries, and OOM with the heap pointer unmoved. Image programs
`img_str_*` plus the CPython 3.14 differential harness
(`pycore/tools/strmodel.py`, `test_strmodel.py`).
