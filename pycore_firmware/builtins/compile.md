# `compile` — shipped subset

Status: **in ROM** (compiler_design.md T4 / §11.2, landed). T1–T4
expressions and statements (`if`/`while`/`for`, `def` positional,
displays, unpack, `try`/`except`/`else`/`finally`, `raise`,
comprehensions, string slices). `"single"` / nonzero `flags` /
invalid `optimize` → `ValueError`. Defaults / `*args` / `**kwargs` /
nested closures remain `SyntaxError`.

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
| `img_compile_repeat` | **1** (R4 watermark ≤ 400000) |
| `img_compile_release_realloc` | **37** (R7 second compile after release) |
| `img_compile_try_except` | **7** (T4) |
| `img_compile_try_else` | **3** (T4) |
| `img_compile_try_finally` | **12** (T4) |
| `img_compile_raise` | **7** (T4) |
| `img_compile_str_slice` | **1** (T4) |
| `img_compile_list_comp` | **15** (T4, two-core) |
| `img_compile_reject_closure` | **1** (§11.4 nested enclosing load) |

String-form `eval("1+2")` / `exec("x = 1")` dispatch via `_bi_code_kind`
(§11.1). `make pycore-size-report` is the W-8 occupancy gate (A8).
Re-entrancy (`_busy`, D9) is deferred: `_PYC_G` is 127 of 128 static keys.
