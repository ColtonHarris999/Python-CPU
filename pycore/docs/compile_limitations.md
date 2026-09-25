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
`compiler.md`'s occupancy paragraph still quotes the post-§11.5 figure
(45 995 slots, 19 541 free). `pycore_firmware/builtins/compile.md` still
says `*args` / defaults are `SyntaxError` and that re-entrancy is
deferred. Both are stale. Current occupancy is the size-report block in
§1.

## What already works

`compile(source, filename, mode)` with `mode` of `"exec"` or `"eval"`
returns a code object that `exec` / `eval` can run. The landed grammar
is literals, names, arithmetic, comparisons, boolean ops, calls
(positional and keyword), subscripts, attributes, assignment (including
chained and `;`), `if` / `while` / `for`, `break` / `continue` / `pass`,
augassign, `del` of a local or a subscript, displays, unpack, `def`
with literal defaults / `*args` / keyword-only / `**kwargs`, `global`,
`lambda`, decorators, `assert`, simple f-strings, `try` / `except` /
`else` / `finally`, `raise`, single-generator comprehensions with one
`if`, string slices, and closures. Differentials compare results, not
`co_code` (`pycore/tests/test_compiler_differential.py`).

Everything in the rest of this file is outside that set, or inside it
but wrong.

---

## 1. Compiling the compiler

Self-host means: the resident compiler compiles
`pycore_firmware/compiler/*.py`, the result is installed as code, and a
second compile of the same source matches the first. None of that
exists. `make pycore-size-report` is the only check, and it is a proxy.

### 1.1 The source is not in the grammar the compiler accepts

`pycore/tests/test_compiler_subset.py` is a different gate. It compiles
the tree with **host** CPython and rejects opcodes and shapes the
machine cannot run. The tree passes that gate. The on-device parser is
stricter about source text, and the subset gate does not look at it.

Compiling each file with the ROM `compile` shim (host stand-ins in
`load_rom_firmware_callables`) :

| File | Bytes | As written | Slots once it parses |
| --- | ---: | --- | ---: |
| `toy.py` | 209 | compiles | 23 |
| `compat.py` | 882 | compiles | 84 |
| `tables.py` | 11 975 | compiles | 1 154 |
| `symtab.py` | 17 486 | compiles | 2 697 |
| `codegen.py` | 45 473 | compiles | 6 837 |
| `lexer.py` | 19 954 | `SyntaxError` (escapes) | 2 882, after rewriting the literals |
| `parser.py` | 79 686 | `SyntaxError` (escapes) | 10 725, after rewriting the literals |
| **Total** | | | **24 402** |

`lexer.py` has 13 non-raw string literals that contain a backslash
(`"\n"`, `"\t"`, `"\\"`). `parser.py` has 7. Those characters are how
the lexer recognizes newlines, indentation, and escape processing.
`_pyc_parse_string` rejects any non-raw literal whose body contains
`\` (`parser.py`). It does this on purpose: returning the raw slice
would make `"a\tb"` two characters where CPython makes one. The
f-string middle path already decodes `\n` `\t` `\r` `\\` `\'` `\"`.
Ordinary literals do not.

No other construct in the seven files is rejected. The tree does not
use `class`, `import`, `async`, `with`, `lambda`, f-strings,
decorators, closures, annotations, comprehensions, or `try`. A
mechanical rewrite of those 20 literals to `chr()` concatenations is
enough for every file to parse and emit. That rewrite is not in the
tree, and nothing in CI attempts this compile. The old bootstrap plan
(`planning/old/native_compiler_plan.md` C9) called for a host test that
fails when any compiler file is outside the ROM grammar. It was never
added.

### 1.2 The output does not fit beside the resident compiler

`make pycore-size-report` on `img_compile_eval_expr` (this tree):

| Region | Used | Capacity | Remain |
| --- | ---: | ---: | ---: |
| Code ROM | 2 669 | 8 192 | 5 523 |
| Code RAM (compiler) | 50 028 | 65 536 | 15 508 |
| Heap (static image) | 350 464 | 981 952 | 631 488 |

The report prints `self-host: blocked (need 50028 output slots, have
15508 headroom)`. That comparison assumes the output is the same size
as the **host-built** package. The host build is CPython 3.14 bytecode,
`CACHE` included. The firmware compiler emits no `CACHE`. Measured
firmware emit of the same seven files is **24 402** slots, not 50 028.

24 402 still does not fit in the 15 508 free slots. The hole is 8 894
slots, not the 34 520 the size report implies.

| Arrangement | Slots | Fits in 65 536? |
| --- | ---: | --- |
| Host-built compiler alone (today's boot image) | 50 028 | yes |
| Firmware-emitted compiler alone | 24 402 | yes |
| Host-built resident + firmware-emitted output | 74 430 | no |
| Two firmware-emitted copies | 48 804 | yes |

So the size wall is specifically the first install. A firmware-built
compiler would be small enough to compile a second copy beside itself.
It cannot be produced while the host-built compiler is the thing
running, because the free region is 15 508 and the output is 24 402.

Per file, the largest module is `parser.py` at 10 725 slots, which
**does** fit in the hole. A whole-package emit does not. There is no
second executable memory. Code RAM is the only place a code object can
run, and the compiler does not spill emitted words anywhere else.

Heap can hold the bits. 24 402 slots × 8 bytes is 195 216 bytes, and
631 488 bytes of heap remain after the static image. Nothing copies a
finished module out to the heap and blits it back after
`_bi_code_release`. `_bi_code_blit` only writes the live bump pointer's
region.

### 1.3 What "compile the compiler" still needs

In order:

1. **Decode ordinary string escapes**, at least `\n` `\t` `\r` `\\`
   `\'` `\"`, using the decoder the f-string path already has. Until
   that lands, `lexer.py` and `parser.py` are not expressible.
   Rejecting unknown escapes (the current D5 stance) should stay.
2. **A host test** that runs `compile()` on every file in
   `pycore_firmware/compiler/` and fails on `SyntaxError`. Pin the
   24 402-slot total so a later grammar change cannot silently push
   the output back over the hole.
3. **An install path for the first firmware-built image.** Any one of:
   - Raise code RAM so free ≥ 24 402 while the host-built package is
     resident. That is a capacity of at least 50 028 + 24 402 = 74 430
     slots (today: 128 blocks × 512).
   - Shrink the host-built package until free ≥ 24 402 (the package
     has to lose about 8 894 slots). Lever named in the design is
     shrinking `codegen.py`, then overlays. Overlays are not started.
   - Compile one module at a time into the 15 508-slot hole (the
     largest, `parser.py`, fits), copy the words to the heap, release
     the code mark, and after the last module have a ROM helper blit
     the heap image over the old compiler. The compiler cannot blit
     that image itself: releasing it is what frees the slots.
4. **Run stage 2.** Emit is not execution. The emitted functions close
   over `_PYC_G` arenas (`nd_*`, `tk_*`, `kids`, the operator stack).
   A stage-2 compiler has to run in its own globals, not alias the
   stage-1 arenas. `_busy` (D9) makes a nested `compile()` a
   `ValueError`. The compiler source never calls `compile`, so a
   top-level exec of the emitted module does not trip it. Nothing
   tests that exec.
5. **Fixpoint.** Stage 2 compiling the same source must match stage
   1's words. No image does this (`img_bootstrap_compile_self` was
   planned and not added). Byte-identity is only meaningful after the
   emitter is deterministic, which it is today (no timestamps, no
   `CACHE`, fold is local).

Until step 3, "self-host: blocked" is the right one-line status. The
number in that line should become 24 402 once escapes parse, because
50 028 is the host image, not the compiler's own output.

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

These parse, emit, and disagree with CPython. Confirmed by compiling
the snippet with the ROM shim and running the host stand-in against
CPython 3.14. The differential corpus does not contain them.

### 3.1 `finally` does not run on the way out

`break`, `continue`, and `return` emit a jump or `RETURN_VALUE`
straight to the loop or the caller (`codegen.py`). They do not route
through an active `finally`. The `finally` body is only visited from
the normal-completion path and from a handler that matched.

| Program | Firmware | CPython |
| --- | --- | --- |
| `while` / `try: break` / `finally: x = 1` | `x == 0` | `x == 1` |
| `try: return 1` / `finally: return 2` | returns 1 | returns 2 |
| `try: return 1` / `finally: g = 7` | `g == 0`, returns 1 | `g == 7`, returns 1 |
| `for` / `try: continue` / `finally: x += 10` | `x == 24` | `x == 34` |

A `try` that does not raise, and an `except` that matches, do run the
`finally` (both sides give `x == 11` for the obvious snippets). The
bug is the non-local exits.

Fix: a try stack in codegen. `break` / `continue` / `return` inside a
`try` with a `finally` must jump to the finally and then to the
original target. CPython's `JUMP_BACKWARD_NO_INTERRUPT` shows up on
this edge in host-compiled functions; the firmware emitter has to keep
using `JUMP_BACKWARD` (D13).

### 3.2 Unmatched `except` plus `finally` underflows

When the `try` has at least one handler and a `finally`, a
non-matching exception falls into a cleanup block whose body is
`COPY 3`, `POP_EXCEPT`, `RERAISE 1`. The `finally` statements are not
in that block. On the host stand-in, `COPY 3` indexes off the stack
and raises `IndexError`. The documented line ("unmatched-except +
finally may skip the finally") understates it: the sequence does not
run, and it does not fail as a Python exception.

The no-handler `try` / `finally` path is a different block and does
run the `finally` (`img_compile_try_finally`).

### 3.3 `except ... as e` leaves `e` bound

The handler stores the name and never deletes it. After the block,
`e` is still the exception instance. CPython unbinds it (and drops
the traceback cycle) at block exit. `DELETE_FAST` executes, so a
function-local name can be cleared. `DELETE_NAME` / `DELETE_GLOBAL`
do not exist, so a module-level `e` cannot be cleared until those
opcodes exist; the compiler should still `DELETE_FAST` when `e` is a
local. `del` of a closed-over name stays `SyntaxError` (`DELETE_DEREF`
is `trap`).

### 3.4 Comprehensions are not a scope

`[i for i in [1, 2, 3]]` leaves `i == 3` in the enclosing namespace.
CPython compiles the comprehension as a nested function, so `i` is
invisible outside. The leak is `STORE_NAME` / `STORE_FAST` of the
target in the enclosing scope. There is also no exception-table
cleanup around the `FOR_ITER`: an element expression that raises does
not run `END_FOR`.

Isolating the comprehension means a nested code object, the same
`MAKE_FUNCTION` path `def` already uses. That also removes the leak.
It costs a code object per comprehension and is the main reason a
"just add a second `for`" change is not a parser tweak.

### 3.5 A4 holes: accepted source the hart traps on

A4 says a construct the machine cannot execute is a `SyntaxError`
from the compiler. These parse and emit anyway:

| Source | What is emitted | On the hart |
| --- | --- | --- |
| `[1, 2, 3][0:2]` | `BINARY_SLICE` | `PY_TRAP_TYPE`. Strings only (`bytecode_support.md`). The host stand-in returns `[1, 2]` because it slices with CPython. |
| `[1, 2, 3][-1]`, `'ab'[-1]` | negative index | `PY_TRAP_TYPE` (deviation 3). |
| a slice whose subject is a name, when that name later holds a list | `BINARY_SLICE` | same trap. The compiler cannot see the type. |

Slice assignment (`x[0:2] = ...`) and a step (`s[1:3:2]`) are rejected,
which is right. The missing check is: reject a slice whose subject is
a list or tuple display, and reject a negative index or negative
slice bound. A name used as a slice subject cannot be rejected
honestly without a type. Document it as a runtime ceiling, the way
negative bounds on strings already are, or reject every non-string
display.

`match` / `case` are not in `KEYWORDS`, so `match 1: case 1: x = 1`
fails with `unexpected input after statement` instead of a named
rejection. `:=` fails with `unmatched bracket`. Both should be the
same class of message as `async`.

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
| `match` / `case` | generic parse error | `MATCH_*` (all `DEFERRED_OPS`) | no |
| `:=` | `unmatched bracket` | `NAMED_EXPR` store | no |
| `lambda` of a non-literal default | `default argument must be a literal` | `SET_FUNCTION_ATTRIBUTE` flags 1 and 2. Only flag 8 (closure) executes. Defaults ride on the code object (D10) | host folder evaluates them at image build |
| positional-only `/` | `positional-only marker '/' is not supported` | compiler only. Metadata already has `posonlyargcount`; host images run `/` | yes |
| annotations, `->` | `annotations are not supported` | `SET_FUNCTION_ATTRIBUTE` 16, `SETUP_ANNOTATIONS` | stripped or folded |
| `*args` at a **call** (`f(*xs)`, `f(**kw)`) | `expected expression` | compiler only. `CALL_FUNCTION_EX` executes | yes |
| `{**d}` | `expected expression` | `DICT_UPDATE` / `DICT_MERGE` (partial, excore) | yes |
| `@` matmul | `unexpected input after expression` | `BINARY_OP` oparg for matmul, no datatype | no |
| generator expression | `generator expressions are not supported` | §2.3 | no |
| second `for` or second `if` in a comprehension | `nested comprehension` / `multiple comprehension ifs` | nested code objects (§3.4) plus the parser | yes |
| `for` / `while` `else` | `for-else` / `while-else` | parser + a jump around the else on `break` | yes |
| `except*` | `except* is not supported` | `CHECK_EG_MATCH`, `CALL_INTRINSIC_2` (T11) | no |
| `raise X from Y` | `raise-from is not supported` | `RAISE_VARARGS` oparg 2 | no |
| slice step, slice store | `slice step` / `slice assignment` | `BINARY_SLICE` has no step; `STORE_SLICE` is deferred | step rejected; unit step folded for strings |
| `del` of a global / module name | `del of a global name is not supported` | `DELETE_NAME`, `DELETE_GLOBAL` are not in the catalog (D11) | no |
| `del` of a cell | `cannot delete closed-over name` | `DELETE_DEREF` (`trap`) | no |
| bytes literals | `bytes literals are not supported` | `BYTES` tag is reserved | no |
| complex literals (`1j`) | `complex literals are not supported` | complex ALU exists for operations; the literal parser does not | literals via host `compile` only if the image path accepts them |
| string escapes in ordinary literals | `escape sequences ... are not supported` | a decoder (§1.1). This is the self-host blocker | yes |
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
| Comprehension growth | `LIST_APPEND` / `SET_ADD` / `MAP_ADD` grow through excore. Device images that build a non-empty comprehension are two-core (`img_compile_list_comp`). |
| Int width | 64-bit, wraps. Folding happens in the firmware, which on the host is arbitrary precision, then the constant is truncated when it is boxed for the device. A fold of `2 ** 62` is not the same bit pattern CPython keeps. `**` is not folded, which avoids the worst of this; `*` is folded. |
| Comparisons | Signed 64-bit and the string ceilings in `bytecode_support.md`. The compiler will emit `COMPARE_OP` for any compare; the trap is in the ALU. |
| Recursion | Not a compile error. Deep recursion is `MEM_FAULT` when the spill region fills. |

---

## 6. Compiler mechanics still open

| Item | State |
| --- | --- |
| Split result / scratch arenas (O-2) | Not started. Caller mark/release is the reclaim path. Open it when `img_compile_repeat`'s watermark stops holding. |
| Module loader, relocation, overlays | Not started. The compiler fits the boot image (50 028 / 65 536). Overlays are the lever if §1.3 shrinks code RAM pressure without a larger RAM. |
| `compile()` of `"single"` | `ValueError`. A REPL would need it. |
| Re-entrancy beyond the guard | The guard is the whole feature. Arenas are process-global. |
| Diagnostics | Most unsupported keywords name themselves. `match`, `:=`, and `*` in a call do not (§3.5, §4). Positions are carried on tokens (`line << 24 \| col << 8`) but many `_pyc_parse_error` messages have no source span in the text the user sees. |
| Emitter allowlist drift | `tables.py` is generated from `pycore.json`. CI checks regeneration. The human list in `compiler_design.md` Appendix B is not the source of truth. |
| Self-host test, async test | Neither exists. §1 and §2 are the specs. |

---

## 7. Order to do the work

Not a schedule. Each line unblocks the next.

1. **Fix §3** (`finally` on `break` / `continue` / `return`, the
   unmatched-`except` cleanup, `DELETE_FAST` of `except as`,
   comprehension scopes). These are wrong answers, not missing
   syntax. Add the four snippets to the differential corpus so they
   cannot regress.
2. **Close the A4 holes** for list/tuple slice displays and negative
   indexes, and name the `match` / `:=` / starred-call errors.
3. **String-escape decoder** for ordinary literals, plus the
   compile-the-tree host test (§1.1). That is the language half of
   self-host.
4. **Install path** (§1.3 step 3). Pick one of larger code RAM, a
   smaller host image, or heap-spill plus a ROM blit. Then a device
   image that compiles one compiler module and runs a function from
   the result.
5. **Stage-2 fixpoint** once a firmware-built compiler fits beside
   itself (48 804 ≤ 65 536). Update `size_report.py` to compare free
   slots against firmware-emitted size, not against the host-built
   50 028.
6. **Call-site `*args` / `**kwargs` and `/`.** Hardware already runs
   `CALL_FUNCTION_EX` and `posonlyargcount`. This is compiler-only
   and unblocks a lot of ordinary Python that is not async and not
   self-host.
7. **Generator frames, then Layer A async** (§2). Do not parse `async`
   successfully until `SEND` returns. `yield` and `await` share the
   frame work; land it once.
8. **`with`, then `async with`.** Exceptions Track 9, then Layer B.
9. **Runtime `class`, `import`, the module loader.** Needed for a
   second compiler that is a real package rather than one flat
   `_PYC_G`. Not needed to compile the current tree, which has no
   imports.
10. **Scheduler and I/O** (§2 Layer C–D) only after a coroutine
    actually resumes.
