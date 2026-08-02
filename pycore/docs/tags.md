# PyCore tag map

Every architectural value is a 132-bit entry `{ tag[3:0], value[127:0] }`.
Numeric tags are contiguous for ALU decode. Secondary discriminators live in
the value field for `CONTROL` and `MUT_COLLEC`.

| Tag | Name | Notes |
|---|---|---|
| `0000` | CONTROL | `value[3:0]`: UNINIT=0, NONE=1, NULL=2 |
| `0001` | INT | signed i64 fast path in `value[63:0]` (sign-extended to 128) |
| `0010` | FLOAT | IEEE754 binary64 in `value[63:0]` |
| `0011` | COMPLEX | real `[63:0]`, imag `[127:64]` (binary64) |
| `0100` | BOOL | truth value in `value[0]` |
| `0101` | ITER | hybrid iterator payload (see architecture.md) |
| `0110` | TUPLE | `{ size[63:0], addr[63:0] }` |
| `0111` | SHORT_STR | inline ≤15 UTF-8 bytes |
| `1000` | LONG_STR | `{ len[127:64], addr[63:0] }` |
| `1001` | MUT_COLLEC | kind `[127:124]`: LIST=1, DICT=2, SET=3, BYTEARRAY=4; addr `[63:0]`; contamination bit `[123]` (see below) |
| `1010` | OBJECT | general heap object (`ob_head` kinds) |
| `1011` | RANGE | mode bit `value[127]`: 0 = inline i32 start/stop/step in `[95:0]`; 1 = pointer to a 3-tuple at `[63:0]` |
| `1100` | BYTES | reserved / partial |
| `1101` | CODE_OBJECT | |
| `1110` | TOMBSTONE | deleted-key / deleted-element sentinel in dict/set tables (never a live stack value) |
| `1111` | FROZENSET | reserved |

Compatibility aliases in RTL/tools: `PY_TAG_UNINIT` / `TAG_UNINIT` → CONTROL+CTL_UNINIT;
`PY_TAG_PTR` / `TAG_PTR` → ITER.

## MUT_COLLEC contamination bit (`value[123]`)

`PYCORE_MUT_CONTAM_BIT = 123` is a sticky flag on a `MUT_COLLEC` handle that
records whether a `PY_TAG_OBJECT` has ever been inserted into the collection
(for dicts, an OBJECT *key* only; values never contaminate). It is set at insert
time (`BUILD_MAP`/`BUILD_SET`/`SET_ADD`/`STORE_DICT`/`MAP_ADD`/`LIST_APPEND`) and
folded into the handle written back to the element's RF slot via
`pycore_mut_set_contaminated` / `pycore_make_mut(kind, addr, contaminated)`.

The bit routes bulk operations (`DICT_UPDATE`, `DICT_MERGE`, `SET_UPDATE`): when
both operands are uncontaminated the whole op is handed to the excore in one
recoverable trap (which hashes plain-value keys directly); if either side is
contaminated the excore's value-hash cannot be used, so the op must run entirely
in pycore (OBJECT keys hash by identity). It is metadata only — it never changes
the object's heap layout or `addr`, and helpers that just need the address
(`pycore_mut_addr`) ignore it. Tooling mirrors this with
`encoding.make_mut(..., contaminated=...)`, `mut_contaminated`, and
`mut_with_contam`.

## COMPLEX ALU

`pycore_complex_alu` supports ADD/SUB/MUL/TRUE_DIV/NEG/POS/EQ/NE/NOT.
Mixed INT/FLOAT/BOOL + COMPLEX operands normalize to complex in `pycore_exec`.
FLOOR_DIV / MOD / POWER / ordering compares on COMPLEX type-trap.

## RANGE encoding

Ranges that fit signed i32 start/stop/step use the inline form (mode=0).
Larger triples use mode=1 and point at a heap `(start, stop, step)` tuple.
