# `chr` — implementation plan

Status: **blocked** (stub in `chr.py`)

## Blockers

- No pure-Python way to build a `SHORT_STR` / `LONG_STR` from an integer
  code point (string concat only joins existing strings).
- UTF-8 encoding of non-ASCII needs a byte→string path.

## Next steps

1. Native/excore `BI_CHR`: INT → one-char SHORT_STR (UTF-8 in payload for
   cp ≤ 0x10FFFF; reject surrogates / out of range).
2. Mirror the STR iterator's UTF-8 width table for encoding.

## Implementation plan

| Phase | Work |
| --- | --- |
| A | Spec `BI_CHR` + range checks |
| B | Encode to SHORT_STR (1–4 bytes) or LONG_STR if ever needed |
| C | Seed `chr` in builtins dict; pair with `ord.md` |
