# PyCore

SystemVerilog multi-cycle Python-bytecode core using tagged 132-bit entries:

```text
{ tag[3:0], value[127:0] }
```

The repository now contains a single active implementation path under `pycore/`.

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

- **Execution flow specification (LaTeX):** `pycore/docs/pycore_execution_flow.tex`
  (PDF: `pycore/docs/pycore_execution_flow.pdf`) — end-to-end path from Python
  source through image construction to multi-cycle bytecode retirement
- Architecture: `pycore/docs/architecture.md`
- Preprocessing breakdown: `pycore/docs/preprocessing_breakdown.md`
- Bytecode support matrix: `pycore/docs/bytecode_support.md`

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

- **execution flow specification**: `pycore/docs/pycore_execution_flow.pdf`
  (source: `pycore/docs/pycore_execution_flow.tex`)
- architecture: `pycore/docs/architecture.md`
- preprocessing breakdown: `pycore/docs/preprocessing_breakdown.md`
- bytecode support matrix: `pycore/docs/bytecode_support.md`
