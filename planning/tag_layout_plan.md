# Tag layout (restructure) — historical plan

> Superseded by `pycore/docs/tags.md`. Kept only as planning history.

Primary 4-bit tags after the tag-space restructure. Numeric types are
contiguous for ALU decode. Secondary discriminators live in the value field
for `CONTROL` and `MUT_COLLEC`.

| Tag | Name | Notes |
|---|---|---|
| `0000` | CONTROL | `value[3:0]`: UNINIT=0, NONE=1, NULL=2 |
| `0001` | INT | signed i64 fast path in `value[63:0]` |
| `0010` | FLOAT | IEEE754 binary64 in `value[63:0]` |
| `0011` | COMPLEX | real `[63:0]`, imag `[127:64]` (binary64) |
| `0100` | BOOL | first-class |
| `0101` | ITER | was PTR; iterator payload unchanged |
| `0110` | TUPLE | immutable sequence handle |
| `0111` | SHORT_STR | inline ≤15 UTF-8 bytes |
| `1000` | LONG_STR | `{len[127:64], addr[63:0]}` |
| `1001` | MUT_COLLEC | kind `[127:124]`: LIST=1, DICT=2, SET=3, BYTEARRAY=4, DEQUE=5 reserved; addr `[63:0]` |
| `1010` | OBJECT | general heap object (`ob_head` kinds) |
| `1011` | RANGE | mode bit `value[127]`: 0 = inline i32 start/stop/step in `[95:0]`; 1 = pointer to 3-tuple at `[63:0]` |
| `1100` | BYTES | immutable bytes (reserved / partial) |
| `1101` | CODE_OBJECT | |
| `1110` | TOMBSTONE | dedicated deleted-key sentinel (no longer aliases DICT) |
| `1111` | FROZENSET | reserved |

## Aliases

- `PY_TAG_UNINIT` / `TAG_UNINIT` → `CONTROL` (+ `CTL_UNINIT`)
- `PY_TAG_PTR` / `TAG_PTR` → `ITER`

## COMPLEX ALU

`pycore_complex_alu` supports ADD/SUB/MUL/TRUE_DIV/NEG/POS/EQ/NE/NOT.
Mixed INT/FLOAT/BOOL + COMPLEX operands normalize to complex in `pycore_exec`.
FLOOR_DIV / MOD / POWER / ordering compares on COMPLEX type-trap.

## RANGE dual encoding

Small ranges that fit signed i32 start/stop/step use the inline form (mode=0)
for a fast path. Extended arguments that cannot fit 127 payload bits use
mode=1 and point at a heap `(start, stop, step)` tuple.
