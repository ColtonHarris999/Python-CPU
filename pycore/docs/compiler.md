# On-device `compile()`

Status: **Landed** through T5 (`lambda`, decorators, `assert`, simple
f-strings) plus T4, §11.4 closures, and the §11.8 T6 grammar (conditional
expressions, chained assignment, `;`). Remaining work (self-hosting, the
module loader, O-2) is in
[`planning/master_plan.md`](../../planning/master_plan.md) §1. Design
history: [`planning/old/compiler_design.md`](../../planning/old/compiler_design.md).

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

`mode == "eval"` wraps a T1–T6 expression in `ND_EXPRESSION`. `mode == "exec"`
parses T1–T6 statements (`if`/`while`/`for`, `break`/`continue`/`pass`,
augassign, `del`, displays, unpack, `def` with the full parameter grammar
and decorators, `global`, `try`/`except`/`else`/`finally`, `raise`,
`assert`, `lambda`, simple f-strings, single-generator list/set/dict
comprehensions, string slices) into `ND_MODULE`. Chained assignment
(`x = y = expr`), `;`-separated simple statements, and conditional
expressions (`a if c else b`) are all in. Slice step, generator
expressions, `raise from`, `except*`, `while`/`for`-`else`, a second
comprehension `for` or `if`, positional-only `/`, annotations, nested
f-strings, format specs, `f"{x=}"`, and `class`/`import`/`with` are
`SyntaxError`.

**Packed node fields must fit a wrapping signed int64** (§7). The firmware
runs on arbitrary-precision ints under host CPython, so a field that spills
past bit 62 passes every host test and is silently truncated on hardware.
`_pyc_ops_push` rejects an over-wide operator-stack field outright, and
`test_compiler_parser.py::test_packed_node_fields_fit_a_wrapping_int64`
sweeps the corpus for node and token arrays.

Packings that carry more than one field:

```text
FunctionDef / Lambda
  nd_b   = nargs | (ndec << 16) | (params << 32)          # 62 bits
  params = nposargs | (nkwonly << 16)
           | (has_varargs << 28) | (has_varkw << 29)
  nd_obj = [name, defaults list, kwdefaults dict]
Call
  nd_c   = nargs | (nkw << 16)
  nd_obj = keyword name list when nkw != 0, else 0
Assign
  nd_a   = kids start of targets, nd_b = n_targets, nd_c = value
ListComp / SetComp / DictComp
  nd_a   = elt (key), nd_b = target,
  nd_c   = kids index of [iter, cond] (+[value] for DictComp);
           cond is -1 with no `if` filter
IfExp
  nd_a = test, nd_b = body, nd_c = orelse
```

The operator stack gains tag 11 for a pending conditional expression;
`_lex_col` selects the expression mode while parsing (0 normal, 1 f-string
interior, 2 no top-level tuple, 3 comprehension iterable or filter, which
is `or_test` only so `if` and `,` end it).

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
sc_argcount[s]   co_argcount: positional parameters only
sc_kwonly[s]     co_kwonlyargcount
sc_flags[s]      has_varargs | (has_varkw << 1)  -> _bi_code_new field 8
sc_defaults[s]   literal positional defaults     -> field 4
sc_kwdefaults[s] literal keyword-only defaults   -> field 6
sc_varnames[s]  list of local names (params first, then STORE targets)
```

Parameter slots follow CPython's `co_varnames` order: positional, then
keyword-only, then `*args`, then `**kwargs`.

Parameters and every `STORE` target in a function become locals;
`global x` forces global. Module / eval names are never FAST. A name
that is local to an enclosing function and read in a nested one is a
freevar of the nested scope (and of intervening functions) and a cellvar
of the definer. Freevars are appended onto `sc_varnames`; `sc_nlocals` is
nlocalsplus; `sc_kind = 1 | (n_free << 8)`. `nlocals > 240`
(`RF_WINDOW_CAP`, D6 / §6.1 S-6) is a `SyntaxError`;
stacksize is checked later by the assembler. The stale “> 32 locals”
cap in the original G contract does not apply after step B.

Host: `pycore/tests/test_compiler_symtab.py` vs CPython `co_varnames`.
Device: `img_symtab_locals` (checksum), `img_symtab_closure` (returns 1).

## Codegen + assemble (step H)

`_pyc_codegen_main() -> CODE_OBJECT` lexes, parses, builds the symbol table,
then recursively visits `nd_*` (Rule 2) into instruction words and assembles
them with `_bi_code_alloc` / `_bi_code_blit` / `_bi_code_new`. T1–T6:
literals, names, ALU, unary, compare/chains, `is`/`in`, `not`/`and`/`or`,
call, subscript, attribute, expression statements, assignment, `return`,
`if`/`elif`/`else`, `while`/`for`, `break`/`continue`/`pass`, augassign,
`del`, list/tuple/dict/set displays, unpack, `def` (defaults / `*args` /
keyword-only / `**kwargs`; nested
assemble into the parent's `co_consts` then `MAKE_FUNCTION`; freevars
emit `COPY_FREE_VARS` / `MAKE_CELL` / `SET_FUNCTION_ATTRIBUTE 8`;
decorators `CALL 0` without `PUSH_NULL`), `lambda`, `assert` (load
`AssertionError` + `RAISE_VARARGS` 1), simple f-strings (`FORMAT_SIMPLE` /
`BUILD_STRING` / `CONVERT_VALUE`),
`try`/`except`/`else`/`finally`, `raise`, comprehensions (`LIST_APPEND` /
`SET_ADD`/`MAP_ADD` oparg 2, with an arbitrary element expression and an
optional `if` filter guarded by `TO_BOOL` + `POP_JUMP_IF_FALSE`), string
`BINARY_SLICE`, keyword call sites (`CALL_KW`, oparg = *total* argument
count, names in a `co_consts` tuple), chained assignment (`COPY 1` before
every store but the last), and conditional expressions (the `If` statement's
jump shape, one value per arm).

No `CACHE` (D1). Constant folding (§11.3 / D2): int `+ - * & | ^` and
unary `- ~`, plus str `+`, rewrite to `Constant` so `1 + 2` is
`LOAD_SMALL_INT 3`. `/ // % ** << >>` stay as BinOp.
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
is ignored. `_PYC_G["_busy"]` guards re-entry (D9): entering while another
compile is active is a `ValueError`, and `finally` clears the flag so a
`SyntaxError` does not poison the next call. Nothing reaches it today --
`exec(compile(src))` is sequential and the compiler never calls `compile`
-- so `img_compile_reentrant` pins the parts that can go wrong.

Host: `pycore/tests/test_compiler_compile.py`. Device: `img_compile_eval_expr`
(A1 → 3), `img_compile_mode_trap` (A5 → 3), `img_compile_reject_import`
(A4 → 1), `img_compile_exec_roundtrip` (A2 → 7),
`img_compile_reject_locals` (A4 window cap → 1), `img_compile_repeat`
(R4 watermark ≤ 400000 → 1), `img_compile_release_realloc` (R7 → 37),
T4 images in §11.2 below.
Host `eval`/`exec` stand-ins call firmware-emitted code objects
(`_HostEmittedCode`) with a **shared** globals dict; SEED_CODE images still
use `types.CodeType`.

## Running several programs (the point of all this)

`img_startup_multiprogram` is the end-to-end shape: a launcher holds a table
of program sources, compiles each at run time, and runs it in its own
globals dict, so the programs cannot see or clobber each other's names.

```python
def launch(source, slot):
    ns = {"out": 0, "n": 0, "i": 0, "scale": 0, "slot": slot}
    try:
        exec(compile(source, "<prog>", "exec"), ns)
    except TypeError:
        return -1
    return ns["out"]
```

`exec(code, ns)` routes through `_bi_exec_globals`, which switches
`globals_base_r` for that frame and restores it on return — the same
mechanism the compiler itself runs under (`compiler_design.md` §4.2), and
the reason a program's names never reach the launcher. A program that
raises unwinds into the launcher's `except`, so one failure does not stop
the rest.

Single-core dicts cannot grow, so a program's namespace must be pre-bound
with every name it stores. On two-core, `PY_TRAP_DICT_GROW` is a recoverable
excore round trip and the dict grows on demand.

Lifetime is caller-driven (§5.7): `compile()` does not release, so a
launcher that runs many programs should bracket them with
`_bi_heap_mark` / `_bi_heap_release` (`img_compile_release_realloc`).

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

## Constant folding (§11.3)

`_pyc_codegen_main` rewrites `BinOp`/`UnaryOp` of `Constant` kids in place
before the visit: int `+ - * & | ^`, unary `- ~`, str `+`. Nested
`1 + 2 * 3` becomes one `LOAD_SMALL_INT 7`. Names stay unfolded (`1 + x`
still `BINARY_OP`). `/ // % ** << >>` are left as BinOp.

## Closures (§11.4)

Landed. `MAKE_CELL` wraps a local slot in `OBK_CELL`; `LOAD_DEREF` /
`STORE_DEREF` go through field0; `COPY_FREE_VARS` copies the CALL-latched
closure tuple into the last n locals; `SET_FUNCTION_ATTRIBUTE 8` allocates
`OBK_FUNCTION` (code + closure). `MAKE_FUNCTION` stays identity. Nested
load of an enclosing local compiles. Device: `img_symtab_closure` (1),
`img_compile_reject_closure` (1), `img_compile_closure` (7).

## T5 grammar (§11.5)

Landed subset: `lambda`, decorators, `assert`, simple f-strings.
Lexer emits `FSTRING_START`/`MIDDLE`/`END` (kinds 59/60/61; not seeded
as `TOK_*` names). Assert loads seeded `AssertionError` rather than
`LOAD_COMMON_CONSTANT`. Decorator application is `CALL 0` with the
function in the self_or_null slot (no `PUSH_NULL`). F-string limits:
`FORMAT_SIMPLE` / `BUILD_STRING` (SHORT_STR total ≤15) / `CONVERT_VALUE`
opargs 1/2/3; no format spec, no `f"{x=}"`, no nested f-strings, no
t-strings. `class`, `import`, and `with` stay compile-time `SyntaxError`.

Device: `img_compile_lambda` (7), `img_compile_assert` (1),
`img_compile_decorator` (7), `img_compile_fstring` (1).

## BIOS (§11.8)

ROM `bios(payload)` `exec`s a string or code object in the caller's
globals. Device: `img_bios_exec` (3).

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
| T3 | `def` with literal defaults, `*args`, keyword-only, `**kwargs`; keyword call sites (`CALL_KW`); `global`; displays; unpack | parser + codegen (J; parameters and `CALL_KW` in §11.8, landed) |
| T4 | `try`/`except`/`else`/`finally`, `raise`, comprehensions, string slices | parser + codegen (§11.2, landed) |
| T5 | `lambda`, decorators, `assert`, simple f-strings. `class`/`import`/`with` stay `SyntaxError` | parser + codegen (§11.5, landed) |
| T6 | conditional expressions, chained assignment, `;`-separated statements, comprehension element expressions and `if` filters | parser + codegen (§11.8, landed) |

## Deviations from CPython (D1–D13)

Pinned here and in `bytecode_support.md`. Differentials compare **program
results**, never `co_code` identity. The lexer differential compares the
token stream (kinds, positions, payload text), not later `co_code`.

| # | Deviation | Consequence |
| --- | --- | --- |
| D1 | No `CACHE` padding is emitted | `co_code` differs from CPython; results must match |
| D2 | Int `+ - * & | ^` / unary `- ~` / str `+` fold; `/ // % ** << >>` do not | `1+2` is one `LOAD_SMALL_INT`; mixed names still emit `BINARY_OP` |
| D3 | `LOAD_GLOBAL` oparg is CPython 3.14 `namei = oparg >> 1`, bit 0 = push `NULL` | Must match hardware |
| D4 | `COMPARE_OP` uses CPython 3.14 packed oparg (selector in bits 7:5) | Must match hardware |
| D5 | Constructs the machine cannot execute are compile-time `SyntaxError` | A4; never an illegal-opcode trap |
| D6 | Frame window `nlocals + co_stacksize > 240` is `SyntaxError` | Cap is compile-time, not `CALL_FILTER`. Recursion depth is runtime `MEM_FAULT`. Closures are §11.4. |
| D7 | `"single"` mode and `flags != 0` raise `ValueError` | Same as invalid `optimize` |
| D8 | `filename` is stored, never opened | No filesystem |
| D9 | `compile()` is not re-entrant | Guarded by `_PYC_G["_busy"]`: entry while active is a `ValueError`, not a clobbered `_in_*`. No path reaches it today |
| D10 | A `def` default must be a literal | Defaults ride on the **code object** (`_bi_code_new` fields 4 and 6), not on a function object: `SET_FUNCTION_ATTRIBUTE` 1/2 are not implemented, so there is no def-time evaluation to hang a non-constant default on. `def f(a=b)` is a `SyntaxError` |
| D11 | `del name` at module scope is a `SyntaxError` | `DELETE_NAME` / `DELETE_GLOBAL` are not in `pycore/targets/pycore.json`. `del` of a local (`DELETE_FAST`) and `del xs[i]` (`DELETE_SUBSCR`) work |
| D12 | One `for` and at most one `if` per comprehension | A second generator clause or filter is a `SyntaxError`, not a silent mis-parse |
| D13 | Two sequential `try` blocks in one function are a build-time error for *host*-compiled images | CPython emits `JUMP_BACKWARD_NO_INTERRUPT` there and this target rejects it. Split them into separate functions. The firmware compiler never emits it |

## Size report (W-8)

`make pycore-size-report` builds `img_compile_eval_expr` and prints ROM,
compiler code-RAM, and static heap occupancy vs hardware ceilings. Overflow
fails the target (A8). Current measurement is in
[`compile_limitations.md`](compile_limitations.md): code RAM is 131 072
slots and the report's `self-host:` line is unblocked for a second copy
of the resident host-built package.

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
source, and returns 37 (R7). O-2 (split result/scratch arenas) stays
closed while that watermark golden holds (§11.6).
