# `compile` — shipped subset

Status: **in ROM** (compiler_design.md step J, landed; K size report). T1–T3 expressions and
statements (`if`/`while`/`for`, `def` positional, displays, unpack).
`"single"` / nonzero `flags` / invalid `optimize` → `ValueError`.
Defaults / `*args` / `**kwargs` / nested closures remain `SyntaxError`.

**Design:** [`planning/compiler_design.md`](../../planning/compiler_design.md)
§4.2. Pipeline notes: [`pycore/docs/compiler.md`](../../pycore/docs/compiler.md).

## Goal

`compile(source, filename, mode)` with `flags==0` returns a code object
usable by `eval` / `exec`. First success (A1):
`eval(compile("1 + 2", "<s>", "eval")) == 3`.

## API

```python
compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1)
```

| Argument | v1 |
| --- | --- |
| `source` | `str` |
| `filename` | stored on `_PYC_G["_in_file"]`, not opened |
| `mode` | `"eval"` or `"exec"` |
| `flags` | must be `0` |
| `dont_inherit` | accepted and ignored |
| `optimize` | `0` or `-1` |

`"single"`, any other mode, `flags != 0`, and `optimize` not in `{0, -1}`
raise `ValueError`. Re-entrancy (`_busy`, D9) is deferred: `_PYC_G` is
already at 127 of 128 static keys.

The shim does **not** go through `_PYC_ENTRY` (that trampoline is still
the step-D toy that returns 42). It stores `_in_src` / `_in_file` /
`_in_mode` and runs `_pyc_codegen_main` via `_bi_exec_globals`.

## Coverage

| Image | Expect |
| --- | --- |
| `img_compile_eval_expr` | **3** (A1) |
| `img_compile_mode_trap` | **3** (`"single"` + `flags=1`) |
| `img_compile_reject_import` | **1** (`SyntaxError` on `import`) |
| `img_compile_exec_roundtrip` | **7** (A2) |
| `img_compile_reject_locals` | **1** (`SyntaxError` on 241 locals) |

`img_compile_repeat` and `img_compile_release_realloc` are later steps.
String-form `eval("1+2")` still needs `_bi_code_kind` (§11).
`make pycore-size-report` is the W-8 occupancy gate (A8). Re-entrancy
(`_busy`, D9) is deferred: `_PYC_G` is 127 of 128 static keys.
