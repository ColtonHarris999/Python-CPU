# On-device `compile()`

Status: **Landed** through T4 (§11.2 try/raise/comprehensions/string
slices) plus §11.1 string-form `exec`/`eval` via `_bi_code_kind`. Design:
[`planning/compiler_design.md`](../../planning/compiler_design.md).

`compile()` is a resident PyCore builtin. This file records the
pipeline, subset, and the deviations from CPython that tests pin.

## Pipeline

```text
source ─► lexer ─► iterative parser ─► SoA AST ─► symtab
       ─► codegen T1–T4 (no CACHE) ─► assemble
       ─► _bi_code_alloc / blit / patch / new ─► existing exec/eval
```

The public builtin is a ROM shim: it stores `_in_src` / `_in_file` /
`_in_mode` on `_PYC_G` and runs `_pyc_codegen_main` through
`_bi_exec_globals`. `_PYC_ENTRY` stays the step-D toy trampoline (42).
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

`mode == "eval"` wraps a T1–T4 expression in `ND_EXPRESSION`. `mode == "exec"`
parses T1–T4 statements (`if`/`while`/`for`, `break`/`continue`/`pass`,
augassign, `del`, displays, unpack, `def` with positional args, `global`,
`try`/`except`/`else`/`finally`, `raise`, single-generator
list/set/dict comprehensions, string slices) into `ND_MODULE`. Slice
step, generator expressions, `raise from`, `except*`, `while`/`for`-`else`,
defaults/`*args`/`**kwargs`, and T5 are `SyntaxError`.

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
them with `_bi_code_alloc` / `_bi_code_blit` / `_bi_code_new`. T1–T4:
literals, names, ALU, unary, compare/chains, `is`/`in`, `not`/`and`/`or`,
call, subscript, attribute, expression statements, assignment, `return`,
`if`/`elif`/`else`, `while`/`for`, `break`/`continue`/`pass`, augassign,
`del`, list/tuple/dict/set displays, unpack, `def` (positional; nested
assemble into the parent's `co_consts` then `MAKE_FUNCTION`),
`try`/`except`/`else`/`finally`, `raise`, comprehensions (`LIST_APPEND` /
`SET_ADD`/`MAP_ADD` oparg 2), string `BINARY_SLICE`.

No `CACHE` (D1). No constant folding (D2): CPython emits `LOAD_SMALL_INT 3`
for `1 + 2`; firmware emits `LOAD_SMALL_INT 1; LOAD_SMALL_INT 2; BINARY_OP +`.
List displays emit `BUILD_LIST n`, never `LIST_EXTEND`. Assemble builds
`co_consts` / `co_names` / `co_varnames` by concatenating 1-tuples
(device `tuple(list)` is LIST_EXTEND, trap 10). Jump args compensate
for the hardware `n_cache` addend (`JUMP_FORWARD=0`, `POP_JUMP_*` /
`JUMP_BACKWARD` / `FOR_ITER`=1). Unary `+` visits the operand only
(CPython's `CALL_INTRINSIC_1` 5 is not in the device allowlist). Exception
tables are a TUPLE of INT varints (CPython 6-bit layout; first start byte
`| 128`); entries are appended onto `kids[]` with `tk_b[0]` as the start
index. `del` of a module/global name is `SyntaxError`
(no `DELETE_NAME` / `DELETE_GLOBAL` on this target). Loop labels reuse
`_lex_line` (depth) and `tk_b` (break/continue pairs). Slice store/del
is `SyntaxError`. `except as e` leaves `e` bound (no `DELETE_NAME`).

Host: `pycore/tests/test_compiler_codegen.py` result differential vs CPython
`eval`/`exec`. Device: `img_codegen_t1_expr` (assembled `"1 + 2"` returns 3),
`img_compile_exec_roundtrip` (A2 → 7).

## Compile shim (step I)

`compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1)`
is seeded in `ROM_FIRMWARE_BUILTINS`. `"single"` / unknown mode / nonzero
`flags` / `optimize` not in `{0, -1}` raise `ValueError`. `dont_inherit`
is ignored. No `_busy` slot (D9; 127 of 128 `_PYC_G` keys).

Host: `pycore/tests/test_compiler_compile.py`. Device: `img_compile_eval_expr`
(A1 → 3), `img_compile_mode_trap` (A5 → 3), `img_compile_reject_import`
(A4 → 1), `img_compile_exec_roundtrip` (A2 → 7),
`img_compile_reject_locals` (A4 window cap → 1), `img_compile_repeat`
(R4 watermark ≤ 400000 → 1), `img_compile_release_realloc` (R7 → 37),
T4 images in §11.2 below.
Host `eval`/`exec` stand-ins call firmware-emitted code objects
(`_HostEmittedCode`) with a **shared** globals dict; SEED_CODE images still
use `types.CodeType`.

## String-form exec / eval (§11.1)

`_bi_code_kind(x)` (`PY_BI_CODE_KIND = 21`) returns the raw 4-bit tag as
`INT`. ROM `exec` / `eval` compile SHORT_STR (7) and LONG_STR (8) via
`compile(source, "<string>", mode)`, then call the code object as before.
`call_sub_r` is 7 bits so sub 64 does not wrap. Wrong argc is `CALL_FILTER`.
Non-string / non-code still traps on `code()` (`img_exec_bad_arg_trap` → 6).

Device: `img_code_kind_tags` (178), `img_eval_str_direct` (3),
`img_eval_str_long` (15), `img_exec_str_direct` (3).

## T4 grammar (§11.2)

Parser + codegen for `try`/`except`/`else`/`finally`, `raise`,
single-generator list/set/dict comprehensions, and string slices. Runtime
already had `RAISE_VARARGS` 0/1, `PUSH_EXC_INFO`, `CHECK_EXC_MATCH`,
`POP_EXCEPT`, `RERAISE`, `LIST_APPEND`/`SET_ADD`/`MAP_ADD`, and string
`BINARY_SLICE`. CODE_RAM is 65 536 slots (lever 2).

Limits: no slice step, no generator expressions, no `except*` / `raise from`,
no `DELETE_NAME` after `except as`, unmatched-except + finally may skip
the finally, comps leak the loop var via `STORE_NAME`/`STORE_FAST`.

Device: `img_compile_try_except` (7), `img_compile_try_else` (3),
`img_compile_try_finally` (12), `img_compile_raise` (7),
`img_compile_str_slice` (1), `img_compile_list_comp` (15, two-core).

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
| T1 | literals, names, ALU, compare, call, subscr, attr, assign, `return` | parser (F); codegen (H); `compile()` shim (I) |
| T2 | `if`/`while`/`for`, `break`/`continue`, augassign, `del` | parser + codegen (J, landed) |
| T3 | `def` (positional args + indented / one-line suite), `global`, displays, unpack | parser slice in G; codegen (J, landed) |
| T4 | `try`/`except`/`else`/`finally`, `raise`, comprehensions, string slices | parser + codegen (§11.2, landed) |
| T5 | `class`, decorators, `import`, `lambda`, f-strings, `with`, `assert` | blocked on runtime (§11) |

## Deviations from CPython (D1–D9)

Pinned here and in `bytecode_support.md`. Differentials compare **program
results**, never `co_code` identity. The lexer differential compares the
token stream (kinds, positions, payload text), not later `co_code`.

| # | Deviation | Consequence |
| --- | --- | --- |
| D1 | No `CACHE` padding is emitted | `co_code` differs from CPython; results must match |
| D2 | No constant folding in v1 | More instructions, same result (`1+2` stays three ops) |
| D3 | `LOAD_GLOBAL` oparg is CPython 3.14 `namei = oparg >> 1`, bit 0 = push `NULL` | Must match hardware |
| D4 | `COMPARE_OP` uses CPython 3.14 packed oparg (selector in bits 7:5) | Must match hardware |
| D5 | Constructs the machine cannot execute are compile-time `SyntaxError` | A4; never an illegal-opcode trap |
| D6 | Frame window `nlocals + co_stacksize > 240`, or a closure, is `SyntaxError` | Cap is compile-time, not `CALL_FILTER`. Recursion depth is runtime `MEM_FAULT` |
| D7 | `"single"` mode and `flags != 0` raise `ValueError` | Same as invalid `optimize` |
| D8 | `filename` is stored, never opened | No filesystem |
| D9 | `compile()` is not re-entrant | `_busy` is deferred (127 of 128 `_PYC_G` keys). Nested `compile()` would clobber `_in_*` and scratch |

## Size report (W-8)

`make pycore-size-report` builds `img_compile_eval_expr` and prints ROM,
compiler code-RAM, and static heap occupancy vs hardware ceilings. Overflow
fails the target (A8). Measured after T4: ROM **2613 / 8192** slots;
compiler **38645 / 65536** code-RAM slots (26891 remain for compiled
output); static heap **258752 / 981952** bytes.

## Lifetime

`compile()` does not `_bi_heap_release` internally. The caller marks:

```python
hm = _bi_heap_mark(); cm = _bi_code_mark()
code = compile(src, "<s>", "exec")
exec(code)
_bi_code_release(cm); _bi_heap_release(hm)
```

Device: `img_compile_repeat` compiles `"1 + 2"` eight times inside one
mark and returns 1 when the watermark stays ≤ 400000 bytes (R4).
`img_compile_release_realloc` compiles, releases, compiles a different
source, and returns 37 (R7).
