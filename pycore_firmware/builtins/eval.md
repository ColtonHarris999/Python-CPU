# `eval` — implementation plan

Status: **in ROM** for code objects and string form (`_bi_code_kind` +
ROM `compile()`, compiler_design.md §11.1).

**As built:** [`pycore/docs/compiler.md`](../../pycore/docs/compiler.md). Design
history: [`planning/old/compiler_design.md`](../../planning/old/compiler_design.md) §11.1.

## Goal

`eval(expression, globals=None)` evaluates an expression from a string or
code object and returns the result. `locals=` is deferred.

## Shipped

`eval(code)` calls the code object (`"eval"` mode ends in `RETURN_VALUE`).
`eval(code, globals)` uses `_bi_exec_globals` (same switch as `exec`).
T1 expressions go through ROM `compile()`:
`eval(compile("1 + 2", "<s>", "eval")) == 3` (`img_compile_eval_expr`).
String form `eval("1+2")` probes `_bi_code_kind` and compiles SHORT_STR
(7) / LONG_STR (8) source (`img_eval_str_direct`, `img_eval_str_long`).

Host CPython cannot `eval` a firmware-emitted `_HostEmittedCode`;
`run_image_test.py` calls the object when the argument is callable and
not a `types.CodeType`. SEED_CODE images still use real `CodeType`.
