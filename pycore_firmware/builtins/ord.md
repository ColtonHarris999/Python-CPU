# `ord` — implementation plan

Status: **blocked** (stub in `ord.py`)

## Blockers

- STR `FOR_ITER` yields one-character `SHORT_STR` values, but pure Python
  cannot read the UTF-8 payload bits as an integer.
- No `BYTES` indexing helper or native `BI_ORD` exists.

## Next steps

1. Add a tiny on-core / excore helper `BI_ORD` that decodes a one-char
   SHORT_STR / LONG_STR lead sequence to an INT code point.
2. Firmware `ord.py` becomes a one-line call (or stays native like `len`).

## Implementation plan

| Phase | Work |
| --- | --- |
| A | Spec `BI_ORD` (argc=1, STR → INT); reject wrong length |
| B | Reuse STR `FOR_ITER` UTF-8 width decode logic in CALL path |
| C | Seed `ord` in builtins dict |
