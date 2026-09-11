# Master plan

PyCore is a CPython 3.14 bytecode CPU (hart) plus an RV32 companion
(`excore`) that finishes recoverable container work. Programs today boot
from a **host** `compile()` image. The remaining product work is to make
that pipeline run **on the hart**, and to close the language gaps that
still trap.

This file is the timeline. Topic plans hold the specifics. Living
inventories (what the hardware actually does today) stay in `pycore/docs/`
and `pycore_firmware/builtins/builtins.md`.

## How the docs connect

```text
planning/master_plan.md          timeline
        │
        ├── architecture_plan.md   boot, code RAM writers, loader, BIOS
        ├── bytecode_support.md    remaining opcodes
        ├── builtin_support.md     remaining ROM / native names
        ├── compile_plan.md        on-device compile() via PyCPython
        └── exceptions_plan.md     trap→raise, assert, with, subclasses
                │
                ▼
pycore/docs/*                    current machine (tags, opcodes, exceptions)
pycore_firmware/builtins/*       current ROM inventory
```

Do not duplicate opcode tables or type lists in planning files. Point at
`pycore/docs/bytecode_support.md` and `pycore/docs/exception_support.md`.

## What is already on main

- Two-core system: pycore bytecode hart + excore grow/extend/delete firmware.
- Image-boot from CPython 3.14 (`image_from_source.py` / `pycore_cli.py`).
- Int / bool / float / complex ALU, strings (index, iterate, variable-bound
  slice), lists / tuples / dicts / sets, `range`, `for` / comprehensions.
- Functions with defaults / `*args` / `**kwargs` / keyword calls.
- Module-level classes, instance attributes, native methods
  (`list.append`, `dict.get`, `str.join`, …).
- `try` / `except` / `else` / `finally`, `raise TypeError("msg")`, MRO match,
  cross-frame unwind, catchable firmware raises, readable `e.args`.
- ROM builtins (`print`, `min`/`sorted`/`map`/`zip`/…), native `ord`/`chr`/`int`/`str`/`len`.
- Writable **code RAM** + `exec`/`eval` on **precompiled** code objects.
- Heap / code mark-release.

## Timeline

Order is “what unblocks the next product step,” not calendar estimates.

### 1. Code-RAM writers (architecture + compile)

Nothing writes code RAM at runtime (`imem_we` is still 0). Add
`_bi_code_alloc` / `_bi_code_emit` / `_bi_code_new` and host stand-ins.
This is the only RTL gate for `compile()`. Details:
[`compile_plan.md`](compile_plan.md) F1 and [`architecture_plan.md`](architecture_plan.md).

### 2. On-device `compile()` (compile plan)

Vendor [PyCPython](https://github.com/ColtonHarris999/PyCPython) at
`vendor/pycpython` is the **host oracle** and algorithm source. Port a
PyCore subset into `pycore_firmware/compiler/`. Do **not** run unmodified
PyCPython on the hart. Do **not** port PyPy’s tokenizer — that path is
abandoned.

First success:

```python
eval(compile("1 + 2", "<s>", "eval")) == 3
```

No BIOS, no module loader, no self-host required for that.

### 3. Language leftovers in parallel

These do not block first `compile()`, but they are the rest of “Python on
this CPU”:

| Track | Plan | Next slice |
| --- | --- | --- |
| Exceptions | [`exceptions_plan.md`](exceptions_plan.md) | T6 trap→raise, then `assert` / `with` / user subclasses |
| Bytecode | [`bytecode_support.md`](bytecode_support.md) | list/tuple slice, `TO_BOOL` on OBJECT, `LOAD_SUPER_ATTR`, import/class/closures |
| Builtins | [`builtin_support.md`](builtin_support.md) | string `exec`/`eval` after compile; F2 `getattr` / empty `min`/`max`; print LONG_STR |
| Architecture | [`architecture_plan.md`](architecture_plan.md) | BIOS + module loader **after** first compile; optional intern / GC |

### 4. Later (after first compile is green)

- String-form `exec` / `eval` (thin dispatch over `compile`).
- Size-report the firmware compiler; overlay via the module loader if it
  does not fit ROM.
- Self-host: compile the compiler on device.
- BIOS that boots and `exec`s a payload.

## Non-goals for this cycle

- Running `vendor/pycpython` on the hart.
- An open-source (PyPy) tokenizer port.
- Merging the simulator UI (`ui` branch) onto `main`.
- Treating `preprocess.py` as a production path (image-boot only).

## Test contract

Host tests: `make pycore-python-tests` (CI job `python`). Clone with
`git submodule update --init` so `vendor/pycpython` is present.

Device images: `PYCORE_IMAGE_RUN` / plusargs into one shared `tb_container`
binary. Do not add per-fixture Verilator rebuilds. See the root `README.md`.
