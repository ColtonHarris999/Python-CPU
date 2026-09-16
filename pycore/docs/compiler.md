# On-device `compile()`

Status: **step J landed, T3 partial** (A2 `img_compile_exec_roundtrip` → 7;
`def` defaults / `*args` / `**kwargs` / keyword calls are still
`SyntaxError` — see "Grammar tiers"). Next is step K (W-8 size report),
which also owns the code-RAM overrun measured in `compiler_design.md` §7.1.
Design:
[`planning/compiler_design.md`](../../planning/compiler_design.md).

`compile()` is a resident PyCore builtin. This file records the
pipeline, subset, and the deviations from CPython that tests pin.

## Pipeline

```text
source ─► lexer ─► iterative parser ─► SoA AST ─► symtab
       ─► codegen T1–T3 (no CACHE) ─► assemble
       ─► _bi_code_alloc / blit / patch / new ─► existing exec/eval
```

The public builtin is a ROM shim: it stores `_in_src` / `_in_file` /
`_in_mode` on `_PYC_G` and runs `_pyc_codegen_main` through
`_bi_exec_globals`. `_PYC_ENTRY` stays the step-D toy trampoline (42).
Helpers live in that private dict, not in the boot builtins namespace.

`_PYC_G` is sized by `dict_slot_count_for_stores` — the same
`next_pow2(2 * keys)` rule the boot globals dict uses — so it sits at 132
keys in 512 slots. It is on the `LOAD_GLOBAL` path of every helper call, and
at the old 127/128 it was both past the hardware's 2/3 grow threshold (so
the next new key would need a `DICT_GROW` trap, fatal on the single-core
image) and deep into linear-probe chains. Static dicts have no 128-slot
ceiling; `img_locals_64` and `img_rf_window_too_big_trap` already ship 256-
and 512-slot globals. It costs ~66 KB more static heap than the old packed
dict, out of ~960 KB.

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

`mode == "eval"` wraps a T1–T3 expression in `ND_EXPRESSION`. `mode == "exec"`
parses T1–T3 statements (`if`/`while`/`for`, `break`/`continue`/`pass`,
augassign, `del`, displays, unpack, `def` with positional args, `global`)
into `ND_MODULE`. Slices, `while`/`for`-`else`, defaults/`*args`/`**kwargs`,
keyword arguments at a call site, semicolon-separated simple statements,
conditional expressions, and later tiers are `SyntaxError`.

String literals are sliced out of the source verbatim, so a **non-raw**
literal containing a backslash is a `SyntaxError`: v1 has no escape decoder
(it arrives with the `string_parser.py` port), and returning the raw slice
would silently give `"a\tb"` two characters where CPython gives one (D5 —
what the machine cannot do is a compile-time error, never a wrong answer).
`r"..."` needs no decoding and is exact as sliced.

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
them with `_bi_code_alloc` / `_bi_code_blit` / `_bi_code_new`. T1–T3:
literals, names, ALU, unary, compare/chains, `is`/`in`, `not`/`and`/`or`,
call, subscript, attribute, expression statements, assignment, `return`,
`if`/`elif`/`else`, `while`/`for`, `break`/`continue`/`pass`, augassign,
`del`, list/tuple/dict/set displays, unpack, `def` (positional; nested
assemble into the parent's `co_consts` then `MAKE_FUNCTION`).

No `CACHE` (D1). No constant folding (D2): CPython emits `LOAD_SMALL_INT 3`
for `1 + 2`; firmware emits `LOAD_SMALL_INT 1; LOAD_SMALL_INT 2; BINARY_OP +`.
List displays emit `BUILD_LIST n`, never `LIST_EXTEND`. Assemble builds
`co_consts` / `co_names` / `co_varnames` by concatenating 1-tuples
(device `tuple(list)` is LIST_EXTEND, trap 10). Jump args compensate
for the hardware `n_cache` addend (`JUMP_FORWARD=0`, `POP_JUMP_*` /
`JUMP_BACKWARD` / `FOR_ITER`=1). Unary `+` visits the operand only
(CPython's `CALL_INTRINSIC_1` 5 is not in the device allowlist). Exception
tables are empty `()`. `del` of a module/global name is `SyntaxError`
(no `DELETE_NAME` / `DELETE_GLOBAL` on this target). Loop labels reuse
`_lex_line` (depth) and `tk_b` (break/continue pairs).

Two invariants the pools carry, both of which a naive implementation gets
wrong silently:

- **`co_consts` dedup compares the parser's constant kind, not just the
  value.** `1000 == 1000.0` is True, so a value-only pool folds a float
  literal onto an int already in the pool and the program sees the wrong
  type. The kind also keeps a nested `CODE_OBJECT` (kind 6, from
  `MAKE_FUNCTION`) out of the `==` scan entirely: `CODE_OBJECT` is neither
  a numeric nor a string tag, so `pycore_is_trapping_tag` holds and
  `COMPARE_OP` against one is a fatal `PY_TRAP_TYPE`
  (`pycore_tag_decode.sv:93`).
- **A conditional jump cannot name its own fall-through.** The hardware
  adds `n_cache` to every taken branch, so the nearest reachable target is
  `i + 2` and an empty suite (`if c: pass`) would need an offset of -1.
  Assemble rewrites that jump to the `POP_TOP` it is equivalent to; any
  other negative offset is an internal error, never a word handed to
  `_bi_code_blit` (which TYPE-traps an oparg that does not fit).

Stack depth is a **linear** walk over the instruction list clamped at zero,
not the CFG walk §5.5 step 3 describes. It is exact for every T1–T3 shape
the codegen emits (the deepest point is always on the fall-through path),
but the clamp means a future emit pattern could under-report `co_stacksize`
without failing anything. Replace it with the real walk before T4.

Host: `pycore/tests/test_compiler_codegen.py` result differential vs CPython
`eval`/`exec`. Device: `img_codegen_t1_expr` (assembled `"1 + 2"` returns 3),
`img_compile_exec_roundtrip` (A2 → 7).

## Compile shim (step I)

`compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1)`
is seeded in `ROM_FIRMWARE_BUILTINS`. `"single"` / unknown mode / nonzero
`flags` / `optimize` not in `{0, -1}` raise `ValueError`. `dont_inherit`
is ignored. There is no `_busy` re-entrancy slot (D9): `_PYC_G` has room
for one now, but a guard that is set before the call and cleared after is
worse than none — an ordinary `SyntaxError` would leave it set and poison
every later `compile()`. It needs `try` / `finally` in the ROM shim, which
is step K work, not a key-count problem.

Host: `pycore/tests/test_compiler_compile.py`. Device: `img_compile_eval_expr`
(A1 → 3), `img_compile_mode_trap` (A5 → 3), `img_compile_reject_import`
(A4 → 1), `img_compile_exec_roundtrip` (A2 → 7),
`img_compile_reject_locals` (A4 window cap → 1). Host `eval`/`exec` stand-ins
call firmware-emitted code objects (`_HostEmittedCode`) with a **shared**
globals dict; SEED_CODE images still use `types.CodeType`.

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
`compat.py` is rewrite guidance: the T1–T3 compiler indexes SoA arrays and
calls none of its three helpers today, so they cost 119 code-RAM slots and
three `_PYC_G` keys for nothing. Drop the file, or start using it.

## Frame-depth invariant

The parser is iterative (explicit operand/operator/block stacks). After
step B a recursive codegen visit is allowed; the parser's live call depth
stays constant in the source nesting.

## Grammar tiers

| Tier | Constructs | Status |
| --- | --- | --- |
| T1 | literals, names, ALU, compare, call, subscr, attr, assign, `return` | parser (F); codegen (H); `compile()` shim (I) |
| T2 | `if`/`while`/`for`, `break`/`continue`, augassign, `del` | parser + codegen (J, landed) |
| T3 | `def` (positional args + indented / one-line suite), `global`, displays, unpack | parser slice in G; codegen (J, landed) |
| T4+ | `try`/`class`/`import`/closures | blocked on runtime |

**T3 is narrower here than in `compiler_design.md` §5.6**, which lists
`def` with default / kw-only / `*args` / `**kwargs`. Only positional
parameters are implemented; defaults and star-args are a `SyntaxError`, and
so is a keyword argument at a call site, even though `CALL_KW` and the
metadata bits for both are in the emit allowlist and the `_bi_code_new`
field contract. Closing that gap is the rest of J.

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
