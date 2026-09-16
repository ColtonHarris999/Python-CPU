# Third-party code in firmware and vendor trees

`planning/compile_plan.md` requires a provenance record for every ported
or vendored compiler source.

| Project | Licence | Path | Revision / branch | What we use | Modifications |
| --- | --- | --- | --- | --- | --- |
| [PyCPython](https://github.com/ColtonHarris999/PyCPython) | PSF-2.0 (`pyproject.toml`) | `vendor/pycpython` (git submodule) | branch `claude/cpython-3-14-compile-frontend-4o4fcz` | Host `compile()` oracle and algorithm reference for the on-device compiler. Package never calls `eval` / `exec` / `compile`. | **None in the submodule.** Device-runnable code is a derived port under `pycore_firmware/compiler/`, with per-file provenance headers. |
| CPython `Lib/tokenize.py` + `Lib/token.py` | PSF-2.0 | (not vendored) | CPython 3.14.7 | Token kinds and tokenizer state machine (indent stack, implicit joining, numbers, strings). | Ported as `pycore_firmware/compiler/lexer.py` over a `str` with SoA `tk_*` arrays. Operators stay `TOK_OP` to match `tokenize.generate_tokens`. |
| CPython `_ast` / `ast` node types | PSF-2.0 | (not vendored) | CPython 3.14.7 | Concrete AST type names and field order for generated `ND_*`. | Host generator `pycore/tools/gen_compiler_tables.py` emits `ND` / `BINOPS` / `PREC`. Device `parser.py` is an original iterative shunting-yard, not a port of `pegen`. |
| CPython / PyCPython `symtable.py` | PSF-2.0 | `vendor/pycpython` (reference only) | CPython 3.14.7 | Module + function scope, `global`, closure detection. | Device `symtab.py` is an original iterative walk of the SoA AST. Closures raise `SyntaxError`; `MAKE_CELL` is never emitted. |
| CPython / PyCPython `codegen.py` + `assemble.py` | PSF-2.0 | `vendor/pycpython` (reference only) | CPython 3.14.7 | T1–T3 instruction shapes, jump offsets, stacksize walk, 6-bit exception-table varints. | Device `codegen.py` is a recursive SoA visit plus assembler calling `_bi_code_*`. No `CACHE`, no constant folding. Nested `def` assembles into the parent `co_consts` then `MAKE_FUNCTION`. Host `encode_exception_table` (W-3) uses the same varint layout. |

CPython itself is the semantic oracle PyCPython already matches (Tier 0/1
100% on CPython 3.14.7). PyCore does not vendor CPython C sources.

When a firmware file is ported from PyCPython, add a row here and a
header in that file naming the upstream path and revision.
