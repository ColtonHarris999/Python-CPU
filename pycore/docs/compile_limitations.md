# Compile limitations

Status of on-device `compile()` as of the current tree. The pipeline
itself is landed (T1–T5, closures, the `compile` shim). This file is the
inventory of what is still wrong, what is still missing, and what has to
change before two particular programs work: compiling the compiler, and
compiling and running `async` code.

Authoritative behavior is the firmware in
`pycore_firmware/compiler/` plus `pycore/targets/pycore.json`. Design
history is [`planning/compiler_design.md`](../../planning/compiler_design.md).
The pipeline overview is [`compiler.md`](compiler.md). Where those
disagree with a measurement below, the measurement wins.
`pycore_firmware/builtins/compile.md` still says `*args` / defaults are
`SyntaxError` and that re-entrancy is deferred. That note is stale.
Current occupancy is the size-report block in §1.

## What already works

`compile(source, filename, mode)` with `mode` of `"exec"` or `"eval"`
returns a code object that `exec` / `eval` can run. The landed grammar
is literals, names, arithmetic, comparisons, boolean ops, calls
(positional and keyword), subscripts, attributes, assignment (including
chained and `;`), `if` / `while` / `for` including `else`, `break` /
`continue` / `pass`, augassign, `del` of a local or a subscript,
displays, unpack, `def` with literal defaults / `*args` /
keyword-only / `**kwargs`, `global`, `lambda`, decorators, `assert`,
simple f-strings, `try` / `except` / `else` / `finally` (including
`finally` on `break` / `continue` / `return`), `raise`,
single-generator comprehensions with one `if` (their own scope),
ordinary string escapes, negative indexes, slices of a list or tuple
display, string slices, and closures. Differentials compare results,
not `co_code` (`pycore/tests/test_compiler_differential.py`).

Everything in the rest of this file is outside that set, or inside it
but still wrong.

---

## 1. Compiling the compiler

Self-host means: the resident compiler compiles
`pycore_firmware/compiler/*.py`, the result is installed as code, and a
second compile of the same source matches the first. The first half
now works on the host stand-in. Installing a second copy and proving
the fixpoint do not.

### 1.1 The source is in the grammar

`pycore/tests/test_compiler_subset.py` compiles the tree with **host**
CPython and rejects opcodes the machine cannot run. That gate still
passes. Separately,
`test_firmware_compiler_compiles_its_own_sources` runs the ROM
`compile` shim on every file under `pycore_firmware/compiler/`. All
seven compile.

Ordinary literals decode `\n` `\t` `\r` `\\` `\'` `\"` `\a` `\b` `\f`
`\v`, backslash-newline, and `\xHH`. Unknown escapes (`\u`, octal)
stay `SyntaxError` (`unsupported escape sequence`). Raw literals are
unchanged.

Firmware emit of this tree (slots, and executed opcodes — the emitter
writes no `CACHE`):

| File | Slots |
| --- | ---: |
| `toy.py` | 23 |
| `compat.py` | 135 |
| `tables.py` | 1 154 |
| `lexer.py` | 4 383 |
| `symtab.py` | 6 045 |
| `parser.py` | 14 438 |
| `codegen.py` | 15 000 |
| **Total** | **41 178** |

The tree still does not use `class`, `import`, `async`, `with`,
`lambda`, f-strings, decorators, closures, annotations, comprehensions,
or `try`.

### 1.2 Which image is the boot compiler

`make pycore-size-report` on `img_compile_eval_expr` (this tree):

| Region | Used | Capacity | Remain |
| --- | ---: | ---: | ---: |
| Code ROM | 2 669 | 8 192 | 5 523 |
| Code RAM (compiler) | 56 469 | 131 072 | 74 603 |
| Heap (static image) | 379 648 | 981 952 | 602 304 |

The report prints `self-host: unblocked (74603 headroom >= 56469
package)`. Code RAM is 256 blocks (1 MB, slots `0x2000 .. 0x21FFF`).
The previous 65 536-slot bank left 9 667 free against a 55 869-slot
resident package, so a second copy could not be emitted beside it.

The boot image stays the **host-built** package. Fetch skips `CACHE`,
so the speed proxy is real opcodes, not slot count. The 94 host-built
functions occupy 56 447 slots and 23 658 real opcodes (229 of those
are `EXTENDED_ARG`). The firmware emit of the same sources is 41 178
slots and 41 178 real opcodes.

| Image | Slots | Real opcodes | Fastest | Smallest |
| --- | ---: | ---: | --- | --- |
| Host-built package (boot image) | 56 469 | 23 658 | yes | no |
| Firmware-emitted seven files | 41 178 | 41 178 | no | yes |

The firmware image is smaller and slower. It is not installed into
the startup ROM. A later measurement that shows it also faster is
what would justify serializing it over the host `co_code`.

Both arrangements fit in 131 072 slots: a second host-built copy
(56 469 ≤ 74 603) and a firmware-emitted copy beside the resident
host image (41 178 ≤ 74 603). Two firmware copies (82 356) fit as
well. Heap does not need to grow.

### 1.3 What "compile the compiler" still needs

1. **Escapes.** Done. Unknown escapes stay rejected.
2. **Host test that every compiler file compiles.** Done. It checks
   that the emit fits in code RAM. It does not pin 41 178, because
   that number moves every time the emitter grows.
3. **Room for a second copy.** Done by raising code RAM to 131 072
   slots. `size_report.py` still compares free slots to the resident
   package (`used`), which is the host image that actually boots.
4. **Stage 2.** Emit is not execution. The emitted functions close
   over `_PYC_G` arenas (`nd_*`, `tk_*`, `kids`, the operator stack).
   A stage-2 compiler has to run in its own globals, not alias the
   stage-1 arenas. `_busy` (D9) makes a nested `compile()` a
   `ValueError`. The compiler source never calls `compile`, so a
   top-level exec of the emitted module does not trip it. Nothing
   tests that exec.
5. **Fixpoint.** Stage 2 compiling the same source must match stage
   1's words. No image does this (`img_bootstrap_compile_self` was
   planned and not added). The emitter is deterministic (no
   timestamps, no `CACHE`, fold is local), so byte-identity is a
   meaningful check once stage 2 runs.

### 1.4 Related ceilings that bite a long compile, not just self-host

- **No collector.** `compile()` does not mark or release. Arenas grow
  for the life of the call. The caller is supposed to bracket with
  `_bi_heap_mark` / `_bi_heap_release` and `_bi_code_mark` /
  `_bi_code_release` (`compiler.md`, lifetime). A process that
  compiles in a loop without that leaks. `img_compile_repeat` pins
  eight compiles of `"1 + 2"` at a watermark ≤ 400 000 bytes. A
  80 KB source is a different working set; it has not been measured
  on device.
- **Not re-entrant.** `_PYC_G` holds the source, the token SoA, the
  AST, and the emit buffers. `_busy` turns a nested entry into
  `ValueError`. A compiler that wanted to `compile()` a nested
  string (it does not today) cannot.
- **Single-core dicts do not grow.** A program's globals must be
  pre-bound with every name it stores, unless the machine is two-core
  and `PY_TRAP_DICT_GROW` is served. The compiler's own `_PYC_G` is
  sized at image build (`static_dict_slots`). A stage-2 package dict
  built at run time has to grow, so self-host execution wants the
  two-core configuration.
- **Frame window.** `nlocals + co_stacksize > 240` is a compile-time
  `SyntaxError` (D6). The subset gate caps the compiler's own
  functions at 200, so this is not what rejects the tree. It will
  reject a larger function someone later adds.
- **Wrapped int64.** Packed node and operator-stack fields must fit a
  signed 64-bit int. Host CPython will not catch a field that spills
  past bit 62; the device truncates it. `_pyc_ops_push` rejects an
  over-wide operator-stack field. A self-hosted compile of a huge
  `def` or call site can trip this where the host differential did
  not.

---

## 2. Programs that require async

`async def`, `await`, `async for`, and `async with` are compile-time
`SyntaxError` (`unsupported statement 'async'` / `'await'`). `yield`
is the same (`unsupported statement 'yield'`). That rejection is
required by A4: the machine cannot execute the bytecode, so the
compiler must not emit it.

Host image-boot cannot run these either.
`image_from_source.py` `DEFERRED_OPS` refuses `YIELD_VALUE`, `SEND`,
and `GET_AWAITABLE` before a hex image is built. `make lint-file` on
an `async def` fails. There is no path, host or on-device, that
compiles an async program into something the hart runs.

### 2.1 What CPython 3.14 actually emits

`async def f(x): y = await x; return y` (flags `0x83` =
`CO_OPTIMIZED | CO_NEWLOCALS | CO_COROUTINE`):

```text
RETURN_GENERATOR
POP_TOP
RESUME 0
LOAD_FAST x
GET_AWAITABLE 0
LOAD_CONST None
SEND → …
YIELD_VALUE 1
RESUME 3
JUMP_BACKWARD_NO_INTERRUPT
END_SEND
STORE_FAST y
LOAD_FAST y
RETURN_VALUE
CLEANUP_THROW
CALL_INTRINSIC_1 3    (INTRINSIC_STOPITERATION_ERROR)
RERAISE 1
```

`async for` adds `GET_AITER`, `GET_ANEXT`, `END_ASYNC_FOR`. The
exception table is part of the protocol, not optional.

### 2.2 Why that cannot run here

Each row is absent for a different reason. Landing the parser without
the rows under it produces a trap, which A4 forbids.

| Piece | Where it stands |
| --- | --- |
| `CO_COROUTINE` (`0x80`) | Not a metadata bit. `pack_code_metadata` stores `CO_VARARGS` (bit 64), `CO_VARKEYWORDS` (bit 65), and `posonlyargcount`. `CALL` always enters the body as a function. An async def would run its body immediately and hit `RETURN_GENERATOR`. |
| `RETURN_GENERATOR` | Not an `opcodes` row. It sits in `OBJ_GEN` ("suspendable/resumable frames", distance 5). Unlisted names in that group resolve as `trap`, not as a coroutine object. |
| `YIELD_VALUE`, `SEND`, `END_SEND`, `CLEANUP_THROW` | Same group. No RTL. `YIELD_VALUE` and `SEND` are `DEFERRED_OPS`. The frame stack is push/pop (`pycore_frame.sv`); nothing freezes a frame and resumes it. |
| `GET_AWAITABLE` | `OBJ_ITER` member, not an opcode row. `DEFERRED_OPS`: "async/await is deferred". |
| `GET_AITER`, `GET_ANEXT`, `END_ASYNC_FOR` | `OBJ_ITER` members, no opcode rows, no `__aiter__` / `__anext__` lookup. |
| `JUMP_BACKWARD_NO_INTERRUPT` | Catalog `reject`. CPython emits it on the `SEND` loop above, and on the cleanup edge of two `try` blocks (D13). The firmware compiler never emits it for `try`. An async backend that copied CPython's words would reintroduce the illegal opcode A4 exists to stop. Emit `JUMP_BACKWARD` instead. |
| `CALL_INTRINSIC_1` oparg 3 | Only oparg 6 (`INTRINSIC_LIST_TO_TUPLE`) executes. Oparg 3 is how a coroutine turns `StopIteration` into `RuntimeError`. |
| `StopAsyncIteration`, `GeneratorExit` | Absent. [`exception_support.md`](exception_support.md) Track 12. `END_ASYNC_FOR` matches `StopAsyncIteration` to end the loop. |
| Event loop | None. No scheduler, no tasks, no timer, no sockets. `open` is blocked on a missing filesystem (`pycore_firmware/builtins/open.md`). |

`NOT_TAKEN`, which appears in the `async for` stream, does execute.
That is the only opcode in the listing the hart already runs.

### 2.3 Generators are the same substrate

`yield` needs `RETURN_GENERATOR`, `YIELD_VALUE`, `SEND`, a resumable
frame, and `GeneratorExit`. Async needs that set plus `GET_AWAITABLE`
and the coroutine flag. Building async first means building a
generator machine and then not using it for `yield`. The exceptions
plan already puts both on Track 12.

### 2.4 What "compile and run async" means, in layers

**Layer A — one coroutine, no I/O.** Enough to run:

```python
async def add(x):
    return x + 1

def drive(c):
    # send None until the coroutine returns
    ...
```

Requires: resumable frames; `RETURN_GENERATOR` / `SEND` / `YIELD_VALUE`
/ `END_SEND` / `CLEANUP_THROW`; a `CO_COROUTINE` bit the call FSM
honors by returning a coroutine object instead of entering the body;
`GET_AWAITABLE` for `await` of that object; `CALL_INTRINSIC_1` oparg
3; `StopIteration` / `GeneratorExit` seeded. The compiler parses
`async def` and `await`, emits `JUMP_BACKWARD` rather than
`JUMP_BACKWARD_NO_INTERRUPT`, and sets the flag. A small driver
written in the existing subset (a loop that resumes the coroutine) is
the "run". No `asyncio`.

**Layer B — `async for`.** Adds `GET_AITER`, `GET_ANEXT`,
`END_ASYNC_FOR`, and a seeded `StopAsyncIteration`. `async with`
waits on Track 9 `with` (`LOAD_SPECIAL`, `WITH_EXCEPT_START`) plus the
async variants of those opcodes. Do not start `async with` before
synchronous `with`.

**Layer C — a scheduler.** Tasks, `sleep`, queues. Needs a timer
source and a run queue on top of Layer A. Still no operating-system
I/O. This is firmware, not a new opcode, but it is what people mean
by "a program that requires async" once `await` is more than a unary
call.

**Layer D — I/O.** Sockets, files, subprocesses. Out of scope for the
compiler. The machine has no filesystem and no network. Async syntax
will not create them.

Keep the parse rejection in place until Layer A executes. Emitting
`GET_AWAITABLE` into a hart that traps it is the failure A4 is written
to prevent.

### 2.5 Compiler work inside Layer A, once the hart can run it

- Treat `async` as a statement prefix (`async def`, later `async for`
  / `async with`), not as an unsupported keyword. `await` is an
  expression operator, not a statement. Both are already in
  `KEYWORDS`, which is why the errors are clean.
- A scope flag distinct from "function", stored somewhere the
  metadata word can carry. Bit 64 and bit 65 are taken.
- Codegen for the `SEND` loop. The exception table format the
  assembler already writes is the right container; the entries are
  new.
- Symtab: an async function's locals are ordinary locals. No new
  cell rules beyond closures, which already exist.
- Tests: a result differential is the wrong oracle for a coroutine
  that has not been driven. Compare the driver's result (`drive(add(1))
  == 2`), and keep a device image that does the same.

---

## 3. Correctness bugs in the landed grammar

### 3.1 Fixed

These used to parse, emit, and disagree with CPython. They are in
`test_compiler_differential.py` now.

- **`finally` on the way out.** `break`, `continue`, and `return`
  run active `finally` blocks, inner to outer, then take the original
  exit. A `return` inside `finally` wins. The inlined copies are holes
  in that `try`'s exception range, so a raise inside the inlined
  `finally` is not caught by the same `try`. The emitter still uses
  `JUMP_BACKWARD` (D13).
- **Unmatched `except` plus `finally`.** The handler cleanup
  (`COPY 3` / `POP_EXCEPT` / `RERAISE 1`) is covered by a `finally`
  handler, so the original exception runs the `finally` and then
  propagates. The host stand-in's exception unwind matches the hart:
  truncate to the table depth, optional lasti spacer, then the
  exception. `PUSH_EXC_INFO` pops the old TOS and pushes the previous
  active exception under it.
- **`except ... as e`.** A fast local is stored `None` and
  `DELETE_FAST`'d, including on the handler-raise path. A module-level
  name is stored `None` and left there: `DELETE_NAME` /
  `DELETE_GLOBAL` do not exist (D11). `del` of a closed-over name
  stays `SyntaxError`.
- **Comprehensions are a nested function.** The loop target does not
  leak. An outer binding of the same name is preserved. The iter
  expression is compiled in the enclosing scope. A second `for` or a
  second `if` is still `SyntaxError`.
- **Display slices and negative indexes.** A slice of a list or tuple
  display evaluates every element, drops the ones outside the clamped
  range, and builds the kept list or tuple. A negative index, and a
  non-constant index, go through `len` after an `isinstance(..., int)`
  check so a string dict key is not compared with `0`. Constant
  non-negative indexes and non-int constants are left alone.
  Non-constant bounds on a display are `SyntaxError` (`slice of a
  list or tuple display is not supported`).
- **Named rejections.** `match` / `case` are `is not supported`.
  `:=` is `named expressions are not supported`. A star where an
  operand is expected is `iterable unpacking is not supported`.
- **`for` / `while` `else`.** Exhaustion runs the `else` and then
  `POP_ITER`. `break` jumps to `POP_ITER` and skips the `else`. A
  false `while` test jumps to the `else`; `break` lands after it.

`LOAD_NAME` / `LOAD_GLOBAL` `NameError` and `LOAD_FAST` /
`LOAD_DEREF` `UnboundLocalError` consult the exception table on the
host stand-in. Other interpreter raises (a bad subscript, a compare
`TypeError`, `ZeroDivisionError`) still escape as raw Python
exceptions.

### 3.2 Still a runtime ceiling

A slice whose subject is a name stays `BINARY_SLICE`. Strings work.
A list or tuple in that name still traps `PY_TRAP_TYPE` on the hart.
The compiler cannot see the type. Slice assignment and a step stay
`SyntaxError`.

---

## 4. Language the compiler refuses

Each of these is a `SyntaxError` (or, for the shim, `ValueError`).
They are limitations, not miscompiles. The opcode column is what has
to exist before the rejection can go away. "Host images" notes
whether `make run-file` can already run the construct via CPython's
`compile()`, which is a different front end.

| Construct | Rejection | Blocked on | Host images |
| --- | --- | --- | --- |
| `async` / `await` / `async for` | `unsupported statement` | §2 | no (`DEFERRED_OPS`) |
| `yield` / generators | `unsupported statement 'yield'` | §2.3, Track 12 | no |
| `class` | `unsupported statement 'class'` | `LOAD_BUILD_CLASS`, frame-local namespace, `__build_class__` | module-level classes are folded at image build; a `class` inside `compile()` is not |
| `import` / `from` / `__future__` | `import is not supported` | module objects, a registry, a loader (`code_loading.md`) | no |
| `with` | `unsupported statement 'with'` | `LOAD_SPECIAL`, `WITH_EXCEPT_START` (exceptions T9) | no |
| `match` / `case` | `match` / `case` `is not supported` | `MATCH_*` (all `DEFERRED_OPS`) | no |
| `:=` | `named expressions are not supported` | `NAMED_EXPR` store | no |
| `lambda` of a non-literal default | `default argument must be a literal` | `SET_FUNCTION_ATTRIBUTE` flags 1 and 2. Only flag 8 (closure) executes. Defaults ride on the code object (D10) | host folder evaluates them at image build |
| positional-only `/` | `positional-only marker '/' is not supported` | compiler only. Metadata already has `posonlyargcount`; host images run `/` | yes |
| annotations, `->` | `annotations are not supported` | `SET_FUNCTION_ATTRIBUTE` 16, `SETUP_ANNOTATIONS` | stripped or folded |
| `*args` at a **call** (`f(*xs)`, `f(**kw)`) | `iterable unpacking is not supported` | compiler only. `CALL_FUNCTION_EX` executes; the host stand-in does not | yes |
| `{**d}` | `iterable unpacking is not supported` | `DICT_UPDATE` / `DICT_MERGE` (partial, excore) | yes |
| `@` matmul | `unexpected input after expression` | `BINARY_OP` oparg for matmul, no datatype | no |
| generator expression | `generator expressions are not supported` | §2.3 | no |
| second `for` or second `if` in a comprehension | `nested comprehension` / `multiple comprehension ifs` | another nested code object per clause | yes |
| `except*` | `except* is not supported` | `CHECK_EG_MATCH`, `CALL_INTRINSIC_2` (T11) | no |
| `raise X from Y` | `raise-from is not supported` | `RAISE_VARARGS` oparg 2 | no |
| slice step, slice store | `slice step` / `slice assignment` | `BINARY_SLICE` has no step; `STORE_SLICE` is deferred | step rejected; unit step folded for strings |
| `del` of a global / module name | `del of a global name is not supported` | `DELETE_NAME`, `DELETE_GLOBAL` are not in the catalog (D11) | no |
| `del` of a cell | `cannot delete closed-over name` | `DELETE_DEREF` (`trap`) | no |
| bytes literals | `bytes literals are not supported` | `BYTES` tag is reserved | no |
| complex literals (`1j`) | `complex literals are not supported` | complex ALU exists for operations; the literal parser does not | literals via host `compile` only if the image path accepts them |
| `\u` and octal escapes | `unsupported escape sequence` | a Unicode / octal decoder. `\n` `\t` `\r` `\\` `\'` `\"` `\xHH` and the short control escapes already decode | yes |
| `"single"` mode, `flags != 0`, `optimize` not in `{0, -1}` | `ValueError` from the shim | REPL printing for `"single"`; future-flag bits | n/a |
| more than 240 locals, or frame window over 240 | `too many locals` / `frame window too large` | the register-file window (D6). Not a grammar gap | host images trap `CALL_FILTER` instead |
| non-literal default, duplicate `*`, keyword-after-positional | `SyntaxError` | some are genuine Python errors; non-literal defaults are D10 | non-literal defaults work on host images |

`dont_inherit` is accepted and ignored. `filename` is stored on
`_PYC_G["_in_file"]` and never opened (D8). There is no filesystem.

---

## 5. Landed features with a ceiling

These match CPython inside the ceiling and stop matching outside it.

| Ceiling | Behavior |
| --- | --- |
| No `CACHE` (D1) | `co_code` is not CPython's. Results are the oracle. |
| Constant folding (D2) | Int `+ - * & \| ^`, unary `-` `~`, and `str +` fold to a constant. `/ // % ** << >>` stay as `BINARY_OP`, so `1/0` still raises at run time. |
| Unary `+` | The operand is visited and no opcode is emitted. `CALL_INTRINSIC_1` oparg 5 (`UNARY_POSITIVE`) is not in the allowlist. Fine for ints; a user type with `__pos__` would be wrong. User types are barely callable from this compiler anyway (`class` is rejected). |
| F-strings | `FORMAT_SIMPLE`, `CONVERT_VALUE` 1/2/3, `BUILD_STRING`. No format spec, no `f"{x=}"`, no nested f-strings, no t-strings. `BUILD_STRING` requires every piece to be a `SHORT_STR` and the total length ≤ 15; otherwise the hart raises `TYPE`. A long f-string compiles and traps. |
| `assert` | Rewritten to load `AssertionError` and `RAISE_VARARGS` 1. `LOAD_COMMON_CONSTANT` stays `trap`. An assert message is a `CALL` of the exception type. |
| Decorators | `CALL 0` with the function in the self slot. No `PUSH_NULL`. Identity decorators work (`img_compile_decorator`). A decorator that is a method needs the call shape the hardware uses for methods. |
| Closures | `MAKE_CELL`, `LOAD_DEREF`, `STORE_DEREF`, `COPY_FREE_VARS`, `SET_FUNCTION_ATTRIBUTE` 8. `LOAD_CLOSURE` and `LOAD_FROM_DICT_OR_DEREF` are `trap` and not emitted. |
| Two `try` blocks in one function | The firmware compiler emits `JUMP_BACKWARD` and the result matches (measured: both sides leave `x == 3`). D13 is the **host** image builder, which rejects CPython's `JUMP_BACKWARD_NO_INTERRUPT`. Splitting into two functions is a host-image workaround, not a firmware-compiler bug. |
| `LOAD_NAME` | Globals then builtins. Full LEGB for a function or `exec` scope is not implemented (`bytecode_support.md`). Nested functions that are real closures go through `LOAD_DEREF`, which is why that case works. |
| Comprehension growth | `LIST_APPEND` / `SET_ADD` / `MAP_ADD` grow through excore. Device images that build a non-empty comprehension are two-core (`img_compile_list_comp`). Inside a function whose only assignment of the target is the comprehension, CPython 3.14 raises `UnboundLocalError` and this compiler raises `NameError`. |
| Name as a slice subject | `BINARY_SLICE`. Strings work. A list or tuple in that name traps `TYPE` on the hart (§3.2). |
| Module-level `except as` | The name is stored `None`. It is not deleted, so a later load does not raise `NameError` (§3.1). |
| Int width | 64-bit, wraps. Folding happens in the firmware, which on the host is arbitrary precision, then the constant is truncated when it is boxed for the device. A fold of `2 ** 62` is not the same bit pattern CPython keeps. `**` is not folded, which avoids the worst of this; `*` is folded. |
| Comparisons | Signed 64-bit and the string ceilings in `bytecode_support.md`. The compiler will emit `COMPARE_OP` for any compare; the trap is in the ALU. |
| Recursion | Not a compile error. Deep recursion is `MEM_FAULT` when the spill region fills. |

---

## 6. Compiler mechanics still open

| Item | State |
| --- | --- |
| Split result / scratch arenas (O-2) | Not started. Caller mark/release is the reclaim path. Open it when `img_compile_repeat`'s watermark stops holding. |
| Module loader, relocation, overlays | Not started. The compiler fits the boot image (56 469 / 131 072, 74 603 free). Overlays are not what unblocked the second copy; the larger code RAM did. |
| `compile()` of `"single"` | `ValueError`. A REPL would need it. |
| Re-entrancy beyond the guard | The guard is the whole feature. Arenas are process-global. |
| Diagnostics | Unsupported keywords, `match` / `case`, `:=`, and a starred operand name themselves. Positions are carried on tokens (`line << 24 \| col << 8`) but many `_pyc_parse_error` messages have no source span in the text the user sees. |
| Emitter allowlist drift | `tables.py` is generated from `pycore.json`. CI checks regeneration. The human list in `compiler_design.md` Appendix B is not the source of truth. |
| Self-host compile test | `test_firmware_compiler_compiles_its_own_sources` compiles every file. It does not exec the result (§1.3 steps 4–5). |
| Async test | Does not exist. §2 is the spec. Keep the `SyntaxError` until `SEND` returns. |

---

## 7. Order to do the work

Not a schedule. Each line unblocks the next. Items 1–4 of the previous
list are done: `finally` / `except as` / comprehensions, the A4
display-slice and negative-index holes, named `match` / `:=` / star
errors, ordinary escapes, the compile-the-tree host test, and a code
RAM large enough for a second copy of the boot compiler. The boot
image stayed the host build because it executes fewer real opcodes
(§1.2).

1. **Stage-2 fixpoint** (§1.3 steps 4–5). Exec the emitted compiler
   in its own globals and check that a second compile matches the
   first. `size_report.py` compares free slots to the resident host
   package, which is the image that boots.
2. **Call-site `*args` / `**kwargs` and `/`.** Hardware already runs
   `CALL_FUNCTION_EX` and stores `posonlyargcount`. The host stand-in
   does not expand `CALL_FUNCTION_EX` and does not enforce
   positional-only, so those two have to land together or the
   differential cannot see them.
3. **Generator frames, then Layer A async** (§2). Do not parse `async`
   successfully until `SEND` returns. `yield` and `await` share the
   frame work; land it once.
4. **`with`, then `async with`.** Exceptions Track 9, then Layer B.
5. **Runtime `class`, `import`, the module loader.** Needed for a
   second compiler that is a real package rather than one flat
   `_PYC_G`. Not needed to compile the current tree, which has no
   imports.
6. **Scheduler and I/O** (§2 Layer C–D) only after a coroutine
   actually resumes.
