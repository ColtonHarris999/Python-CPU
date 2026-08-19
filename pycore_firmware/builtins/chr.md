# `chr` — shipped

Status: **native** (`BI_CHR`, builtin id 11)

## What shipped

`chr(i)` is a hardware CALL fast path that owns the `chr` entry in the boot
builtins dict. It encodes a code point as 1–4 UTF-8 bytes directly into an
inline `SHORT_STR` handle — one cycle, no allocation, no `string_mem` write.

The original blocker was "no pure-Python way to build a `SHORT_STR` from an
integer code point". Since the result is at most 4 bytes it always fits inline,
so no string heap is involved at all.

## Behaviour

| Input | Result |
| --- | --- |
| `INT` / `BOOL` in `0 .. 0x10FFFF`, non-surrogate | One-character `SHORT_STR` |
| `> 0x10FFFF` | `PY_TRAP_TYPE` (CPython raises `ValueError`) |
| Negative | `PY_TRAP_TYPE` (high value bits set) |
| Surrogate `0xD800..0xDFFF` | `PY_TRAP_TYPE` — **deviation**, see below |
| Non-int | `PY_TRAP_TYPE` |
| `argc != 1` | `PY_TRAP_CALL_FILTER` |

## Deviation: lone surrogates are rejected

CPython allows `chr(0xD800)`, producing a lone surrogate. PyCore stores strings
as UTF-8 and surrogates have no well-formed UTF-8 encoding, so accepting them
would put ill-formed bytes into `string_mem` and into `SHORT_STR` payloads that
`BI_LEN`, STR `FOR_ITER`, and `s[i]` all assume are valid.

Rejecting them keeps a useful invariant: `ord(chr(n)) == n` for every `n` that
`chr` accepts. Covered by `img_builtin_chr_surrogate_trap`.

## Coverage

`img_builtin_chr`, `img_builtin_ord_unicode` (2/3/4-byte encodings plus the
round trip), `img_builtin_chr_range_trap`, `img_builtin_chr_surrogate_trap`.

Pairs with [`ord.md`](ord.md).
