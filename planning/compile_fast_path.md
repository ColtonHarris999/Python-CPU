# Fast path to builtin `compile()`

**Status:** proposed working list (narrows Plan 1 §14 for the first `compile()`)
**Audience:** firmware compiler agent, pycore RTL agent
**Does not replace:** [`native_compiler_plan.md`](native_compiler_plan.md) (Plan 2) or
[`code_loading_bios_tokenizer_plan.md`](code_loading_bios_tokenizer_plan.md) (Plan 1).
Those remain the completeness / bootstrap contracts. This file is the **shortest
path to `exec(compile(src, "<s>", "eval"))` returning a correct result**.

**Rule of this list:** prefer a compiler written against today's ISA over new
hardware, as long as the rewrite is O(n) with the same algorithm (a Python
index loop instead of a slice, `xs[len(xs)-1]` instead of `xs[-1]`). Add
pycore only when (a) there is no honest rewrite, or (b) the rewrite would be
the same class of bug-farm that `lst.append` → `lst += [x]` was — dozens of
sites, host CPython no longer running the same source.

Native `LOAD_ATTR` methods (list/set/str/dict) and `e.args` are the model for
(b). They are in [PR #86](https://github.com/ColtonHarris999/Python-CPU/pull/86).

---

## 1. What is already enough

Do **not** wait for Plan 1 to be "complete". First `compile()` needs this, and
most of it is already on `main` (methods: PR #86):

| Need | Status |
| --- | --- |
| Execute precompiled `CODE_OBJECT`s | **Done** (`exec(code)`, `eval(code)`, `exec(code, globals)`) |
| Code RAM region + fetch mux | **Done** (P1). Nothing writes it at runtime yet |
| `code_ram_ptr_r` + heap/code mark/release | **Done** (P8) |
| String `BINARY_SLICE`, `ord` / `chr`, `for` over LIST/STR/DICT/RANGE | **Done** |
| `list.append` / `pop` / `extend` / `clear` | **Done** (native method table) |
| `str.join` / `startswith` / `endswith` / `find` | **Done** |
| `dict.get` / `keys` / `items` / `update` / `pop` / `values` | **Done** |
| `set.add` / `update` | **Done** |
| `raise SyntaxError("msg")` and `e.args[0]` | **Done** |
| `MAKE_FUNCTION`, `CALL`, `CALL_KW`, `LIST_TO_TUPLE` (`(*lst,)`), unpack | **Done** |
| `try` / `except` (not `finally` / `with`) | **Done** |

First success looks like:

```python
code = compile("1 + 2", "<s>", "eval")
assert eval(code) == 3
```

No BIOS, no module loader, no string-form `exec`, no self-host.

---

## 2. Compiler subset — write this in from day one

The compiler (`pycore_firmware/compiler/`) is ordinary Python that has to run
on PyCore. Every construct below has a rewrite with the **same complexity
class**. Using them keeps Plan 2 C10 (closures, `class`, `import`, …) off the
critical path, and is the host test Plan 2 §10 already wanted: *the compiler
must compile its own source*.

A host gate (`test_compiler_subset.py`) should reject any compiler file that
uses a banned form, so this does not become a late rewrite.

| Banned in compiler source | Rewrite (same algorithm) | Why not hardware now |
| --- | --- | --- |
| `xs[a:b]` / `xs[i:]` on **list/tuple** | `copy_range(xs, a, b)`: `while` + `append` | String slice already exists; list slice is nice-to-have, not blocking. AST nodes are indexed by constant (`node[3]`), not sliced |
| `xs[-1]`, `s[:-1]` | `xs[len(xs)-1]`, `s[0:len(s)-1]` | Deviation 3. Hardware wrap is a large bounds-check change |
| Slice assignment `xs[a:b] = …` | Rebuild / `while` stores | `STORE_SLICE` is a new opcode FSM |
| `str.split` / `strip` / `replace` | `find` + slice loops (strings **are** sliced) | Method-table expansion is optional later |
| `getattr` / `setattr` / `hasattr` | Direct dict / `LOAD_ATTR` of a constant name | Firmware `getattr` does not walk MRO and does not raise |
| `type(x) is str` | Don't branch on native tags; keep tokens tagged in the token tuple | `obj.__class__` is OBJECT-only today |
| Tuple dict keys / PEG memo `(rule, pos)` | Nested dict `memo[rule][pos]`, or a packed `SHORT_STR` key | Dict keys reject `TUPLE` |
| Classes / inheritance / `__slots__` | Tagged lists + functions (Plan 2 C2) | `LOAD_BUILD_CLASS` is deferred |
| Nested fn closing over outer locals | Pass an explicit `env` dict / extra args | `MAKE_CELL` / `LOAD_DEREF` is C10 |
| `import` | One image-resident package (functions already in globals) | Module objects + registry |
| f-strings | `str` concat / `"".join` | `FORMAT_WITH_SPEC` deferred; MVP FORMAT is SHORT_STR-only |
| List/dict/set comprehensions in *compiler* source | `for` + `append` / store | Comprehensions run, but they need two-core grow; loops are simpler to budget |
| `with`, `try/finally`, `assert`, `match`, `async` | `try/except` + explicit cleanup; no `assert` | Separate exception tracks (T7/T9) |
| Decorators / `lambda` | `def` | Nothing new, just keep the subset small |
| `CACHE` in *emitted* code | Emit none (fetch already skips them) | Required regardless |
| Long identifiers as dict keys (>15 bytes) in v1 | Keep compiler names `SHORT_STR`; v1 user programs: names ≤ 15 bytes **or** intern (F2 below) | Full LONG_STR content-eq on every dict probe is P6.4 — large, hot |

Helpers live in `pycore_firmware/compiler/compat.py` (names indicative):

```python
def copy_range(xs, start, stop):
    n = len(xs)
    if start > n:
        start = n
    if stop > n:
        stop = n
    out = []
    i = start
    while i < stop:
        out.append(xs[i])
        i = i + 1
    return out
```

That is the same O(n) copy a `BINARY_SLICE` FSM would do. Cycle cost is worse;
algorithmic cost is equal. Do **not** block the tokenizer on list slice.

Flatten PyPy `NonGreedyDFA(DFA)` into two functions (Plan 1 §2.3 already
requires this).

---

## 3. Pycore changes — must, cheap, later

### 3.1 Must (no rewrite exists)

These are the `list.append` of `compile()`: small, contained, and the pipeline
cannot emit a runnable code object without them.

| ID | Change | Layer | Why it cannot be rewritten |
| --- | --- | --- | --- |
| **F1** | `_bi_code_alloc(nslots) -> INT` | CALL FSM + `code_ram_ptr_r` | Bump-reserve code RAM. Mark/release already move this pointer; alloc is the missing "heap malloc" for slots |
| **F1** | `_bi_code_emit(slot, opcode, oparg)` | CALL FSM + **code-mem write mux** | Fetch currently hard-wires `imem_we_o = 0`. The RAM bank already accepts `we_i`. This is one on-core writer (excore cannot reach imem). Absolute slot addressing so jump patching is a re-emit |
| **F1** | `_bi_code_new(fields) -> CODE_OBJECT` | CALL FSM + heap alloc | Clone of host `HeapImageBuilder.alloc_code`. 8 on-heap fields; flags as a 9th Python argument so `*args`/`**kwargs` metadata is not stuffed into an i64 (Plan 2 §6.3) |
| **F1** | Host stand-ins in `image_from_source.py` | tooling | Same instruction stream under CPython. **Highest-leverage test asset** — C1–C5 debug off-device |

`code_loading.md` already says these are the only missing writers. Do not invent
a module-image loader to get there.

### 3.2 Cheap and high leverage (append-shaped) — after F1, only if the subset hurts

Do these the way native methods landed: one table/FSM, firmware bodies, image
tests. Not before the first round-trip.

| ID | Change | When to pull it in |
| --- | --- | --- |
| **P** | Tokenizer (Plan 1 P9) as **firmware**, not RTL | Required for `compile(str)`, but it is Python. Start it in parallel with F1 using the subset in §2. String slice + methods already cover the §2.3 audit except `indents[1:]` → `copy_range` |
| **C1–C5** | Parser / AST / symtable / codegen / assembler | Firmware. Tiny expression grammar first (Plan 2 §4.1). Emit only allowlisted opcodes |
| **C7a** | ROM `compile(source, filename, mode)` with `flags==0`, mode `"eval"` then `"exec"` | Firmware wrapping C1–C5 + F1. `"single"` raises |
| **O1** | List/tuple `BINARY_SLICE` | Pull in if `copy_range` shows up at many sites *and* a profiler/size report says the helper is the budget problem. Same FSM shape as `CONT_SLICE_STR` without UTF-8 |
| **O2** | Expand native-method table 16 → 32: `str.split` / `strip` / `replace` / `isidentifier`, `list.insert` / `copy` | Only after a tokenizer/parser file would otherwise be a nest of `find` loops. Index width is 4 bits today |
| **O3** | `_bi_intern(s) -> str` | Canonical LONG_STR handle. **Cheaper than P6.4** (does not change dict probe equality; interned strings keep descriptor identity). Needed when user programs grow names past 15 bytes |
| **O4** | `_bi_code_kind` **or** `__class__` on native tags | Only for string-form `exec`/`eval` dispatch. v1 is `eval(compile(s, …))` — two builtins, no dispatch |
| **O5** | F2 `getattr` raises `AttributeError`; empty `min`/`max` raise `ValueError` | Compiler should not call them. Firmware correctness, not a compile blocker |

### 3.3 Do not do on this path

Large, or fully avoided by §2. Revisit under Plan 2 C10 / remaining Plan 1.

| Item | Why it is off the path |
| --- | --- |
| BIOS (P5) | Test programs call `compile` directly. BIOS is the later OS entry |
| Module format + relocation (P2) | Compiler lives in the boot image; output is a `CODE_OBJECT` handle, not a relocated module |
| LONG_STR content equality on every dict/set probe (P6.4) | Use SHORT_STR names in v1; intern builtin (O3) if needed |
| Negative indices in hardware | Rewrite |
| `STORE_SLICE`, `BUILD_SLICE`, step slices | Don't emit / don't use |
| `set.discard` | `DELETE_SUBSCR` on SET is still TYPE; `if x in s` is enough |
| Closures, generators, runtime `class`, `import`, `with`, `except*`, GC | Plan 2 C10. Compiler source must not need them |
| Trap→raise (exceptions T6) | Syntax errors are already Python `raise`. Hardware TYPE stays fatal |
| Console RX / `open` / `input` | Source for v1 is a `LONG_STR` / `SHORT_STR` already on the heap (Plan 2 C8 S1) |
| Growing `RF_DEPTH` for a PEG parser | LL(1) explicit stack (Plan 2 §2.2) |

---

## 4. Sequence (do in this order)

Each step has a done-when that is a test, not a doc.

| Step | Work | Done when |
| --- | --- | --- |
| **0** | Land native methods (PR #86) if not on `main` | `make pycore-img-native-methods-all` |
| **A** | `compat.py` + `test_compiler_subset.py` (banned constructs) | Host test red on `xs[-1]` / `xs[1:]` / `class` / nested close / f-string in `compiler/` |
| **B** | **F1** emit trio + host stand-ins | `img_code_new_call`: emit `RESUME; LOAD_SMALL_INT 7; RETURN_VALUE`, call, get 7 |
| **C** | Tokenizer port under the subset (Plan 1 P9, no list-slice wait) | Host `test_rom_lexer.py` vs CPython `tokenize` on a tiny corpus; one device `img_lexer_count` |
| **D** | Tiny-grammar parser (Plan 2 C1 staging) | `img_parser_tiny_expr` |
| **E** | Tagged-list AST for that grammar | Round-trip vs `ast.parse` on host |
| **F** | Symtable: module + function, **closures → clear SyntaxError** | Host locals-vs-globals corpus |
| **G** | Codegen **T1** + assembler (no CACHE, reserved `EXTENDED_ARG` on forward jumps) | Host differential: ROM compiler vs CPython **results** for T1 snippets |
| **H** | ROM `compile` + `img_compile_eval_expr` | `eval(compile("1+2", "<s>", "eval")) == 3` on device |
| **I** | T2 (`if`/`while`/`for`/`and`/`or`) then T3 (`def`, displays, unpack) | Host corpus; a few device goldens |
| **J** | `exec`/`eval` string dispatch **only if** needed; else keep `eval(compile(...))` | Optional O4 |
| **K** | Size report (`make pycore-size-report`) before adding files | Build fails on ROM / heap / string overflow |

Self-host (Plan 2 C9) and BIOS/loader stay **after** H is green. Compiling the
compiler is a size-and-subset problem, not a reason to start P2/P5 first.

---

## 5. What codegen may emit (v1 allowlist)

Mirror `bytecode_support.md` fully-supported table. Firmware raises on anything
else. T1 is enough for step H:

- literals: `LOAD_CONST`, `LOAD_SMALL_INT`, `LOAD_FAST`, `STORE_FAST`
- names: `LOAD_GLOBAL` / `LOAD_NAME` (globals-then-builtins; no locals mapping)
- arith / compare / `is` / `in`, `UNARY_*`
- `CALL` / `PUSH_NULL`, `LOAD_ATTR` (method_flag as CPython 3.14)
- subscript `NB_SUBSCR`, `STORE_SUBSCR` (no slices in *user* v1 either, or
  only string slices with non-literal bounds)
- `RETURN_VALUE`, `POP_TOP`, `COPY`, `SWAP`, `NOP`/`RESUME`
- jumps already used by `if`/`while` once T2 lands
- `BUILD_LIST` / `BUILD_TUPLE` / `BUILD_MAP` / `BUILD_SET` at T3
- `MAKE_FUNCTION` at T3 (`def` with no closures, no defaults if defaults still
  need image-time fold — prefer empty defaults in v1, or emit `co_defaults`
  through `_bi_code_new` field 4)

Explicitly **do not emit:** `LOAD_BUILD_CLASS`, `IMPORT_*`, `YIELD_*`,
`LOAD_DEREF` / `MAKE_CELL`, `LOAD_SPECIAL` / `SETUP_*`, `FORMAT_WITH_SPEC`,
`STORE_SLICE`, `LOAD_COMMON_CONSTANT`, `MATCH_*`.

User programs that use those get a **compile-time** error from the ROM compiler,
not an illegal-opcode trap.

---

## 6. Tests (minimum set for H)

Host (breadth):

- `test_compiler_subset.py` — compiler source is in the subset
- `test_code_fabrication.py` — stand-ins pack metadata/flags
- T1 differential: ROM `compile` + host `exec` vs CPython `exec` of the same
  source (results, never `co_code`)
- Tokenizer vs `tokenize` on the same corpus Plan 1 §10.3 named

Device:

| Image | Expect |
| --- | --- |
| `img_code_new_call` | 7 |
| `img_code_emit_range_trap` | trap 7 |
| `img_lexer_count` | token count golden |
| `img_parser_tiny_expr` | node-count / checksum |
| `img_compile_eval_expr` | 3 |
| `img_compile_mode_trap` | `SyntaxError` or `ValueError` for `"single"` / bad flags |

Wire `pycore-img-compile-min` into `all-tests` at H, not the full Plan 2
bootstrap.

---

## 7. Plan 1 §14 rows, recast

Plan 1 said none of these may be dropped. For **first `compile()`** they split:

| Plan 1 row | First `compile()` |
| --- | --- |
| Code RAM ≥ 32 768 slots | **Keep** (already there) |
| Module format + relocation | **Defer** (P2) |
| `code_ram_ptr_r` + emit primitives | **F1 — this is the work** |
| Mark/release | **Keep** (already there); compiler must call them |
| LONG_STR content-eq | **Defer**; SHORT_STR / intern (O3) |
| Slicing + list/str methods | **Methods + string slice: keep.** List slice: subset rewrite |
| Exceptions with messages | **Keep** (already there) |
| `exec(code, globals)` | **Keep** (already there) |
| BIOS | **Defer** (P5) |
| Tokenizer | **Firmware now** (step C), not gated on P2/P5/P6.4 |
| `_bi_code_kind` | **Defer** (O4) |

---

## 8. Owner split for this path

| Step | Owner |
| --- | --- |
| A subset gate | firmware compiler + tests |
| B / F1 emit | pycore RTL + tooling |
| C tokenizer | firmware compiler |
| D–G parser…assembler | firmware compiler |
| H `compile` builtin | firmware (replace `compile.py` stub) |
| O1–O5 | only when a step above is blocked by a rewrite that fails the "equal algorithm / too many sites" test |
