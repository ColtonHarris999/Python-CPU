# `exec` — implementation plan

Status: **in ROM** for code objects; string form **blocked** on `compile()`.

**Plan:** [`planning/compile_plan.md`](../../planning/compile_plan.md)
(string form) and [`planning/builtin_support.md`](../../planning/builtin_support.md).

`exec(code_object)` needs **no further hardware**: `CALL` on a
`CODE_OBJECT` already works, and `STORE_NAME` / `LOAD_NAME` already
target the module globals dict.

## Goal

`exec(object, globals=None)` runs statements from a string or code object
for side effects (returns `None`). `locals=` is deferred.

## Shipped

`exec(code)` calls the object and returns `None`. `exec(code, globals)`
switches `globals_base_r` via `_bi_exec_globals` and restores on return.

Host CPython code objects are not callable; `run_image_test.py` injects a
stand-in. The device runs `exec.py`.

## Remaining

String form waits on ROM `compile()`. v1 can stay
`exec(compile(source, filename, "exec"))`.
