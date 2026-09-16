# On-device `compile()`

Status: **step H landed** (T1 codegen + assemble + W-3). Next is step I
(`compile()` shim; `img_compile_eval_expr` → 3). Design:
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

## Lexer (step E)

`_pyc_lex(src) -> int` walks the source once and fills SoA arrays in `_PYC_G`:

```text
tk_a[i] = kind | (col << 8) | (line << 24)
tk_b[i] = start | (end << 32)
tk_s[i] = text for NAME / NUMBER / STRING / OP, else 0
```

Kinds are the CPython 3.14 `token` integers (`TOK_*` in generated
`tables.py`). Operators are `TOK_OP` (55), matching
`tokenize.generate_tokens`. COMMENT / NL / ENCODING are not emitted.
A user program stores `_in_src` on `_PYC_G` and runs `_pyc_lex_main`
through `_bi_exec_globals`.

Host: `pycore/tests/test_compiler_lexer.py` vs `tokenize.generate_tokens`.
Device: `img_lexer_count` (token-count golden).

## Parser (step F)

`_pyc_parse(mode) -> int` (root node id) is an iterative shunting-yard over
`tk_*`. Operand / operator stacks live in `_PYC_G`, so source nesting does
not grow the live call depth. AST is SoA:

```text
nd_kind[n]                  ND_* small int (CPython ast type)
nd_pos[n]  = line | (col << 32)
nd_a[n], nd_b[n], nd_c[n]   child ids, kid-arena (start, count), or an int operand
nd_obj[n]                   str / int / float / list payload, or None
kids[]                      flat arena
```

`mode == "eval"` wraps a T1 expression in `ND_EXPRESSION`. `mode == "exec"`
parses T1 statements (`Expr`, `Assign`, `Return`) plus the G-slice of T3
(`def` with positional args, `global`) into `ND_MODULE`. Displays, slices,
and later tiers are `SyntaxError`.

Host: `pycore/tests/test_compiler_parser.py` vs `ast.parse` (tree shape).
Device: `img_parser_tiny_expr` (checksum), `img_compile_deep_nesting`
(40 nested parens, RF `spill_count=0`).

## Symbol table (step G)

`_pyc_symtab(root) -> int` (scope count) is an iterative walk of `nd_*`.
Scope tables live in `_PYC_G`:

```text
sc_kind[s]      0 = Module/Expression (no FAST), 1 = function
sc_parent[s]    -1 at the root
sc_node[s]      Module / FunctionDef node id
sc_nlocals[s]
sc_argcount[s]
sc_varnames[s]  list of local names (params first, then STORE targets)
```

Parameters and every `STORE` target in a function become locals;
`global x` forces global. Module / eval names are never FAST. A name
that is local to an enclosing function and read in a nested one is a
closure → `SyntaxError("closures are not supported on this target")`.
`nlocals > 240` (`RF_WINDOW_CAP`, D6 / §6.1 S-6) is a `SyntaxError`;
stacksize is checked later by the assembler. The stale “> 32 locals”
cap in the original G contract does not apply after step B.

Host: `pycore/tests/test_compiler_symtab.py` vs CPython `co_varnames`.
Device: `img_symtab_locals` (checksum), `img_symtab_closure` (returns 1).

## Codegen + assemble (step H)

`_pyc_codegen_main() -> CODE_OBJECT` lexes, parses, builds the symbol table,
then recursively visits `nd_*` (Rule 2) into instruction words and assembles
them with `_bi_code_alloc` / `_bi_code_blit` / `_bi_code_new`. T1 only:
literals, names, ALU, unary, compare/chains, `is`/`in`, `not`/`and`/`or`,
call, subscript, attribute, expression statements, assignment, `return`.
Nested `def` is a `SyntaxError` (`def codegen is not in T1`); that is J/T3.

No `CACHE` (D1). No constant folding (D2): CPython emits `LOAD_SMALL_INT 3`
for `1 + 2`; firmware emits `LOAD_SMALL_INT 1; LOAD_SMALL_INT 2; BINARY_OP +`.
Both evaluate to 3. Jump args compensate for the hardware `n_cache` addend
(`JUMP_FORWARD=0`, `POP_JUMP_*=1`). Unary `+` visits the operand only
(CPython's `CALL_INTRINSIC_1` 5 is not in the device allowlist). Exception
tables are empty `()` in T1; the host encoder is `encode_exception_table`
(W-3).

Host: `pycore/tests/test_compiler_codegen.py` result differential vs CPython
`eval`/`exec`. Device: `img_codegen_t1_expr` (assembled `"1 + 2"` returns 3).

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
| T1 | literals, names, ALU, compare, call, subscr, attr, assign, `return` | parser (F); codegen (H); `compile()` shim next (I) |
| T2 | `if`/`while`/`for`, `break`/`continue`, augassign, `del` | next (J) |
| T3 | `def` (positional args + indented / one-line suite), `global` | parser slice in G (full T3 in J) |
| T4+ | `try`/`class`/`import`/closures | blocked on runtime |

## Deviations from CPython (D1–D9)

See `compiler_design.md` §5.8. Differentials compare **program results**,
never `co_code` identity (no `CACHE`, no constant folding in v1). The lexer
differential compares the token stream (kinds, positions, payload text),
not later `co_code`.

## Lifetime

`compile()` does not `_bi_heap_release` internally. The caller marks:

```python
hm = _bi_heap_mark(); cm = _bi_code_mark()
code = compile(src, "<s>", "exec")
exec(code)
_bi_code_release(cm); _bi_heap_release(hm)
```
