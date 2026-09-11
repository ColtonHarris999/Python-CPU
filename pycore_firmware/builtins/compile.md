# `compile` — implementation plan

Status: **blocked** (stub in `compile.py`)

**Plan:** [`planning/compile_plan.md`](../../planning/compile_plan.md)

Host oracle: `vendor/pycpython` ([PyCPython](https://github.com/ColtonHarris999/PyCPython)).
Firmware port: `pycore_firmware/compiler/` (not present yet). Do not run
the vendor tree on the hart. The old PyPy tokenizer plan is abandoned.

## Goal

`compile(source, filename, mode)` with `flags==0` returns a code object
usable by `eval` / `exec`. First success:
`eval(compile("1 + 2", "<s>", "eval")) == 3`.

## Blockers

1. **No compiler on the hart.** Port a PyCore subset of PyCPython into
   `pycore_firmware/compiler/` (LL(1), tagged-list AST, no PEG).
2. **Code-object fabrication.** Need `_bi_code_alloc` / `_bi_code_emit` /
   `_bi_code_new`. Fetch still hard-wires `imem_we=0`. Host
   `HeapImageBuilder.alloc_code` is the stand-in until that lands.
3. **`"single"` / nonzero `flags` / AST input** — out of v1 (`ValueError`).

Keyword calls (`CALL_KW`) and catchable `SyntaxError` + `e.args` already
work on main.

## Sequence

F1 emit primitives → tokenizer/parser/codegen subset → ROM `compile` →
string `exec`/`eval`. Details and banned constructs:
[`planning/compile_plan.md`](../../planning/compile_plan.md).
