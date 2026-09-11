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

- Int / bool / float ALU, strings (index, iterate, slice with variable bounds),
  lists / tuples / dicts / sets, `range`, `for` / comprehensions, functions with
  defaults / `*args` / `**kwargs` / keyword calls.
- Module-level classes, instance attributes, native methods
  (`list.append`, `dict.get`, `str.join`, …).
- `try` / `except` / `else` / `finally`, `raise TypeError` / `raise TypeError("msg")`,
  MRO matching, cross-frame unwind. Firmware raises are catchable (F1); `e.args`
  is readable (F4).
- ROM builtins (`print`, `min`/`sorted`/`map`/`zip`/…), native `ord`/`chr`/`int`/`str`/`len`.
- List/tuple sequence repeat (`[1,2] * 3`). Writable code RAM + `exec`/`eval` on
  precompiled code objects.

Still open (see `planning/`):

- BIOS / module loader / on-device tokenizer (Plan 1 P2, P5, P9).
- Native `compile()` (Plan 2).
- `assert`, `with`, `import`, generators, `except*`, trap→Python-exception (T6),
  list/tuple slicing, literal `s[1:]` slice constants, negative indices.

In review (not on `main` yet): slice-const folding and `int(float)` /
`max(float)` (PRs #84 / #88); compiler plans (PRs #85 / #87).

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
CPython 3.14 for a golden `int`/`bool`, then runs the two-core hart in Verilator
and checks that the retired return matches. `help` prints the supported-program
summary below in full.

A program should define a no-arg `managed_entry()` that returns `int` or `bool`.
If you do not call it at module level, `run` appends a call. Type annotations
are stripped.

## What programs are allowed

**Yes:** functions, `if`/`while`/`for`, list/dict/set/tuple displays, f-strings
without format specs, `try`/`except`/`finally`, `raise` of seeded exception
types, module-level `class C:` (no bases), keyword/`*args`/`**kwargs` calls.
Types: 64-bit `int`, `bool`, `float`, `None`, `str`, `list`, `tuple`, `dict`,
`set`, `range`. String slicing with *variable* bounds (`s[a:b]`).

**Boot builtins:** `len`, `range`, `ord`, `chr`, `int`, `str`, `print`, `min`/`max`,
`sum`, `sorted`, `map`/`zip`/`enumerate`/`filter`/`reversed` (these return
**lists**), `list`/`dict`/`tuple`/`set`, `abs`/`all`/`any`, `bin`/`hex`/`oct`,
`hasattr`/`getattr`/`isinstance`, `exec`/`eval` on a code object.
Methods: `list.append/pop/extend/clear`, `set.add/update`,
`str.join/startswith/endswith/find`, `dict.get/keys/items/values/update/pop`.

**No:** `import`, generators/`async`, `match`, `assert`, `with`, closures,
runtime `class`, `super()`, `compile()`, string-form `exec`/`eval`, files,
slice assignment, list/tuple slicing, all-literal `s[1:]` (bind bounds to
variables), format-spec f-strings, `STR * INT`, negative indices.

**Ceilings:** missing dict keys and unbound locals still halt with a hardware
trap rather than a catchable Python exception. `int` is 64-bit, not
arbitrary-precision.

The linter is the gate: if `lint` is OK, image-boot will accept the file. Hardware
may still trap on a semantic ceiling the linter cannot see. Details:
`pycore/docs/bytecode_support.md` and `pycore_firmware/builtins/builtins.md`.

## Register layout and tags

96-entry RF: `RF[0..31]` frame locals, `RF[32..95]` operand stack. Entries are
`{ tag[3:0], value[127:0] }`. Call frames are a dmem push/pop stack
(`pycore/rtl/pycore_frame.sv`).

| Tag | Name | Notes |
| --- | --- | --- |
| `0000` | CONTROL | UNINIT / NONE / NULL via `value[3:0]` |
| `0001` | INT | signed i64 fast path |
| `0010` | FLOAT | IEEE 754 binary64 |
| `0011` | COMPLEX | real + imag binary64 |
| `0100` | BOOL | `value[0]` |
| `0101` | ITER | hybrid iterator |
| `0110` | TUPLE | `{size, addr}` |
| `0111` | SHORT_STR | inline ≤15 UTF-8 bytes |
| `1000` | LONG_STR | `{len, addr}` |
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
| List/dict/set resize; non-empty `LIST_EXTEND`; mid-list delete; `SET_UPDATE` | **excore** |

Recoverable excore traps (`EXCORE_EN=1`): list grow (9), list extend (10),
dict grow (11), list delete (12), set grow (13), set update (14), plus dict
update/merge. See `pycore/docs/architecture.md`.

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
| Active plans | `planning/` |
| excore MMIO / ISA / firmware | `excore/docs/` |

## Setup

**Linux (Ubuntu/Debian):**

```bash
sudo apt-get update
sudo apt-get install -y make g++ verilator python3.14 python3.14-venv docker.io
```

If the distro has no `python3.14`, install it via pyenv (or equivalent) and
pass `PYTHON=python3.14` to make. Windows: WSL2 Ubuntu, same commands.

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
make pycore-container          # legacy hex fixtures
make pycore-img                # single-core image-boot
make pycore-excore-system      # two-core trap round-trips
make pycore-img-two-core       # image-boot on the two-core top
make excore-cpu-test
```

Image-boot tests (`make pycore-img-*`) are the production path. Do not use the
old inline three-slot `LOAD_CONST` / `preprocess.py` flow for new work.

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

See `pycore/docs/architecture.md` (“Two-core transport and integration”) for
mailbox format, memory-ownership protocol, and full trap taxonomy.
`excore/` also has a standalone regression against a mocked mailbox:

```bash
make excore-test                 # standalone excore (mocked mailbox)
make pycore-excore-system         # pycore <-> excore integration (real traps)
make pycore-img-two-core          # img_* differentials on the two-core top
```
