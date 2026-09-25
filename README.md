# PyCore

A research CPU whose native ISA is a **CPython 3.14 bytecode subset**. The
prototype is portable SystemVerilog, simulated with Verilator.

This repository is a **two-core** system:

- **`pycore/`** — the bytecode hart. Programs boot from a CPython `compile()`
  object graph (`image_from_source.py`): instruction memory is 1:1 with CPython
  code units; constants live in the serialized `co_consts` tuple in dmem.
- **`excore/`** — an RV32 companion hart that finishes *recoverable* container
  work (list/dict/set grow, extend, mid-list delete) in firmware instead of
  halting. Fatal traps (type, mem fault, illegal opcode, …) still halt.

## Current status (main)

Shipped and regression-tested:

- Int / bool / float ALU, strings (index, iterate, slice with variable or
  unit-step literal bounds),
  lists / tuples / dicts / sets, `range`, `for` / comprehensions, functions with
  defaults / `*args` / `**kwargs` / keyword calls.
- Module-level classes, instance attributes, native methods
  (`list.append`, `dict.get`, `str.join`, …).
- `try` / `except` / `else` / `finally`, `raise TypeError` / `raise TypeError("msg")`,
  MRO matching, cross-frame unwind. Firmware raises are catchable (F1); `e.args`
  is readable (F4).
- ROM builtins (`print`, `min`/`sorted`/`map`/`zip`/…), native `ord`/`chr`/`int`/`str`/`len`.
- List/tuple sequence repeat (`[1,2] * 3`) and concat (`[1,2] + [3]`). Writable code RAM + `exec`/`eval` on
  precompiled code objects or source strings.
- **On-device `compile()`** (`pycore/docs/compiler.md`): a compiler
  written in the PyCore subset, resident in code RAM at reset, reached
  through four code-write builtins. Closures, `lambda`, decorators,
  `assert`, and simple f-strings are in; so is the full `def` parameter
  grammar. ROM `bios(payload)` execs a source string.

Still open (see `planning/master_plan.md`):

- Module loader / relocation, and self-hosting (the compiler does not yet
  fit in its own compiled-output headroom — `make pycore-size-report`).
- `with`, `import`, generators, `except*`, runtime `class`,
  trap→Python-exception, list/tuple slicing, negative indices,
  `del` of a module-level name.
- Garbage collection: `compile()` leaks its working set; the caller
  reclaims with `_bi_heap_mark` / `_bi_heap_release`.

## Try a Python file

Requires **Python 3.14** and Verilator. Lint first, then simulate:

```bash
make help
make lint-file RUN_SOURCE=pycore/programs/example_sum_loop.py
make run-file  RUN_SOURCE=pycore/programs/example_sum_loop.py
```

Equivalent:

```bash
python3.14 pycore/tools/pycore_cli.py help
python3.14 pycore/tools/pycore_cli.py lint pycore/programs/example_sum_loop.py
python3.14 pycore/tools/pycore_cli.py run  pycore/programs/example_sum_loop.py
```

`run` compiles the module to a boot image, executes `managed_entry()` on host
CPython 3.14 for a golden `int`/`bool`, then runs the shared two-core
`tb_container` (plusargs, same binary as image CI) and checks that the retired
return matches. `help` prints the supported-program summary below in full.

A program should define a no-arg `managed_entry()` that returns `int` or `bool`.
If you do not call it at module level, `run` appends a call. Type annotations
are stripped.

## What programs are allowed

**Yes:** functions, `if`/`while`/`for`, list/dict/set/tuple displays, f-strings
without format specs, `try`/`except`/`finally`, `raise` of seeded exception
types, module-level `class C:` (no bases), keyword/`*args`/`**kwargs` calls.
Types: 64-bit `int`, `bool`, `float`, `None`, `str`, `list`, `tuple`, `dict`,
`set`, `range`. String slicing (`s[a:b]`, including unit-step literals like `s[1:]`).

**Boot builtins:** `len`, `range`, `ord`, `chr`, `int`, `str`, `print`, `min`/`max`,
`sum`, `sorted`, `map`/`zip`/`enumerate`/`filter`/`reversed` (these return
**lists**), `list`/`dict`/`tuple`/`set`, `abs`/`all`/`any`, `bin`/`hex`/`oct`,
`hasattr`/`getattr`/`isinstance`, `exec`/`eval` on a code object **or a
source string**, `compile()` (T1–T6 source → code object), `bios(payload)`.
Methods: `list.append/pop/extend/clear`, `set.add/update`,
`str.join/startswith/endswith/find`, `dict.get/keys/items/values/update/pop`.

**No:** `import`, generators/`async`, `match`, `with`,
runtime `class`, `super()`, files,
slice assignment, list/tuple slicing, format-spec f-strings, `STR * INT`,
negative indices. String slice step other than `None`/1 is still rejected.

Host `compile()` for images is still CPython. ROM `compile()` ships the T1–T6
grammar plus closures: `eval(compile("1 + 2", "<s>", "eval"))` → 3,
`exec(compile(src, "<s>", "exec"))` A2 → 7, `def` with defaults /
`*args` / keyword-only / `**kwargs`, keyword call sites, conditional
expressions, chained assignment, and comprehensions with an element
expression and an `if` filter. `del` of a module-level name, annotations,
and non-literal defaults are compile-time `SyntaxError` (see
`pycore/docs/compiler.md` D1–D12).
[PyCPython](https://github.com/ColtonHarris999/PyCPython)
is vendored at `vendor/pycpython` as the oracle / algorithm source
(`git submodule update --init`). Occupancy: `make pycore-size-report`.

**Ceilings:** missing dict keys and unbound locals still halt with a hardware
trap rather than a catchable Python exception. `int` is 64-bit, not
arbitrary-precision. STRACC case/classify above U+00FF is a recoverable
firmware trap (performance, still correct).

The linter is the gate: if `lint` is OK, image-boot will accept the file. Hardware
may still trap on a semantic ceiling the linter cannot see. Details:
`pycore/docs/bytecode_support.md` and `pycore_firmware/builtins/builtins.md`.

## Register layout and tags

256-entry RF ring: occupancy is the suffix `[watermark, tos)`; CALL spills a
watermark prefix to dmem (`0x100000`) when the live window would not fit, and
RETURN fills it back. Entries are `{ tag[3:0], value[127:0] }`. Call-frame
*descriptors* are a dmem push/pop stack (`pycore/rtl/pycore_frame.sv`). Behind
`imem_*` / `dmem_*` is an 8 KB L1I, 8 KB L1D, 128 KB L2 and parameterized RAM;
see `pycore/docs/memory_hierarchy.md`.

| Tag | Name | Notes |
| --- | --- | --- |
| `0000` | CONTROL | UNINIT / NONE / NULL via `value[3:0]` |
| `0001` | INT | signed i64 fast path |
| `0010` | FLOAT | IEEE 754 binary64 |
| `0011` | COMPLEX | real + imag binary64 |
| `0100` | BOOL | `value[0]` |
| `0101` | ITER | hybrid iterator |
| `0110` | TUPLE | `{size, addr}` |
| `0111` | SHORT_STR | inline ≤15 kind-1 bytes |
| `1000` | LONG_STR | STRACC handle `{flags, kind, nbytes, hash, nchars, addr}` |
| `1001` | MUT_COLLEC | LIST / DICT / SET / BYTEARRAY via kind nibble |
| `1010` | OBJECT | general heap object |
| `1011` | RANGE | inline i32 triple or tuple pointer |
| `1100` | BYTES | reserved / partial |
| `1101` | CODE_OBJECT | |
| `1110` | TOMBSTONE | deleted dict/set key sentinel |
| `1111` | FROZENSET | reserved |

Payload details: `pycore/docs/tags.md`.

## Ownership split (containers ↔ excore)

| Work | Owner |
| --- | --- |
| Hash + rich equality (INT/BOOL/FLOAT/STR) | **pycore** |
| Linear probe / contains / tombstone skip | **pycore** |
| List append with spare capacity; last-element list delete | **pycore** |
| Empty `LIST_EXTEND` (no-op pop) | **pycore** |
| List/dict/set resize; non-empty `LIST_EXTEND`; mid-list delete; uncontaminated `SET_UPDATE` / `DICT_UPDATE` / `DICT_MERGE`; `print` to the console | **excore** |
| Bulk updates with an OBJECT key or element (contaminated), and every `TUPLE`-source `SET_UPDATE` | **pycore** (`pycore_cont_bulk.svh`) |

Recoverable excore traps (`EXCORE_EN=1`): list grow (9), list extend (10),
dict grow (11), list delete (12), set grow (13), set update (14), builtin
call (16), dict update (19), and dict merge (20). See
`pycore/docs/architecture.md`.

## Docs

| Doc | Path |
| --- | --- |
| Two-core architecture | `pycore/docs/architecture.md` |
| Tag map | `pycore/docs/tags.md` |
| Bytecode support matrix | `pycore/docs/bytecode_support.md` |
| Exception types | `pycore/docs/exception_support.md` |
| Object model | `pycore/docs/object_model.md` |
| Code loading | `pycore/docs/code_loading.md` |
| Image / preprocessing flow | `pycore/docs/preprocessing_breakdown.md` |
| Dict / set + excore | `pycore/docs/dict_excore.md`, `pycore/docs/set_excore.md` |
| ROM builtins inventory | `pycore_firmware/builtins/builtins.md` |
| On-device `compile()` | `pycore/docs/compiler.md` |
| Memory hierarchy / STRACC | `pycore/docs/memory_hierarchy.md`, `pycore/docs/string_accel.md` |
| Roadmap (what is left to build) | `planning/master_plan.md` |
| Cleanup backlog for agents | `planning/cleanup_report.md` |
| Archived designs | `planning/old/` |
| PyCPython vendor | `vendor/pycpython` (`git submodule update --init`) |
| excore MMIO / ISA / firmware | `excore/docs/` |

## Setup

**Linux (Ubuntu/Debian):**

```bash
git submodule update --init --recursive
sudo apt-get update
sudo apt-get install -y make g++ verilator python3.14 python3.14-venv docker.io
```

The RTL needs **Verilator 5.032 or newer**: it slices function-call return
values, which older releases (Ubuntu's 5.020 package, for one) reject. If
your distro ships an older Verilator, use the Docker targets below, or
build Verilator from source. If the distro has no `python3.14`, install it
via pyenv (or equivalent) and pass `PYTHON=python3.14` to make. Windows:
WSL2 Ubuntu, same commands.

```bash
make docker-build
make docker-lint-file RUN_SOURCE=pycore/programs/example_sum_loop.py
make docker-run-file  RUN_SOURCE=pycore/programs/example_sum_loop.py
```

## Testing workflows

CI compiles **two** shared `tb_container` simulators (single-core and two-core)
and then runs image/container fixtures against those binaries via plusargs.
`make run-file` uses the same two-core binary (compile once, then plusargs).
Planning-doc and markdown-only PRs (including `pycore/docs/` and
`excore/docs/`) skip the hardware jobs.

### Fast checks (no full-chip sim)

```bash
make pycore-python-tests   # host unit tests (includes the linter)
make pycore-rtl-unit
make excore-asm-tests
```

### Shared simulators (compile once, reuse)

```bash
make pycore-sim-img            # EXCORE_EN=0
make pycore-sim-img-twocore    # EXCORE_EN=1
```

### Grouped hardware suites

```bash
make all-tests TEST_JOBS=4     # pycore + excore; TEST_JOBS default 2
make pycore-container          # container fixtures (some still hand-built hex)
make pycore-img                # single-core image-boot
make pycore-excore-system      # two-core trap round-trips
make pycore-img-two-core       # image-boot on the two-core top
make excore-cpu-test
```

Image-boot tests (`make pycore-img-*`) are the production path. Do not add
new `BOOT_EN=0` hex fixtures or new uses of the deprecated `preprocess.py`
(see `planning/cleanup_report.md` items A4 and C1).

### Docker equivalents

```bash
make docker-python-tests
make docker-rtl-unit
make docker-container
make docker-img
make docker-two-core
make docker-excore
make docker-pycore-test
make docker-all-tests
make docker-lint-file RUN_SOURCE=pycore/programs/example_sum_loop.py
make docker-run-file  RUN_SOURCE=pycore/programs/example_sum_loop.py
```

If needed, you can pass host-network flags:

```bash
make docker-all-tests DOCKER_BUILD_FLAGS=--network=host DOCKER_RUN_FLAGS=--network=host
```

---

## PyCore quick reference

```bash
make pycore-test
```

## excore quick reference

With `EXCORE_EN=1`, recoverable traps are handed to excore over
`trap_mailbox.sv` instead of halting:

| Code | Trap |
| --- | --- |
| 9 | `PY_TRAP_LIST_GROW` |
| 10 | `PY_TRAP_LIST_EXTEND` |
| 11 | `PY_TRAP_DICT_GROW` |
| 12 | `PY_TRAP_LIST_DELETE` |
| 13 | `PY_TRAP_SET_GROW` |
| 14 | `PY_TRAP_SET_UPDATE` |
| 16 | `PY_TRAP_BUILTIN_CALL` |
| 19 | `PY_TRAP_DICT_UPDATE` |
| 20 | `PY_TRAP_DICT_MERGE` |

See `pycore/docs/architecture.md` (“Two-core transport and integration”) for
mailbox format, memory-ownership protocol, and full trap taxonomy.
`excore/` also has a standalone regression against a mocked mailbox:

```bash
make excore-test                 # standalone excore (mocked mailbox)
make pycore-excore-system         # pycore <-> excore integration (real traps)
make pycore-img-two-core          # img_* differentials on the two-core top
```
