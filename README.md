# PyCore

SystemVerilog multi-cycle Python-bytecode core using tagged 132-bit entries:

```text
{ tag[3:0], value[127:0] }
```

This repository is a **two-core** system:

- **`pycore/`** — primary CPython 3.14 bytecode hart (image-boot from
  `compile()` object graphs; `LOAD_CONST` indexes `co_consts` in dmem).
- **`excore/`** — RV32 “exception core” (vendored multicycle hart under
  `excore/rtl/singlecore/` + trap firmware) that services *recoverable*
  container traps in firmware instead of halting.

Recoverable traps today: list grow / extend / mid-list delete, dict grow,
and set grow / update. Fatal traps (type, mem fault, illegal opcode, …)
still halt via `pycore_trap`. Future milestones include GC and
unimplemented-opcode emulation. See `pycore/docs/architecture.md` and
`excore/docs/`.

## Register layout and tag system

### Register layout

PyCore uses a 96-entry architectural register file:

- `RF[0..31]`: frame-local window
- `RF[32..95]`: operand-stack / runtime-allocation window

Function-call frames are managed by `pycore/rtl/pycore_frame.sv` as a
**simple dmem push/pop** call stack. A ring-buffer / spill design study
lives in `pycore/rtl/attic/pycore_frame_buffer.sv` (not in the build).

### Tag map

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

Full payload details: `pycore/docs/tags.md` and `pycore/docs/architecture.md`.

## Ownership split (containers ↔ excore)

| Work | Owner |
| --- | --- |
| Hash + rich equality (INT/BOOL/FLOAT/STR) | **pycore** |
| Linear probe / contains / tombstone skip | **pycore** |
| List append with spare capacity; last-element list delete | **pycore** |
| Empty `LIST_EXTEND` (no-op pop) | **pycore** |
| List/dict/set resize; non-empty `LIST_EXTEND`; mid-list delete; `SET_UPDATE` | **excore** |

Design notes: `pycore/docs/dict_excore.md`, `pycore/docs/set_excore.md`.

## Python version

Image tools (`pycore/tools/image_from_source.py`, differential tests) require
**Python 3.14**. The deprecated `preprocess.py` path is the same. Excore
assembler tools are plain Python 3 (not CPython-version-coupled).

Production regression uses **image-boot** (`image_from_source` /
`run_image_test`): imem is 1:1 with CPython code units; constants live in
the serialized `co_consts` tuple. Do not use the old inline three-slot
`LOAD_CONST` / const-ROM flow.

## Docs

| Doc | Path |
| --- | --- |
| Two-core architecture | `pycore/docs/architecture.md` |
| Tag map | `pycore/docs/tags.md` |
| Bytecode support matrix | `pycore/docs/bytecode_support.md` |
| Object model | `pycore/docs/object_model.md` |
| Image / preprocessing flow | `pycore/docs/preprocessing_breakdown.md` |
| Dict + excore split | `pycore/docs/dict_excore.md` |
| Sets + hash-container split | `pycore/docs/set_excore.md` |
| Planning / historical notes | `planning/` |
| excore MMIO map | `excore/docs/mmio_map.md` |
| excore RV32I subset | `excore/docs/rv32i_subset.md` |
| Firmware build | `excore/docs/firmware_build.md` |
| Adding a trap handler | `excore/docs/adding_a_trap_handler.md` |

## Quick setup after clone

### Local Linux (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y make g++ verilator python3.14 python3.14-venv docker.io
```

If your distro does not package `python3.14`, install Python 3.14 via pyenv (or
equivalent) and run make with `PYTHON=python3.14`.

### Local Windows

Use WSL2 Ubuntu and run the same Linux setup commands inside WSL.

### Docker

```bash
make docker-build
```

## Testing workflows

### Run an individual test target (local)

```bash
make pycore-tag-decode
make pycore-exec
make pycore-string-exec
make pycore-type-pairs
make pycore-mem
make pycore-frame
make pycore-frame-fib
make pycore-container
make pycore-img-smoke
make pycore-python-tests
make excore-asm-tests
make excore-cpu-test
make pycore-excore-system
make pycore-img-two-core
```

### Run all tests (local)

```bash
make all-tests
```

### Run any provided Python file (local)

```bash
make run-file \
  RUN_SOURCE=pycore/programs/smoke_return.py \
  RUN_FUNCTION=managed_entry
```

This flow:

1. preprocesses the requested function into program/string memory images;
2. runs PyCore simulation with those generated images;
3. prints return entry information from the retired `RETURN_VALUE`;
4. dumps memory image files (`program`, `string`) for inspection.

For new differential / image-boot coverage prefer `make pycore-img-*` (uses
`image_from_source.py`).

Optional output-path overrides:

```bash
make run-file \
  RUN_SOURCE=pycore/programs/smoke_return.py \
  RUN_FUNCTION=managed_entry \
  RUN_PROGRAM_HEX=pycore/programs/my_program.hex \
  RUN_STRING_HEX=pycore/programs/my_string_mem.hex
```

## Docker equivalents

```bash
make docker-pycore-test
make docker-all-tests
make docker-run-file RUN_SOURCE=pycore/programs/smoke_return.py RUN_FUNCTION=managed_entry
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
