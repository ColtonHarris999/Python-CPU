# Plan 3 — native `compile()` on PyCore, integrating PyCPython

**Status:** active — this is the full remaining plan
**Audience:** firmware compiler agent, bytecode agent, pycore RTL agent, tooling agent
**Supersedes:** [`native_compiler_plan.md`](native_compiler_plan.md) (Plan 2) as the working compiler plan. Plan 2 remains useful background; every load-bearing requirement is restated here.
**Does not replace:** [`code_loading_bios_tokenizer_plan.md`](code_loading_bios_tokenizer_plan.md) (Plan 1). Plan 1 is still in progress and is a hard prerequisite. §5 restates the contract.
**Vendor:** [`vendor/pycpython`](../../vendor/pycpython) — git submodule of [ColtonHarris999/PyCPython](https://github.com/ColtonHarris999/PyCPython), branch `claude/cpython-3-14-compile-frontend-4o4fcz`.

The product goal is that a PyCore program can do the moral equivalent of:

```python
res = compile(source, "program.py", "exec")
exec(res)
```

CPython's `compile()` takes **source text** (or AST), not a filesystem path. `compile("program.py")` with one argument compiles the *string* `"program.py"`, which is a bare name. The on-device API matches CPython: three arguments, modes `"exec"` and `"eval"`. A filename convenience that `open()`s a path is a later OS piece (Plan 1 §8.2 S3) and is **not** required to close this plan. Image-resident source strings (S1) are.

This document is the complete remaining work: Plan 1 leftovers that the compiler depends on, every change PyCPython needs before it can become firmware, every PyCore RTL/firmware/tooling change, and the bootstrap that proves host independence.

---

## 1. What PyCPython is

PyCPython is a from-scratch, importable reimplementation of CPython **3.14.7**'s compilation pipeline:

```text
source → tokenizer → PEG parser → AST → AST preprocess →
  symbol table → codegen → CFG optimizer → assembler → code object
```

Public entry points: `pycpython.compile.compile_source()` and `parse_to_ast()`. The package is forbidden from calling `eval` / `exec` / `compile` and from importing stdlib `ast` / `symtable` / `dis` / `opcode`. Code objects are built by serializing a `CodeSpec` with `marshal_writer.py` and reading it back with `marshal.loads`.

Pinned oracle (from `STATUS.md`, measured on 3.14.7):

| Check | Result |
| --- | --- |
| Tier 0 AST (positions included) on `Lib/` + `Lib/test/` | **1869 / 1869** |
| Tokenizer + symbol table parity | 100% on the same files |
| Tier 1 structural code-object equality | **1864 / 1864** compilable files |
| Tier 2 `marshal.dumps` byte-exact | 87.6% as dumped; **100%** after one round trip (deviation D1, single-byte `bytes` `FLAG_REF`) |
| Error-parity corpus | 257 files, same exception type and `args` |

That is a finished **host** compiler. It is not a PyCore-subset compiler. The rest of this plan is how to use it without pretending the hart can run 1 MB of CPython-shaped Python.

Host smoke on this repository (CPython 3.14.7): `compile_source("x = 1 + 2\nprint(x)\n", "t.py", "exec")` emits `LOAD_SMALL_INT 3; STORE_NAME; LOAD_NAME print; …` — CPython-identical, including constant folding. `pycore/tests/test_pycpython_oracle.py` pins that.

---

## 2. Verdict: how it integrates *today*

Three layers. Only H is possible on the current hart. F and D are the rest of the work.

```text
┌─────────────────────────────────────────────────────────────────┐
│ H  Host oracle   vendor/pycpython  (this PR starts here)       │
│    CPython 3.14.7 process. Differential tests, image tooling.   │
└─────────────────────────────┬───────────────────────────────────┘
                              │ algorithms + golden code objects
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ F  Firmware compiler   pycore_firmware/compiler/  (derived)    │
│    PyCore-subset Python. Tagged-list AST. LL(1) parser.       │
│    Emits only SUPPORTED_OPS. Assembles via _bi_code_*.         │
└─────────────────────────────┬───────────────────────────────────┘
                              │ needs Plan 1 leftovers + C6
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ D  Device runtime   RTL + BIOS + ROM compile/exec/eval        │
│    Code RAM writes, CODE_OBJECT fabrication, string exec.     │
└─────────────────────────────────────────────────────────────────┘
```

**Do not execute `vendor/pycpython` on the hart.** A measured audit of the submodule (20 files, compiling every module with CPython 3.14 and checking `validate_code_tree` / `SUPPORTED_OPS`):

| Fact | Number | Why it is fatal on device |
| --- | --- | --- |
| Source size | **1069.8 KB**, 29 548 lines, 20 files | Plan 2 budgeted a few thousand lines. PyPy's compiler was already called out as 315 KB and "far past" imem |
| Generated PEG parser alone | **544.6 KB**, 14 040 lines, **455** rule methods | PEG recursion vs `MAX_CALL_DEPTH_CORE = 128`; one method per grammar rule per token position |
| Walrus `:=` | **1 961** (almost all in `generated_parser.py`) | NamedExpr is fine in 3.14 bytecode, but the *parser source* is unportable as written |
| Classes / inheritance | **174** classes, **135** with bases | Image folding rejects bases, `__slots__`, nested classes, and `@property`. Runtime `LOAD_BUILD_CLASS` is deferred |
| `__slots__` | 18 | Image folding rejects `__slots__` |
| `list.append` calls | **218** | `LOAD_ATTR` on `LIST` still traps; Plan 1 P6.3.2 is open |
| `try` | 63 | Device `try/except` exists for seeded types; `finally` / `with` do not |
| Stdlib imports | `sys`, `marshal`, `struct`, `weakref`, `unicodedata`, `warnings`, `collections`, `os` | No `import`, and several are C-backed |
| Compiling the compiler itself | See [`bytecode_compile_progress.md`](bytecode_compile_progress.md): **92** opcodes; **17 / 20 files fail** `validate_code_tree` | Closures (`MAKE_CELL`, `LOAD_DEREF`, `STORE_DEREF`, `LOAD_LOCALS`), `LOAD_BUILD_CLASS`, `IMPORT_*`, generators, `assert`, `super()`, `with` |
| Dynamic bytecode of those 20 files | **~116 000** logical units; **~309 000** raw `co_code` units including `CACHE` | Code RAM is **32 768 slots**. The unmodified compiler does not fit even before the BIOS and ROM firmware |

Plan 2 §2.2 rejected PEG for frame depth, memo tuple keys, and class/decorator shape. The audit **confirms** that call. PyCPython's parser is a faithful CPython PEG: `PToken.memo` is a dict keyed by `rule_type` (an int — that part is fine), but every `_r_*` method is a Python call, `GeneratedParser(Parser)` is inheritance, and `compile.py` raises the recursion limit to **12 000**. That is the opposite of a 128-frame machine.

**What *is* usable immediately (layer H):**

- Golden `compile()` for host tests, independent of the running interpreter's private compiler internals.
- Algorithm reference for every stage Plan 2 was going to take from PyPy (`tokenizer`, `symtable`, `codegen`, `flowgraph`, `assemble`).
- Exception-table encoder (`assemble.py`) and jump/`EXTENDED_ARG` sizing — the missing half of `pycore/tools/exception_table.py`.
- A finished AST (`pyast.py` from `Python.asdl`) and opcode tables (`opcodes.py` from 3.14.7) to generate device node-kind tables from.

**Keep the submodule pristine.** Ports live in `pycore_firmware/compiler/` with provenance headers. Do not rewrite vendor files into a PyCore dialect; that would destroy the 100% Tier 0/1 oracle.

---

## 3. Target API and data flow on device

```python
def compile(source, filename, mode, flags=0, dont_inherit=False, optimize=-1):
    if flags != 0:
        raise ValueError
    if mode == "single":
        raise ValueError
    toks = tokenize(source)          # Plan 1 P9, device DFA
    tree = parse(toks, mode)          # F: LL(1) driver
    ast = build_ast(tree, mode)
    sym = build_symtable(ast)
    instrs = codegen(ast, sym, mode) # SUPPORTED_OPS only
    return assemble(instrs)         # _bi_code_alloc / _bi_code_emit / _bi_code_new

def exec(source, globals=None):
    if _bi_code_kind(source) == KIND_CODE:
        code = source
    else:
        code = compile(source, "<string>", "exec")
    if globals is None:
        code()
    else:
        _bi_exec_globals(code, globals)
    return None
```

`eval` is the same dispatch with `mode="eval"` and returning the callee's value. `filename` is accepted and ignored until tracebacks exist. `"single"` stays rejected.

`exec(code_object)` and `eval(code_object)` / `exec(code, globals)` **already work** (Plan 1 P3/P4, in ROM). String forms wait on this plan's `compile`.

```text
source (LONG_STR in image or heap)
   │
   ▼  P9 tokenizer (device DFA, string tables)
tokens  [kind INT, value, pos] list
   │
   ▼  C1 LL(1) parser  (NOT vendor generated_parser.py)
parse tree  tagged lists
   │
   ▼  C2 astbuilder
AST  [KIND, lineno, col, fields…]
   │
   ▼  C3 symtable
scopes  name → {local, global}  (closures: clean error)
   │
   ▼  C4 codegen   allowlisted opcodes, no CACHE
pseudo-instructions + blocks
   │
   ▼  C5 assembler  jumps, stacksize, exception table
   │
   ▼  C6  _bi_code_alloc / _bi_code_emit / _bi_code_new
CODE_OBJECT  (8 heap fields, bytecode in code RAM)
   │
   ▼  existing exec(code) / eval(code)
```

Host development runs the same Python through `load_rom_firmware_callables()` with `_bi_code_*` stand-ins that assemble a CPython `types.CodeType`. Layer H's `compile_source()` is the **semantic** oracle for "what CPython would have compiled"; the firmware compiler is allowed to differ in `co_code` (no `CACHE`, documented opcode subset) and is checked by **program results**, never byte-identical `co_code`.

---

## 4. PyCPython file-by-file disposition

Every file under `vendor/pycpython/pycpython/` (sizes from the audit):

| File | Size | On-device? | Disposition |
| --- | --- | --- | --- |
| `parser/generated_parser.py` | 545 KB | **No** | Host oracle only. Device parser is a new LL(1) driver + generated DFA tables (C1). Keep `tools/gen_parser.py` unused on device |
| `codegen.py` | 153 KB | **Reference** | Re-implement T1–T3 against `SUPPORTED_OPS`. Do not port pattern matching, async, generators, `class`, `import`, `with`, `finally` until §12 runtime exists |
| `tokenizer.py` | 77 KB | **No as-is** | Byte-buffer C tokenizer: classes, `collections.namedtuple`, generators (`generate_tokens`), `bytes.decode`, `warnings`. Device tokenizer remains Plan 1 P9 (PyPy DFA). Use this file as the **token-stream oracle** on the host |
| `flowgraph.py` | 67 KB | **Selective** | Jump/`EXTENDED_ARG` and stack-depth ideas; skip optimizations that assume CPython cache layout |
| `parser/pegen.py` | 56 KB | **No** | PEG runtime, inheritance, `unicodedata`, `os`, `sys`. Host only |
| `symtable.py` | 49 KB | **Reference** | Port module + function scopes; drop PEP 695 / annotation / type-param / async / comprehension-cell complexity until needed. Closures: compute them so we can **error**, do not emit `MAKE_CELL` |
| `opcodes.py` | 28 KB | **Host generate** | Input to a firmware allowlist that must match `SUPPORTED_OPS` |
| `pyast.py` | 24 KB | **Host generate** | 126 `LOAD_BUILD_CLASS` sites. Device AST is tagged lists from `Parser/Python.asdl` via `gen_ast_tables.py` |
| `ast_preprocess.py` | 17 KB | **Later / subset** | Constant folding is how `1+2` became `LOAD_SMALL_INT 3`. Useful, not v1-blocking — codegen can emit the ops and let hardware run them |
| `assemble.py` | 16 KB | **Closest port** | Exception-table 6-bit varints, jump sizing, `co_stacksize`. Replace `build_code`/`marshal.loads` with `_bi_code_new` |
| `marshal_writer.py` | 16 KB | **Host only** | `marshal` / `struct` / `weakref` / `sys.intern`. Device has no marshal and an 8-field code object |
| `parser/string_parser.py` | 13 KB | **Selective** | String-escape / f-string decode. `unicodedata`, inheritance. Needed once f-strings are in the grammar subset |
| `unparse.py` | 13 KB | **No** | Error-message pretty printer; 15 `LOAD_DEREF`. Replace with simpler messages or a non-closure writer |
| `tokens.py` | 5.5 KB | **Yes, flatten** | Token kind ints. Device tokenizer uses the same small-int kinds |
| `errors.py` | 3.9 KB | **Subset** | `SyntaxError` construction; drop `warnings.warn_explicit` until warnings exist |
| `parser/__init__.py` | 3.6 KB | **Replace** | Bytes vs str, `sys.setrecursionlimit`. Device parse entry is `parse(toks, mode)` over the token list |
| `future.py` | 2.6 KB | **Tiny subset** | `__future__` in v1: reject or accept annotations-as-strings only if the grammar has it |
| `compile.py` | 2.6 KB | **Rewrite** | Becomes the ROM `compile` body in `pycore_firmware/builtins/compile.py` |
| `instrseq.py` | 2.6 KB | **Yes, tagged lists** | Instruction + sequence without classes |
| `__init__.py` | 78 B | n/a | |

`tools/` (pegen generator, `gen_ast.py`, `gen_opcodes.py`) stay **host-only**, next to `pycore/tools/`.

---

## 5. Changes required on PyCore (runtime, so the compiler can exist)

Plan 1 §14 is still the contract. Status as of this writing, then what Plan 3 additionally needs.

### 5.1 Plan 1 leftovers (do these before or in parallel with F)

| Deliverable | Plan 1 | Status | Why the compiler dies without it |
| --- | --- | --- | --- |
| Code RAM ≥ 32 768 slots | P1 | **Done** | Compiler + output live here |
| Module format + `_bi_load_module` + relocation | P2 | **Open** | Compiler ships as loadable modules; overlays if it will not fit in ROM |
| `code_ram_ptr_r` | P1/P8 | **Done** (marks only) | C6 emit writes through it |
| Mark/release heap + code RAM | P8 | **Done** | Every `compile()` leaks without release |
| Content-based `LONG_STR` equality + hash | P6.4 | **Open** (deviation 4 still live) | Identifiers > 15 bytes as `co_names` / symtable keys |
| `BINARY_SLICE` strings | P6.1 | **Done** | Tokenizer / parser slices |
| `BINARY_SLICE` list/tuple | P6.3.1 | **Open** | Parser stacks, instruction lists |
| Negative indices | P6 / R5 | **Open** (deviation 3) | 21 negative subscripts/slices in vendor; the **port** must audit, or hardware must grow |
| `list.append` / `pop` / `extend`; `str.join` / `startswith` / `endswith` / `find` | P6.3.2 | **Open** | 218 `append`, 32 `pop`, 9 `join` in vendor; firmware port will still want methods |
| `SHORT_STR` ordering | P6.3.3 | **Done** | |
| `LONG_STR` ordering | P6.3.3 | **Open** | Sort/min on long names |
| `SyntaxError` with message | P7 | Construction **done**; `e.args` via `LOAD_ATTR` is F4 | Parser reporting |
| `exec(code)` / `eval(code)` / `exec(code, globals)` | P3/P4 | **Done, in ROM** | Running compiled output |
| `_bi_code_kind` | P3 | **Open** | String vs code dispatch in `exec`/`eval` |
| BIOS | P5 | **Open** | Owns marks; later `compile`+`exec` of a payload |
| Tokenizer | P9 | **Open** | Stage 1 of the pipeline |

Plan 3 does **not** wait for BIOS or the loader to start host-side C1–C5. It **does** wait for P6 methods + interning + list slice before a device tokenizer/parser is honest, and for C6 before anything compiled on device can run.

### 5.2 C6 — code-object fabrication (RTL + tooling) — start in parallel

Nothing can write code RAM at runtime today (`code_loading.md` §2). Three on-core builtins (excore cannot reach code memory):

| Builtin | Behaviour |
| --- | --- |
| `_bi_code_alloc(nslots) -> INT` | Reserve `nslots` from `code_ram_ptr_r`; OOM → `PY_TRAP_MEM_FAULT` |
| `_bi_code_emit(slot, opcode, oparg)` | Write `{arg[39:8], opcode[7:0]}`. Slot must be inside a reservation. Absolute addressing so jump patching is a re-emit |
| `_bi_code_new(fields) -> CODE_OBJECT` | 9-element list → 8-field 256-byte object. Metadata low 64 bits in `fields[3]`; flags (`varargs`, `varkw`, `posonlyargcount`) in `fields[8]` because `posonlyargcount` sits at bits `[81:66]` of the hardware word |

Field/tag contract (unchanged from Plan 2 §7):

| i | Field | Tag |
| --- | --- | --- |
| 0 | `entry_slot` | `INT` |
| 1 | `co_consts` | `TUPLE` |
| 2 | `co_names` | `TUPLE` of strings |
| 3 | `metadata` | `INT` (`argcount \| nlocals<<16 \| stacksize<<32 \| kwonly<<48`) |
| 4 | `co_defaults` | `TUPLE` |
| 5 | `co_varnames` | `TUPLE` |
| 6 | `co_kwdefaults` | `MUT_DICT` |
| 7 | `co_exceptiontable` | `TUPLE` of `INT` bytes (`()` if none) |
| 8 | `flags` | `INT` |

Wrong length/tag/OOM traps. Self-modification of a live PC is undefined.

**Host stand-ins** in `image_from_source.py` (beside `_host_bi_print`): accumulate words and `CodeType.replace`. This is how C1–C5 are developed under CPython.

`pycore/tools/exception_table.py` already **parses** CPython 6-bit varints. Add the **encoder** (PyCPython `assemble.py` is the reference) and property-test `encode(decode(x)) == x`.

### 5.3 Runtime features the PyCPython *algorithms* need, beyond Plan 1

These are not required to *parse* a tiny grammar on the host. They become required as soon as the firmware compiler's own source uses them.

| Feature | Evidence in vendor | Device status | Plan 3 choice |
| --- | --- | --- | --- |
| Relative `import` | 224 `IMPORT_*` | Deferred | **Flatten** firmware into explicit packages or a single module graph the image builder seeds. Do not implement `import` for v1 |
| Inheritance / `class` at runtime | 135 bases, 174 `LOAD_BUILD_CLASS` | Module-level fold only; **no bases** | Device AST/parser/codegen use **tagged lists and functions**, not classes. Host keeps classes |
| Closures | 26 `LOAD_DEREF`, 8 `MAKE_CELL` | Deferred | **Forbid** in firmware compiler source. Nested functions: 3 sites — rewrite |
| Generators | `YIELD_VALUE` 13 | Deferred | Public `generate_tokens` is host-only; device tokenizer returns a list |
| `with` | 1 | Deferred (T9) | Rewrite the one site |
| `@property` / `@staticmethod` / `@classmethod` | 3 / 13 / 4 | staticmethod fold only | No properties on device objects; flatten to functions |
| `bytes` / `encode` / `decode` | tokenizer is UTF-8 **bytes** | `BYTES` tag reserved / partial | Device tokenizer operates on **str** with `ord`/`chr` (Plan 1 P0). Do not port the byte tokenizer |
| `unicodedata` | identifier / string checks | No | ASCII-plus-explicit tables, or a tiny generated bitmap |
| `sys.setrecursionlimit(12000)` | `compile.py`, parser | No | LL(1) explicit stack; never need it |
| `marshal.loads` | `build_code` | No | `_bi_code_new` |
| `isinstance` | 244 calls | **in ROM** | Allowed in firmware once the compiler is a `CODE_OBJECT` that can `CALL` it. For v1 tagged-list AST, prefer `node[0] == KIND_*` |
| Walrus | 1961 | Opcode is fine | Allowed in *user programs* when codegen T2 exists. **Forbidden** as a reason to ship `generated_parser.py` |
| `assert` / `LOAD_COMMON_CONSTANT` | 204 | T7 open | Firmware compiler uses `if not x: raise …`, never `assert` |
| Default arguments (`SET_FUNCTION_ATTRIBUTE`) | 24 | Folded at **image-build** only | Either fold defaults when seeding the compiler image, or rewrite firmware defs to have no defaults. Runtime defaults for *user* `def f(x=1)` are T3 |

### 5.4 Memory budget (restated with measured numbers)

| Resource | Limit | Compiler pressure |
| --- | --- | --- |
| Code ROM | 8 192 slots / 64 KB | BIOS + ROM builtins. Compiler does **not** live here |
| Code RAM | 32 768 slots / 256 KB | Firmware compiler + emitted code. Unmodified PyCPython is **~116k logical units / ~309k raw imem units including CACHE** → **does not fit** ([`bytecode_compile_progress.md`](bytecode_compile_progress.md)). Target a subset compiler of **≤ ~12 000 slots**, leaving room for output and a payload |
| Heap | ~106 KB (`0x0440`–`0x1B000`) | AST node ≈ 192 B; token ≈ 128 B. Compile per statement; mark/release; "source too large" error, not OOM trap |
| Static strings | 16 KB (`STRING_RUNTIME_BASE = 16384`) | DFA + grammar tables as strings (`ord(s[i])`). Overflow → fail the **host** image build. P2 data section can hold tables if needed |
| Frames | `MAX_CALL_DEPTH_CORE = 128`, `RF_DEPTH = 256` | LL(1) explicit stack. PEG is banned for this reason, not taste |
| `INT` | signed i64 | Compiler counters and line numbers fit; arbitrary-precision is out |

`make pycore-size-report` (Plan 2 §9.4) is still a merge-gate deliverable: per ROM/loaded module, slots / heap / static strings vs the three ceilings, **fail the build** on overflow.

### 5.5 Tooling and CI (start now)

| Change | Why |
| --- | --- |
| `git submodule` `vendor/pycpython` | Done this PR |
| `.github/workflows/all-tests.yml` `submodules: true` | `actions/checkout@v4` otherwise leaves an empty directory; Docker bind-mounts the workspace |
| `pycore/tools/pycpython_vendor.py` | Single path helper so tests and later oracles agree |
| `pycore/tests/test_pycpython_oracle.py` | Tier-1 smoke: `compile_source` vs `compile` on a T1 snippet |
| `pycore/tools/measure_pycpython_opcodes.py` | Regenerates [`bytecode_compile_progress.md`](bytecode_compile_progress.md): opcode mix vs `pycore.json` |
| `pycore/tests/test_measure_pycpython_opcodes.py` | Pins full / partial / unsupported classification of that mix |
| Optional later: `image_from_source.py --compiler pycpython` | Build images with the vendor compiler instead of builtin `compile()`; must remain 3.14.7-equivalent for supported ops |
| `load_rom_firmware_callables()` stand-ins for `_bi_code_*` | C1–C5 host development |
| `validate_code_tree` on every `pycore_firmware/compiler/*.py` | Firmware cannot emit deferred opcodes |
| Negative-index grep test on firmware compiler sources | Deviation 3 |
| `THIRD_PARTY.md` | Done this PR; update on every port |

### 5.6 Documentation (same commit as the code, Plan 1 §4.1)

| Document | When |
| --- | --- |
| **`pycore/docs/compiler.md`** (new) | Pipeline, tagged-list AST, grammar/table flow, codegen tiers, assembler rules, size budget, every deviation from CPython's compiler |
| `pycore/docs/code_loading.md` | C6 writers (`_bi_code_emit`) |
| `pycore/docs/object_model.md` | New `BI_*` ids |
| `pycore/docs/bytecode_support.md` | Numbered deviations for "no CACHE", `LOAD_GLOBAL` low bit, etc. |
| `pycore_firmware/builtins/compile.md` / `exec.md` / `eval.md` | From blockers to shipped notes |
| `pycore_firmware/README.md` | `compiler/` tree |
| `planning/README.md` | This file is the active compiler plan |
| `planning/bytecode_compile_progress.md` | Measured opcode mix of vendor PyCPython vs PyCore; regenerate with `measure_pycpython_opcodes.py` |
| `vendor/README.md` | Submodule map |

---

## 6. Changes required to compiler code (the derived firmware port)

This is the F-layer. It is a **port of algorithms**, not a copy of files.

### 6.1 Standing constraints on `pycore_firmware/compiler/`

1. Must pass `validate_code_tree` (no deferred/unsupported opcodes).
2. No inheritance, no `__slots__`, no `@property`, no `@classmethod`, no nested `class`.
3. No `import` of anything that is not already seeded as a ROM/global (prefer one package flattened by the image builder).
4. No `yield`, no `async`, no `with`, no `assert`, no closures, no `super()`.
5. No negative indices/slices; host grep test fails the build.
6. Tables that would be `tuple`s of `int`s are **strings** read with `ord(s[i])`, every byte `< 0x80`, asserted by the generator.
7. A host test compiles **every** firmware compiler module **with the ROM compiler itself** (via stand-ins) from C1 onward, so bootstrap S2 cannot fail late (Plan 2 R4).

### 6.2 C1 — parser (LL(1), not PEG)

`pycore/tools/gen_grammar_tables.py` reads `pycore_firmware/compiler/python.gram` and emits `grammar_tables.py`. Algorithm: `parso` pgen2 or a reimplementation (MIT; record in `THIRD_PARTY.md`). Not CPython `pegen`.

`parser.py`: push-down automaton, explicit stack of `[dfa, state, node]`, from PyPy `parser.py` **structure**, consuming Plan 1 tokens.

Staging: tiny expression grammar first; full subset grammar only after the driver is trusted.

Host tests: tiny-grammar accept/reject; corpus parse-tree shape vs PyCPython `parse_to_ast()` (normalize positions). Deep parentheses must not grow frames. Every syntax error has line and column.

Device: `img_parser_tiny_expr`, `img_parser_stmt_count`, `img_parser_deep_nesting`, `img_parser_syntax_error_trap`.

**Fallback** if LL(1) cannot express a needed construct: precedence-climbing recursive descent (depth ≈ 10), same AST. Track leftovers in §12.

### 6.3 C2 — AST as tagged lists

```text
node = [NODE_KIND, lineno, col, field0, field1, ...]
```

`pycore/tools/gen_ast_tables.py` reads CPython `Parser/Python.asdl` (PyCPython `pyast.py` / `tools/gen_ast.py` confirm field order) and emits `ast_kinds.py`.

`astbuilder.py`: parse tree → tagged lists. PyCPython / PyPy astbuilder as reference; constructors become list literals.

Heap: free tokens before AST, AST before codegen, using P8 marks. Compile per top-level statement when a module would exceed the heap. Clean "source too large".

### 6.4 C3 — symbol table

Module + function scope; `global` / `nonlocal`. Closures: **raise** `"closures unsupported"` rather than emit `LOAD_NAME` for an outer local.

Long identifiers require P6.4 content equality.

### 6.5 C4 — codegen, PyCore-canonical bytecode

Firmware allowlist ≡ `SUPPORTED_OPS`. Host test that they cannot drift.

Documented deviations from CPython's compiler (also `bytecode_support.md` + `compiler.md`):

1. **No `CACHE` padding.** Fetch skips `CACHE`; emitting none keeps jump deltas consistent. Differential tests compare **results**, not `co_code`.
2. **`LOAD_GLOBAL`:** `namei = oparg >> 1`, bit 0 = NULL push.
3. **`COMPARE_OP`:** CPython 3.14 packed oparg (selector in bits 7:5).
4. Do not emit a construct the runtime cannot execute (tier table).

| Tier | Constructs | Runtime gate |
| --- | --- | --- |
| T1 | Literals, names, arithmetic/bitwise/unary, comparisons, `is`, `in`, calls, subscript, attribute, expression statements, assignment | Current core |
| T2 | `if`/`elif`/`else`, `while`, `for`, `break`, `continue`, `pass`, chained comparisons, `and`/`or`, augmented assignment | Current core |
| T3 | `def` (positional / default / kw-only / `*args` / `**kwargs`), `return`, unpacking, list/tuple/dict/set displays | C6 flags path for varargs/varkw/posonly; defaults stored on the code object |
| T4 | `try`/`except`/`finally`, `raise`, `with`, comprehensions | `finally`/`with` need exception-plan T9+; list comps already run |
| T5 | `class`, decorators, `import`, `lambda` | Runtime `LOAD_BUILD_CLASS`, imports, cheap lambda |

v1 ships T1–T3. T4/T5 wait on §12.

PyCPython `codegen.py` + `flowgraph.py` are the **spec** for "what CPython would emit" when we need to debug a mismatch. They are not the firmware body.

### 6.6 C5 — assembler

1. Order blocks; labels → code-unit offsets.
2. Forward jumps reserved as `EXTENDED_ARG 0` + `JUMP_*` so patching never resizes.
3. CFG walk for `co_stacksize` (hardware does not yet check it; still compute it).
4. Exception table → field 7, CPython 6-bit varints (encoder from PyCPython `assemble.py`).
5. Pack metadata + flags for `_bi_code_new`.

### 6.7 C7 — ROM `compile` / string `exec` / `eval`

Seed `compile` in `ROM_FIRMWARE_BUILTINS`. Extend `load_rom_firmware_callables()` so host goldens run the ROM body with stand-ins. Move `compile` to **in ROM** in `builtins.md`. Rewrite `compile.md` / `eval.md` / `exec.md` from blocker notes into shipped subset docs.

`_bi_code_kind` (Plan 1 §8.1) is required for string/code dispatch.

### 6.8 C8 — source on device

| Route | Mechanism | v1? |
| --- | --- | --- |
| S1 image-resident `LONG_STR` | Constant in the boot image or a loaded module | **Required** |
| S2 `input()` / console RX | MMIO RX sibling of `CONSOLE_TX` | Later |
| S3 `open()` / block device | Filesystem | Later |

S1 competes with DFA/grammar tables for the 16 KB static string region — P2's data section is the overflow path.

---

## 7. C9 — self-hosting bootstrap

Host independence is a fixpoint, not a demo.

| Stage | What runs | Proves |
| --- | --- | --- |
| S0 | Host builds the firmware compiler image (today's flow, possibly using PyCPython as `compile()`) | Baseline |
| S1 | On-device compiler compiles a test program; the result runs | Pipeline on hardware |
| S2 | On-device compiler compiles **its own source** (S1 blobs) into a module; P2 loads it | Compiler ⊂ supported subset |
| S3 | Stage-2 compiler compiles the same test program; results match S1 | Semantic self-consistency |
| S4 | Stage-2 **emitted code** is byte-identical to stage-1 for the same input | Deterministic codegen |

S2 is the tightest memory moment: source + working set + output. Marks + compile module-by-module.

The host test that the firmware compiler compiles itself starts at C1, not at S2.

---

## 8. Testing (edge cases enumerated, Plan 1 §4.2)

Every phase: host unit tests, device differential, device trap (exact trap code), aggregate target in `all-tests`.

**Layer H (this PR and follow-ons):**

- `test_pycpython_oracle.py`: T1 snippet, structural equality vs `compile()` (bytecode, names, consts, flags, stacksize).
- Later: run PyCPython's own `tests/check_codegen.py` against 3.14.7 when a CPython source tree is present (optional CI job, not `all-tests`).
- Image builds remain on builtin `compile()` until an explicit `--compiler pycpython` path is proven not to change goldens for `SUPPORTED_OPS`.

**Firmware compiler:** Plan 2 §4–§8 matrices, restated:

- Parser: empty, single expr, deep parens, every grammar statement, `a-b-c` / `a**b**c`, trailing commas, every syntax-error position.
- AST: round-trip each `KIND_*`; shape vs `parse_to_ast` on the corpus; node-size accounting.
- Symtable: param local; assign local; read-only → global; `global x`; closure → trap; duplicate param; param+global.
- Codegen T1–T3: ROM compiler on host stand-ins, `exec` under CPython, compare **results** to CPython `exec`.
- Assembler: forward/back/zero jumps; 255/256 `EXTENDED_ARG` boundary; exception-table round-trip; 0/1/255/256 locals.
- Fabrication: `img_code_new_call` (`RESUME; LOAD_SMALL_INT 7; RETURN_VALUE` → 7); args; varargs flags; range/tag/OOM traps.
- Builtins: `img_compile_exec_roundtrip`, `img_compile_eval_expr`, `img_exec_str_direct`, `img_eval_str_direct`, `img_compile_exec_nested`, mode/flags traps, `img_compile_repeat_release` (mark leak).
- Bootstrap: `img_bootstrap_compile_self`, `img_bootstrap_stage2_compiles`, host S4 identity.

Aggregate `pycore-img-compile-all` in `all-tests`.

---

## 9. Language and runtime completeness (C10)

Compiling a construct PyCore cannot execute is worthless. Pairing (from Plan 2 §11, still correct):

| Feature | Runtime | Notes |
| --- | --- | --- |
| Closures | `MAKE_CELL`, `LOAD_DEREF`, `STORE_DEREF`, `LOAD_CLOSURE`, cells | Symtable already knows; firmware currently errors |
| Generators | `YIELD_VALUE`, `SEND`, `RETURN_GENERATOR`, suspend | Frames are push/pop today |
| Runtime `class` | `LOAD_BUILD_CLASS`, frame-local namespaces | Today: image-time fold, no bases |
| `import` | Module objects, registry, store (S3) | Flattening is the v1 substitute |
| `try`/`finally`/`with` | Broader tables, `LOAD_SPECIAL` / `WITH_EXCEPT_START` | `try/except` + `RERAISE` exist; T9+ open |
| Comprehensions | Mostly run; codegen + `MAP_ADD`/`SET_ADD` | Policy B |
| f-strings | `FORMAT_VALUE` / `FORMAT_WITH_SPEC` / `BUILD_STRING` | Partial `FORMAT_SIMPLE` / `BUILD_STRING` already |
| Decorators / `lambda` | Calls + `MAKE_FUNCTION` | Cheap after T5 |
| `async`/`await` | Far future | |
| Negative indices / step slices | Index normalisation, `BUILD_SLICE` | Removes port friction |
| Full LEGB / `locals()` | Frame-local mapping | Also `exec(code, g, l)` |
| GC | Tracing collector | Marks are a stopgap |
| `int` beyond i64 | Long ints | Documented ceiling |

Sequence: **closures → `finally` → runtime `class` → f-strings → generators → imports**.

---

## 10. Definition of done

Plan 1 contract rows in §5.1 that this plan depends on are complete **or** explicitly re-scoped here first.

- [ ] `vendor/pycpython` submodule pinned; CI checks out submodules; host oracle tests green
- [ ] Parser driver + generated tables parse the documented grammar subset on device
- [ ] AST is tagged lists; node tables generated from `Python.asdl`
- [ ] Symbol table resolves locals/globals; closures raise clearly
- [ ] Codegen T1–T3, allowlisted opcodes only
- [ ] Assembler: jumps including `EXTENDED_ARG`, stack depth, exception tables
- [ ] `_bi_code_alloc` / `_bi_code_emit` / `_bi_code_new` + host stand-ins
- [ ] `compile()`, `exec(str)`, `eval(str)` in ROM; differential tests
- [ ] S1 source blobs on device
- [ ] Bootstrap S1–S4, including byte-identical stage-2 output
- [ ] `pycore/docs/compiler.md` current; deviations numbered and pinned
- [ ] `make pycore-size-report` within budget; overflow fails the build
- [ ] Edge matrices in §8 covered; `make all-tests` green

---

## 11. Risks

| # | Risk | Mitigation |
| --- | --- | --- |
| R1 | Heap exhaustion (AST ~192 B, no GC) | Narrow nodes; marks; per-statement compile; "too large"; consider growing `DMEM_BLOCK_COUNT` |
| R2 | Firmware compiler exceeds 32 768 slots | Size report hard-fail; overlay via P2; keep vendor PEG **off** device |
| R3 | Python is not LL(1) | Documented subset; factor grammar; RD fallback; leftovers in §9 |
| R4 | Firmware source drifts out of subset | Host "compile the compiler" from C1 |
| R5 | Frame depth | LL(1) explicit stack; iterative walks; deep-nesting device tests |
| R6 | 16 KB static strings | Tables in module data section; size report |
| R7 | Jump / `EXTENDED_ARG` / exception tables | Reserve `EXTENDED_ARG`; property tests; PyCPython assembler as host oracle |
| R8 | Silent miscompilation | Result differentials vs CPython **and** vs PyCPython; S4 fixpoint |
| R9 | Simulation time | Tiny device sources; breadth on host; bootstrap nightly if needed |
| R10 | Licence | PSF-2.0 on the submodule; firmware ports keep headers; `THIRD_PARTY.md` |
| R11 | Temptation to "just load PyCPython" | §2 numbers; CI rejects `vendor/pycpython` in `ROM_FIRMWARE_BUILTINS` |
| R12 | Negative indices in any port | Grep test; prefer implementing negatives over perpetual audits |
| R13 | Plan 1 P2/P6/P9 slip | Host C1–C5 do not block on them; **device** C7/C9 do. Do not fake a device `compile` on ROM-only images |

---

## 12. Sequencing and owner split

```text
H0 submodule + host oracle          (this PR)
P6 methods + LONG_STR eq + list slice
P9 tokenizer
C6 fabrication  ─────────────────────┐  (parallel with C1–C5 on host)
C1 tiny grammar → C2 → C3 → C4 T1   │
C5 assembler ←───────────────────────┘
C4 T2 → T3
P2 loader (if compiler is not ROM-resident)
C7 compile/exec(str)/eval(str)
C8 S1 source blobs
C9 bootstrap
C10 closures first
```

| Track | Owner | First deliverable |
| --- | --- | --- |
| H0 oracle | tooling | `test_pycpython_oracle.py` green (this PR) |
| P6 / P9 | bytecode + firmware | `img_lexer_count` (Plan 1) |
| C1 parser | firmware + tooling | Tiny-grammar host driver |
| C2 AST | firmware + tooling | `gen_ast_tables.py` + round-trip |
| C3 symtable | firmware | Locals vs globals on host corpus |
| C4 codegen | firmware | T1 differential vs CPython **and** PyCPython results |
| C5 assembler | firmware | Jump / exception-table properties |
| C6 fabrication | RTL + tooling | `img_code_new_call` |
| C7 builtins | firmware | `img_compile_exec_roundtrip` |
| C8 source | RTL + firmware | `img_source_blob_compile` |
| C9 bootstrap | all | `make pycore-bootstrap` |
| C10 | bytecode + RTL | Closures |

---

## 13. What this restates on purpose

From Plan 1: code RAM geometry, module loader, marks, interning, methods, BIOS, tokenizer-as-strings, `_bi_code_kind`, documentation/test discipline, the §14 contract.

From Plan 2: LL(1) not PEG, tagged-list AST, codegen tiers, assembler, `_bi_code_*`, `compile`/`exec(str)`/`eval(str)`, S1 source, bootstrap S0–S4, size report, C10 backlog, risks R1–R10.

New in Plan 3: the PyCPython audit, the three-layer split, the file-by-file disposition, the ban on shipping `generated_parser.py`, PSF-2.0 provenance, CI submodule checkout, and the concrete opcode/construct counts that justify those decisions.

---

## 14. This PR's concrete delta

1. Add `vendor/pycpython` as a submodule on branch `claude/cpython-3-14-compile-frontend-4o4fcz`.
2. Record provenance (`vendor/README.md`, `pycore_firmware/THIRD_PARTY.md`).
3. Checkout submodules in CI.
4. Host oracle smoke test.
5. Point `planning/README.md`, Plan 2, and `compile.md` at this document.

No RTL and no firmware compiler yet — those are C1–C9 above.
