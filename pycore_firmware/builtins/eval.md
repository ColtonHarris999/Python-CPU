# `eval` — implementation plan

Status: **in ROM** for code objects; string form is
`eval(compile(source, filename, "eval"))` (step I). Auto str-vs-code
dispatch still needs `_bi_code_kind` (compiler_design.md §11).

**Plan:** [`planning/compiler_design.md`](../../planning/compiler_design.md)
and [`planning/builtin_support.md`](../../planning/builtin_support.md).

## Goal

`eval(expression, globals=None)` evaluates an expression from a string or
code object and returns the result. `locals=` is deferred.

## Shipped

`eval(code)` calls the code object (`"eval"` mode ends in `RETURN_VALUE`).
`eval(code, globals)` uses `_bi_exec_globals` (same switch as `exec`).
T1 expressions go through ROM `compile()`:
`eval(compile("1 + 2", "<s>", "eval")) == 3` (`img_compile_eval_expr`).

Host CPython cannot `eval` a firmware-emitted `_HostEmittedCode`;
`run_image_test.py` calls the object when the argument is callable and
not a `types.CodeType`. SEED_CODE images still use real `CodeType`.

## Remaining

Do not add a second parser. String-form `eval("1+2")` waits on a tag
probe (`_bi_code_kind` or `__class__` on native tags).
