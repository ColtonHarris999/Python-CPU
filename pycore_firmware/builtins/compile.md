# `compile` — implementation plan

Status: **blocked** (stub in `compile.py`)

## Goal

`compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1)`
returns a code object usable by `eval` / `exec`.

## Blockers

1. **No compiler on the hart.** PyCore executes a CPython 3.14 bytecode
   subset; it does not include a parser, AST, or bytecode emitter.
2. **Code-object fabrication.** `PY_TAG_CODE_OBJECT` layouts are produced by
   host-side `image_from_source.py` / `HeapImageBuilder.alloc_code`. There is
   no runtime opcode to allocate and fill `co_code` / `co_consts` /
   `co_names` / metadata from scratch.
3. **Keyword arguments.** `flags`, `dont_inherit`, `optimize` need `CALL_KW`
   (deferred).
4. **Source forms.** Accepting `ast.AST` requires the `ast` module (imports
   deferred).
5. **Mode handling.** `"exec"` / `"eval"` / `"single"` imply different code
   object shapes and compiler entry points.
6. **Error model.** Syntax errors need exception objects + `RAISE_VARARGS`
   (both out of scope for image-boot).

## Next steps

1. Keep `compile` as a host-only tooling concern for the current milestone
   (images are built on CPython 3.14 before load).
2. Define a **minimal ROM bytecode loader** that can accept a pre-serialized
   code-object blob (not source text) and install it as `PY_TAG_CODE_OBJECT`.
3. Only after (2): consider a tiny expression compiler for a *subset* grammar
   (integers, names, `+`/`-`/`*`) if interactive `eval` becomes a product
   goal — still far short of CPython `compile`.

## Implementation plan

| Phase | Work | Depends on |
| --- | --- | --- |
| A | Document host `compile()` as the only supported path; reject runtime `compile` in preprocess | — |
| B | Spec a `CODE_OBJECT` freeze format (bytes + const table) loadable from dmem | object model |
| C | Native/excore helper `bi_load_code(blob) → CODE_OBJECT` | B, heap alloc |
| D | Optional: micro-compiler for arithmetic expressions → blob for C | C, parser |
| E | Full CPython-compatible `compile` | parser, AST, assembler, exceptions — **not planned for ROM** |

## Recommendation

Do **not** attempt a pure-Python `compile` in `pycore_firmware`. Point
firmware `eval` / `exec` at precompiled code objects (phase C) instead of
source strings.
