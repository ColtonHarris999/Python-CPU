# PyCore

SystemVerilog multi-cycle Python-bytecode core using tagged 132-bit entries:

```text
{ tag[3:0], value[127:0] }
```

The repository is a two-core system: `pycore/` is the primary CPython-bytecode
core, and `excore/` is an RV32 "exception core" (vendored singlecore
multicycle hart + trap firmware) that services
recoverable traps (list growth today; dict rehash / GC / unimplemented-opcode
emulation are future milestones) in firmware instead of halting. See
`pycore/docs/architecture.md` for the two-core design and `excore/docs/` for
the excore-specific docs (MMIO map, supported RV32I subset, firmware build
flow).

## Register layout and tag system

### Register layout

PyCore uses a 96-entry architectural register file:

- `RF[0..31]`: frame-local window
- `RF[32..95]`: operand-stack / runtime-allocation window

Function-call frames are managed by `pycore/rtl/pycore_frame.sv` as a ring-buffer
with spill-to-memory.

### Tag map

| Tag | Meaning |
| --- | --- |
| `0000` | `UNINITIALIZED` |
| `0001` | `INT` signed (64-bit fast path, sign-extended to 128) |
| `0010` | `FLOAT` IEEE 754 double in `value[63:0]`, upper bits zero |
| `0011` | `BOOL` with `value[0]` significant, upper bits zero |
| `0100` | `PTR` raw 128-bit byte address for data memory |
| `0101` | `TUPLE` `size[63:0]`, `addr[63:0]` |
| `0110` | `SHORT_STR` inline string: `size[3:0]`, `bytes[119:0]`, `flags[3:0]` |
| `0111` | `LONG_STR` descriptor: `size[63:0]`, `addr[63:0]` |
| `1000` | `OBJECT` opaque `addr[63:0]` |
| `1001` | `DICT` python dictionary: `addr[63:0]` |
| `1010` | `LIST` python list: `addr[63:0]` |
| `1011` | `SET` python set: `addr[63:0]` |
| `1100` | `CODE_OBJECT` PythonCodeObject: `addr[63:0]` |
| `1101` | `FRAME_OBJECT` PythonFrameObject: `addr[63:0]` |
| `1110` | `UNUSED` |
| `1111` | `NONE` python None type |

String value layouts:

- `SHORT_STR`: `size[3:0]`, `payload[119:0]`, `flags[3:0]`
- `LONG_STR`: `size[63:0]`, `addr[63:0]`

Additional design detail is documented in `pycore/docs/architecture.md`.

## Python version

`pycore/tools/preprocess.py` is strict and must run on **Python 3.14**.

## Docs

- Preprocessing breakdown: `pycore/docs/preprocessing_breakdown.md`
- Bytecode support matrix: `pycore/docs/bytecode_support.md`
- Two-core architecture: `pycore/docs/architecture.md`
- excore MMIO map: `excore/docs/mmio_map.md`
- excore RV32I subset: `excore/docs/rv32i_subset.md`
- excore firmware build flow: `excore/docs/firmware_build.md`

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
make pycore-top
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

1. preprocesses the requested function into program/const/string memory images;
2. runs PyCore simulation with those generated images;
3. prints return entry information from the retired `RETURN_VALUE`;
4. dumps memory image files (`program`, `const`, `string`) for inspection.

Optional output-path overrides:

```bash
make run-file \
  RUN_SOURCE=pycore/programs/smoke_return.py \
  RUN_FUNCTION=managed_entry \
  RUN_PROGRAM_HEX=pycore/programs/my_program.hex \
  RUN_CONST_HEX=pycore/programs/my_consts.hex \
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

## Legacy core quick reference

`make sim` compiles/disassembles a Python function, emits:

- program image (`programs/*_prog.hex`)
- constant image (`programs/*_consts.hex`)
- expected return (`programs/*_expected.txt`)

and then runs Verilator (`tb/tb_pycpu.cpp`) to validate final behavior.

---

## PyCore quick reference

Primary regression entrypoint:

```bash
make pycore-test
```

PyCore docs:

- architecture: `pycore/docs/architecture.md`
- preprocessing breakdown: `pycore/docs/preprocessing_breakdown.md`
- bytecode support matrix: `pycore/docs/bytecode_support.md`

## excore quick reference

excore is now fully integrated with pycore (Phase C): recoverable traps
(`PY_TRAP_LIST_GROW`, `PY_TRAP_LIST_EXTEND`) are handed to the excore over
`trap_mailbox.sv` instead of halting — see `pycore/docs/architecture.md`'s
"Two-core transport and integration" section for the mailbox format,
memory-ownership protocol, and trap taxonomy. `excore/` also still has its
own standalone regression (excore unit-tested against a mocked mailbox,
independent of pycore):

```bash
make excore-test                 # standalone excore (mocked mailbox)
make pycore-excore-system         # pycore <-> excore integration (real traps)
make pycore-img-two-core          # every img_* differential test on the two-core top
```

excore docs:

- MMIO map: `excore/docs/mmio_map.md`
- supported RV32I subset: `excore/docs/rv32i_subset.md`
- firmware build flow: `excore/docs/firmware_build.md`
- adding a new trap handler: `excore/docs/adding_a_trap_handler.md`
