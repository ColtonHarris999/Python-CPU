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
        ├── compiler_design.md    on-device compile() (active design)
        └── exceptions_plan.md     trap→raise, assert, with, subclasses
                │
                ▼
pycore/docs/*                    current machine (tags, opcodes, exceptions,
                                 memory_hierarchy.md, string_accel.md)
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
- Memory hierarchy on the hart: 8 KB L1I, 8 KB L1D, 128 KB inclusive L2,
  parameterized RAM, STRACC (strings are heap objects), 4-entry CODC, 16-entry
  GIC. Frame top-of-stack buffer **skipped** (L1D already hits >95% of the
  frame region). As-built: [`pycore/docs/memory_hierarchy.md`](../pycore/docs/memory_hierarchy.md),
  [`pycore/docs/string_accel.md`](../pycore/docs/string_accel.md).

## Timeline

Order is “what unblocks the next product step,” not calendar estimates.

### 1. Code-RAM writers — **landed** (architecture + compile step C)

`_bi_code_alloc` / `_bi_code_blit` / `_bi_code_patch` / `_bi_code_new` write
code RAM and fabricate `CODE_OBJECT` handles. Host stand-ins live in
`load_rom_firmware_callables()`. Details: [`compiler_design.md`](compiler_design.md)
step C and [`architecture_plan.md`](architecture_plan.md).

### 2. On-device `compile()` — **T1–T3 landed** (steps D–J)

Vendor [PyCPython](https://github.com/ColtonHarris999/PyCPython) at
`vendor/pycpython` is the **host oracle** and algorithm source. The
PyCore-subset port is `pycore_firmware/compiler/`. Do **not** run unmodified
PyCPython on the hart.

```python
eval(compile("1 + 2", "<s>", "eval")) == 3          # A1
exec(compile(src, "<s>", "exec"))  # globals match    # A2 → 7
```

Design: [`compiler_design.md`](compiler_design.md). Occupancy:
`make pycore-size-report` (step K). No BIOS, no module loader, no self-host
required for that.

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
- Overlays via the module loader if compiled-output headroom (285 code-RAM
  slots today) is too tight; `make pycore-size-report` is the occupancy gate.
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
