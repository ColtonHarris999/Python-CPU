# `ord` — shipped

Status: **native** (`BI_ORD`, builtin id 10)

## What shipped

`ord(c)` is a hardware CALL fast path that owns the `ord` entry in the boot
builtins dict. It decodes a one-character UTF-8 string to its code point in a
single cycle with no dmem or `string_mem` access.

## Why it turned out to be cheap

The original blocker was "no pure-Python way to read the payload bytes as an
integer". Two observations collapsed the rest of the work:

1. **A one-character string is always a `SHORT_STR`.** Every string of ≤15
   bytes is `SHORT_STR` — `tag_constant` chooses by encoded length, runtime
   concatenation in `pycore_string_mem.sv` does the same, and `s[i]`
   (`CONT_SUBSCR_STR`) returns `SHORT_STR`. A character is at most 4 bytes, so
   `ord` never needs to touch `string_mem`, and a `LONG_STR` argument is by
   construction longer than one character — a length error.
2. **The UTF-8 primitives already existed** for STR `FOR_ITER` and `s[i]`:
   `pycore_utf8_char_width`, `pycore_utf8_cont_valid`, and
   `pycore_short_str_byte`. Only the payload-bits-to-code-point step was new
   (`pycore_utf8_decode`).

## Behaviour

| Input | Result |
| --- | --- |
| One-character `SHORT_STR` | `INT` code point |
| Multi-character string | `PY_TRAP_TYPE` (CPython raises `TypeError`) |
| Empty string | `PY_TRAP_TYPE` |
| `LONG_STR` | `PY_TRAP_TYPE` (always > 1 character) |
| Non-string | `PY_TRAP_TYPE` |
| Malformed UTF-8 (bad lead / continuation) | `PY_TRAP_TYPE` |
| `argc != 1` | `PY_TRAP_CALL_FILTER` |

Overlong encodings are not rejected, matching STR `FOR_ITER` and `s[i]`: they
cannot be produced by the image tooling, `chr`, concatenation, or `s[i]`.

## Coverage

`img_builtin_ord`, `img_builtin_ord_unicode` (2/3/4-byte widths plus an
`ord(chr(n))` round trip), `img_builtin_ord_scan` (`ord(s[i])` classification
loop), `img_builtin_ord_len_trap`, `img_builtin_ord_type_trap`.

Pairs with [`chr.md`](chr.md).
