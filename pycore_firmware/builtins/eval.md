# `eval` — implementation plan

Status: **in ROM** for code objects; string form **blocked** on `compile()`.

**Plan:** [`planning/compile_plan.md`](../../planning/compile_plan.md)
(string form) and [`planning/builtin_support.md`](../../planning/builtin_support.md).

## Goal

`eval(expression, globals=None)` evaluates an expression from a string or
code object and returns the result. `locals=` is deferred.

## Shipped

`eval(code)` calls the code object (`"eval"` mode ends in `RETURN_VALUE`).
`eval(code, globals)` uses `_bi_exec_globals` (same switch as `exec`).

## Remaining

String form is `eval(compile(source, filename, "eval"))` once ROM
`compile()` exists. Do not add a second parser.
