# On-device `compile()`

Status: **T0 + A in progress.** Design:
[`planning/compiler_design.md`](../../planning/compiler_design.md).

`compile()` will be a resident PyCore builtin. This file records the
pipeline, subset, and the deviations from CPython that tests pin.

## Pipeline

```text
source ─► lexer ─► iterative parser ─► SoA AST ─► symtab
       ─► codegen T1–T3 (no CACHE) ─► assemble
       ─► _bi_code_alloc / blit / patch / new ─► existing exec/eval
```

The public builtin is a shim around `_bi_exec_globals(_PYC_ENTRY, _PYC_G)`.
Helpers live in that private dict, not in the boot builtins namespace.

## Subset (firmware compiler source)

Enforced by `pycore/tests/test_compiler_subset.py` on every file under
`pycore_firmware/compiler/`. Rewrite helpers: `compat.py`.

Banned: list/tuple slice, negative indices, `class`, closures, `import`,
generators, `with`/`assert`/`match`, decorators, `lambda`, f-strings,
`getattr`/`hasattr`/`setattr`, `type(x) is T`, tuple dict keys, a frame
window `nlocals + co_stacksize > 200`.

Allowed (and previously thought banned): `str.split` / `strip` / `replace`
and friends, identifiers longer than 15 bytes, `try`/`except`/`finally`.

String slicing is native. List/tuple slicing is not — use `copy_range`.

## Frame-depth invariant

The parser is iterative (explicit operand/operator/block stacks). After
step B a recursive codegen visit is allowed; the parser's live call depth
stays constant in the source nesting.

## Grammar tiers

| Tier | Constructs | Status |
| --- | --- | --- |
| T1 | literals, names, ALU, compare, call, subscr, attr, assign, `return` | next (H/I) |
| T2 | `if`/`while`/`for`, `break`/`continue`, augassign, `del` | next (J) |
| T3 | `def`, displays, unpack, `global` | next (J) |
| T4+ | `try`/`class`/`import`/closures | blocked on runtime |

## Deviations from CPython (D1–D9)

See `compiler_design.md` §5.8. Differentials compare **program results**,
never `co_code` identity (no `CACHE`, no constant folding in v1).

## Lifetime

`compile()` does not `_bi_heap_release` internally. The caller marks:

```python
hm = _bi_heap_mark(); cm = _bi_code_mark()
code = compile(src, "<s>", "exec")
exec(code)
_bi_code_release(cm); _bi_heap_release(hm)
```
