# Compile plan

On-device `compile()`, using **PyCPython** as the host oracle and
algorithm source. This is the only remaining compile plan.

**Abandoned:** PyPy / open-source tokenizer ports, “wait for all of Plan 1
before compile,” and running unmodified `vendor/pycpython` on the hart.

**Audience:** firmware compiler, pycore RTL, image tooling.

## Goal

```python
eval(compile("1 + 2", "<s>", "eval")) == 3
```

API matches CPython: `compile(source, filename, mode)` with `flags==0`.
Modes `"exec"` and `"eval"`. `"single"` and nonzero flags → `ValueError`.
Filename is stored, not opened. String-form `exec`/`eval`, BIOS, module
loader, and self-host come **after** this is green.

## Three layers

```text
H  Host oracle     vendor/pycpython                 CPython 3.14 host only
F  Firmware port   pycore_firmware/compiler/        PyCore-subset, derived
D  Device runtime  RTL `_bi_code_*` + ROM compile   writes code RAM
```

| Layer | What it is |
| --- | --- |
| **H** | Git submodule [`vendor/pycpython`](../vendor/pycpython) ([PyCPython](https://github.com/ColtonHarris999/PyCPython), branch `claude/cpython-3-14-compile-frontend-4o4fcz`). `compile_source()` is the semantic oracle. Never seeded into ROM. |
| **F** | New tree `pycore_firmware/compiler/`. Algorithms taken from PyCPython (`codegen.py`, `symtable.py`, `assemble.py`, tokenizer ideas) and **rewritten** against today’s ISA. Provenance headers + [`THIRD_PARTY.md`](../pycore_firmware/THIRD_PARTY.md). |
| **D** | `_bi_code_alloc` / `_bi_code_emit` / `_bi_code_new`. Existing `exec`/`eval` on code objects already work. |

**Do not execute `vendor/pycpython` on the hart.** Measured mix of compiling
its own 20 files (CPython 3.14.7):

| Bucket | Opcodes | Logical units | Share |
| --- | ---: | ---: | ---: |
| Fully supported | 61 | 103707 | 89.3% |
| Partially supported | 9 | 11605 | 10.0% |
| Not supported | 22 | 847 | 0.7% |

Vendor source is ~1.07 MB / 29.5k lines; the generated PEG parser alone is
~545 KB with 455 rule methods. Logical imem units ~116k vs 32768 code-RAM
slots (~3.5×); raw units including `CACHE` ~9.4×. Highest-count unsupported
ops: `LOAD_COMMON_CONSTANT` (`assert`), `LOAD_BUILD_CLASS` / `LOAD_LOCALS`,
`IMPORT_*`, cells / generators. Recompute with
`python3.14 pycore/tools/measure_pycpython_opcodes.py` (writes
[`old/bytecode_compile_progress.md`](old/bytecode_compile_progress.md)).

Host smoke: `pycore/tests/test_pycpython_oracle.py` (needs
`git submodule update --init`).

## Policy: rewrite first

Prefer a compiler written against **today’s ISA** over new hardware, as
long as the rewrite is the same algorithm (index loop vs slice,
`xs[len(xs)-1]` vs `xs[-1]`). Add pycore only when (a) there is no honest
rewrite, or (b) the rewrite is the `lst.append` → `lst += [x]` bug-farm.

Native methods and `e.args` on main are the model for (b).

### Banned in `pycore_firmware/compiler/`

Host gate `test_compiler_subset.py` must reject these.

| Banned | Rewrite |
| --- | --- |
| list/tuple `xs[a:b]` | `copy_range` + `append` |
| `xs[-1]`, `s[:-1]` | `len-1` / `s[0:len(s)-1]` |
| slice assignment | rebuild / store loop |
| `str.split` / `strip` / `replace` | `find` + string slices (strings **are** sliced) |
| `getattr` / `hasattr` | constant `LOAD_ATTR` / dict probe |
| `type(x) is str` | tagged token tuples |
| tuple dict keys / PEG memo | nested dict or packed SHORT_STR key |
| classes / inheritance | tagged lists + functions |
| nested fn closing over outer locals | explicit `env` dict |
| `import` | one image-resident package |
| f-strings | concat / `join` |
| comprehensions in compiler source | `for` + `append` |
| `with`, `assert`, `match`, `async` | `try/except` + explicit cleanup |
| decorators / `lambda` | `def` |
| names > 15 bytes as dict keys (v1) | SHORT_STR names; intern later |

PEG is banned (`MAX_CALL_DEPTH_CORE = 128`; vendor raises recursion limit
to 12 000). Device parser is **LL(1)** + generated tables, not
`generated_parser.py` / `pegen.py`.

## Pipeline on device

```text
source ─► tokenize ─► LL(1) parse ─► tagged-list AST ─► symtable
       ─► codegen (SUPPORTED_OPS, no CACHE) ─► assemble
       ─► _bi_code_alloc / emit / new ─► existing exec/eval
```

Tokenizer: **PyCPython-derived**, under the subset above. Not a PyPy DFA
port. Vendor remains a host token-stream oracle if useful.

AST node = tagged list `[KIND, lineno, col, …]`. Free token list / parse
tree with mark/release before the next stage. Compile per top-level
statement when a whole-module AST would blow the 109 KB heap.

Symtable: module + function; closures → clear `SyntaxError`, do not
miscompile to a global read.

Codegen tiers:

| Tier | Grammar | When |
| --- | --- | --- |
| T1 | literals, names, arith, `return` | first `eval(compile(...))` |
| T2 | `if` / `while` / `for` / `and` / `or` | after H |
| T3 | `def` (no closures), displays, unpack | after T2 |
| T4+ | `class` / `import` / closures / `with` / `assert` | wait on runtime |

Differentials by **program results**, never `co_code` identity. Firmware
emits no `CACHE`.

Allowlist for v1 emit: `LOAD_CONST` / `LOAD_SMALL_INT` / `LOAD_FAST` /
`STORE_FAST` / `LOAD_GLOBAL` / `LOAD_NAME` / ALU / compare / `CALL` /
`PUSH_NULL` / `LOAD_ATTR` / `NB_SUBSCR` / `STORE_SUBSCR` / `RETURN_VALUE` /
`POP_TOP` / `COPY` / `SWAP` / `NOP` / `RESUME` / T2 jumps / T3
`BUILD_*` / `MAKE_FUNCTION`. Do not emit `LOAD_BUILD_CLASS`, `IMPORT_*`,
`YIELD_*`, `LOAD_DEREF` / `MAKE_CELL`, `LOAD_SPECIAL`, `SETUP_*`,
`FORMAT_WITH_SPEC`, `STORE_SLICE`, `LOAD_COMMON_CONSTANT`, `MATCH_*`.

## F1 — must-have pycore (no rewrite exists)

| Builtin | Role |
| --- | --- |
| `_bi_code_alloc(nslots) → INT` | bump `code_ram_ptr_r`; OOM → `PY_TRAP_MEM_FAULT` |
| `_bi_code_emit(slot, opcode, oparg)` | write `{arg[39:8], opcode[7:0]}`; turn on `imem_we` for RAM |
| `_bi_code_new(fields) → CODE_OBJECT` | 9 Python args → 8-field 256 B object; flags (varargs / varkw / posonly) as a separate arg |

Host stand-ins in `image_from_source.py` / `load_rom_firmware_callables()`.
Highest-leverage test asset: C1–C5 debug off-device.

Excore cannot reach imem. Absolute slot addressing so jump patching is a
re-emit.

## Sequence

Each step is done when a **test** is green, not a doc.

| Step | Work | Done when |
| --- | --- | --- |
| **0** | Native methods + `e.args` | **Done** on main |
| **A** | `compat.py` + `test_compiler_subset.py` | host red on `xs[-1]` / `xs[1:]` / `class` / f-string in `compiler/` |
| **B** | F1 emit trio + host stand-ins | `img_code_new_call`: emit `RESUME; LOAD_SMALL_INT 7; RETURN_VALUE`, call, get 7 |
| **C** | Tokenizer (PyCPython-derived, subset) | host vs `tokenize` on a tiny corpus; `img_lexer_count` |
| **D** | Tiny-grammar LL(1) parser | `img_parser_tiny_expr` |
| **E** | Tagged-list AST | round-trip vs `ast.parse` on host |
| **F** | Symtable; closures → SyntaxError | host locals-vs-globals corpus |
| **G** | Codegen T1 + assembler (no CACHE; `EXTENDED_ARG` on long jumps) | host result differential vs CPython for T1 |
| **H** | ROM `compile` + `img_compile_eval_expr` | `eval(compile("1+2", "<s>", "eval")) == 3` on device |
| **I** | T2 then T3 | host corpus + a few device goldens |
| **J** | string `exec`/`eval` dispatch | optional; v1 can stay `eval(compile(...))` |
| **K** | size report before adding files | fail on ROM / heap / string overflow |

Self-host, BIOS, and the module loader stay **after H**. Compiling the
compiler is a size-and-subset problem, not a reason to start those first.

## Do not do on this path

| Item | Why |
| --- | --- |
| BIOS / module relocating loader | compiler lives in the boot image; output is a handle |
| LONG_STR content-eq on every probe | SHORT_STR names in v1; intern if needed |
| List/tuple slice hardware | rewrite; pull only if `copy_range` is the budget problem |
| Negative indices in hardware | rewrite |
| PEG parser / growing `RF_DEPTH` | LL(1) explicit stack |
| Closures, runtime `class`, `import`, `with`, `assert`, GC | later language tracks |
| Trap→raise (exceptions T6) | syntax errors are already Python `raise` |
| `open` / stdin | source is already a heap string |

## Tests

- Host: `make pycore-python-tests`. Oracle + opcode-mix tests require the
  submodule. Device images: `PYCORE_IMAGE_RUN` / plusargs, shared
  `tb_container`. No per-fixture Verilator rebuild.
- Wire new targets into `pycore-img` / `pycore-img-two-core`.
- Minimum device set for H: `img_code_new_call`, emit-range trap,
  `img_lexer_count`, `img_parser_tiny_expr`, `img_compile_eval_expr`,
  bad-mode `SyntaxError` / `ValueError`.

## Host tooling note

Until the ROM compiler exists, images still use CPython `compile()` in
`image_from_source.py`. Optional later: `--compiler pycpython` for
oracle-built images. Slice-const folding (literal `s[1:]` → `BINARY_SLICE`)
is host tooling, not firmware; see [`bytecode_support.md`](bytecode_support.md).

On-device `compile()` allocates string constants through
`HeapImageBuilder.alloc_str` — the same helper the image builder uses —
so a compiled-on-device module and an image-built module produce
byte-identical string objects (same header packing, same intern key
`(kind, payload)`).

## Historical docs

Folded into this file and superseded:

- [`old/code_loading_bios_tokenizer_plan.md`](old/code_loading_bios_tokenizer_plan.md) (P9 PyPy tokenizer — dropped)
- [`old/native_compiler_plan.md`](old/native_compiler_plan.md)
- [`old/native_compiler_full_plan.md`](old/native_compiler_full_plan.md)
- [`old/compile_fast_path.md`](old/compile_fast_path.md)
- [`old/implemented/compile_exec_plan.md`](old/implemented/compile_exec_plan.md)
