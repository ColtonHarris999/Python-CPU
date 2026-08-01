# `open` — implementation plan

Status: **blocked** (stub in `open.py`)

## Goal

`open(file, mode='r', ...)` returns a file object.

## Blockers

1. **No filesystem** in the pycore/excore prototype (no block device, no
   host FS ABI beyond optional future MMIO).
2. **No `file` / `TextIO` object kind** in the tag/object model.
3. **Keyword-heavy signature** (`mode`, `encoding`, `buffering`, …) needs
   `CALL_KW`.
4. **Context manager protocol** (`with`) needs `BEFORE_WITH` /
   exception-path opcodes (deferred).

## Next steps

1. Decide product shape: host-backed MMIO console only vs. real FS.
2. If console-only: implement `print` / `input` first; leave `open` unsupported.
3. If FS: define excore syscalls (`OPEN`/`READ`/`WRITE`/`CLOSE`) and a
   `OBK_FILE` heap kind with methods folded like image types.

## Implementation plan

| Phase | Work | Depends on |
| --- | --- | --- |
| A | Spec `OBK_FILE` + excore syscall numbers | excore MMIO |
| B | Native/excore `BI_OPEN` returning file handle | A |
| C | Method folding: `read`/`write`/`close` on type dict | image class folding |
| D | Pure-Python wrapper matching CPython defaults | B, `CALL_KW` or positional-only API |

## Recommendation

Out of scope for firmware builtins until an I/O device story exists; keep
the stub and route energy into `print` (already excore-trapped).
