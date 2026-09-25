# `exec` — implementation plan

Status: **in ROM** for code objects and string form (`_bi_code_kind` +
ROM `compile()`, compiler_design.md §11.1).

**As built:** [`pycore/docs/compiler.md`](../../pycore/docs/compiler.md). Design
history: [`planning/old/compiler_design.md`](../../planning/old/compiler_design.md) §11.1.

`exec(code_object)` needs **no further hardware**: `CALL` on a
`CODE_OBJECT` already works, and `STORE_NAME` / `LOAD_NAME` already
target the module globals dict. String form probes the argument tag
and compiles SHORT_STR / LONG_STR source.

## Goal

`exec(object, globals=None)` runs statements from a string or code object
for side effects (returns `None`). `locals=` is deferred.

## Shipped

`exec(code)` calls the object and returns `None`. `exec(code, globals)`
switches `globals_base_r` via `_bi_exec_globals` and restores on return.
`exec("x = 1")` is `exec(compile(source, "<string>", "exec"))` after a
`_bi_code_kind` probe (tag 7 or 8). Non-string / non-code still
CALL_FILTER-traps on `code()` (`img_exec_bad_arg_trap` → trap 6).

Host CPython code objects are not callable; `run_image_test.py` injects a
stand-in. The device runs `exec.py`.

## Coverage

| Image | Expect |
| --- | --- |
| `img_exec_str_direct` | **3** (`exec("x = 1 + 2")`) |
| `img_exec_bad_arg_trap` | **6** (`CALL_FILTER` on `exec(5)`) |
