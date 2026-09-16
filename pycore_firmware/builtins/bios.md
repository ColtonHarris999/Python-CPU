# `bios` — ROM payload exec

Status: **in ROM** (compiler_design.md §11.7). One-arg wrapper that
`exec`s a string or code object in the caller's globals.

**Design:** [`planning/compiler_design.md`](../../planning/compiler_design.md)
§11.7.

## API

```python
bios(payload) -> None
```

`payload` is whatever ROM `exec` accepts (SHORT_STR / LONG_STR compiled
via `compile(source, "<string>", "exec")`, or a code object). Returns
`None`. Wrong argc is `CALL_FILTER`.

## Coverage

| Image | Expect |
| --- | --- |
| `img_bios_exec` | **3** — `bios("x = 1 + 2")` then return `x` |
