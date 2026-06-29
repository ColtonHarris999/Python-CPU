# PyCore

SystemVerilog multi-cycle Python-bytecode core using tagged 131-bit entries:

```text
{ tag[2:0], value[127:0] }
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

- `000`: `UNINITIALIZED`
- `001`: `INT`
- `010`: `FLOAT`
- `011`: `BOOL`
- `100`: `PTR`
- `101`: `OBJECT`
- `110`: `SHORT_STR`
- `111`: `LONG_STR`

String value layouts:

- `SHORT_STR`: `size[3:0]`, `payload[119:0]`, `flags[3:0]`
- `LONG_STR`: `size[63:0]`, `addr[63:0]`

Additional design detail is documented in `pycore/docs/architecture.md`.

## Python version

`pycore/tools/preprocess.py` is strict and must run on **Python 3.14**.

## Docs

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

## GitHub merge gate for `main`

`.github/workflows/all-tests.yml` publishes the required status check `all-tests`.

To enforce this check on `main`:

1. `Settings -> Branches -> Branch protection rules -> main`
2. Enable **Require status checks to pass before merging**
3. Require check: **all-tests**
4. (Recommended) Enable **Require a pull request before merging**
