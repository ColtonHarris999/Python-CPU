# `compile` — implementation plan

Status: **T0 + A.** Stub in `compile.py`; subset gate and occupancy
baseline are green. Design:
[`planning/compiler_design.md`](../../planning/compiler_design.md).
Living notes: [`pycore/docs/compiler.md`](../../pycore/docs/compiler.md).

Host oracle: `vendor/pycpython` ([PyCPython](https://github.com/ColtonHarris999/PyCPython)).
Firmware port: `pycore_firmware/compiler/`. Do not run the vendor tree on
the hart.

## Goal

`compile(source, filename, mode)` with `flags==0` returns a code object
usable by `eval` / `exec`. First success:
`eval(compile("1 + 2", "<s>", "eval")) == 3`.

## Current

- **T0.** `img_str_eq_runtime_long`, `img_compile_ns_inherit`, measured ROM
  occupancy in `test_compiler_rom_occupancy.py`.
- **A.** `test_compiler_subset.py` is red on `xs[-1]`, `xs[1:]`, `class`,
  closures, and an over-cap frame window. `compat.py` is the rewrite kit.

## Still blocked for a working `compile()`

1. **Step B.** RF ring window + locals lift.
2. **Step C.** `_bi_code_alloc` / `_bi_code_blit` / `_bi_code_patch` /
   `_bi_code_new` and the code-memory write path.
3. **Steps E–I.** Lexer, parser, symtab, T1 codegen, assembler, ROM shim.

Keyword calls (`CALL_KW`) and catchable `SyntaxError` + `e.args` already
work on main. `"single"` / nonzero `flags` / AST input stay `ValueError`.
