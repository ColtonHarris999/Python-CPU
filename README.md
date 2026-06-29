# Python-CPU / PyCore

SystemVerilog research CPU project with two execution paths:

- `rtl/pycpu_core.sv`: original managed-bytecode core.
- `pycore/`: tagged-value (`{tag[2:0], value[127:0]}`) PyCore prototype.

Both flows are pinned to **CPython 3.14 bytecode numbering**.

---

## Register layout and tag system (PyCore)

### Register layout

PyCore uses a 96-entry architectural register file:

- `RF[0..31]`: frame-local window
- `RF[32..95]`: operand-stack / runtime allocation window

Call frames are managed by `pycore_frame.sv` as a ring-buffer + spill system:

- resident frame slots live in the physical RF window
- when resident capacity is full, oldest frame slots spill to memory
- spilled entries are tracked by per-frame mapping tables

### Tagged entry format

Each register entry is 131 bits:

```text
{ tag[2:0], value[127:0] }
```

Current tag map:

- `000`: `UNINITIALIZED`
- `001`: `INT`
- `010`: `FLOAT`
- `011`: `BOOL`
- `100`: `PTR`
- `101`: `OBJECT`
- `110`: `SHORT_STR` (inline string)
- `111`: `LONG_STR` (`size[63:0]`, `addr[63:0]`)

String-specific value layouts:

- `SHORT_STR`: `size[3:0]`, `payload[119:0]`, `flags[3:0]`
- `LONG_STR`: `size[63:0]`, `addr[63:0]`

For full architecture rationale, see:

- `pycore/docs/architecture.md`

---

## Python version (strict)

Tooling is intentionally strict:

- `tools/gen_bytecode_assets.py` requires Python 3.14.
- `pycore/tools/preprocess.py` requires Python 3.14.

If you run those scripts under any other interpreter, they fail fast by design.

---

## Preprocessing and bytecode support docs

- preprocessing breakdown and budget: `pycore/docs/preprocessing_breakdown.md`
- bytecode support lists (full / partial / unsupported): `pycore/docs/bytecode_support.md`

---

## Quick setup after clone

### Option A: Local Linux (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y make g++ verilator python3.14 python3.14-venv docker.io
```

If `python3.14` is not available from your distro packages, install Python 3.14
via your preferred method (for example pyenv) and run make with
`PYTHON=python3.14`.

### Option B: Local Windows (recommended via WSL2)

Use WSL2 Ubuntu and run the same Linux commands above inside WSL.

### Option C: Docker (no local Verilator/Python setup needed)

```bash
make docker-build
```

---

## Testing workflows

You can run **individual tests**, **all tests**, or **a custom Python file**.

### Individual test targets (local)

```bash
make sim
make test-programs
make pycore-tag-decode
make pycore-exec
make pycore-string-exec
make pycore-type-pairs
make pycore-mem
make pycore-frame
make pycore-frame-fib
make pycore-top
make pycore-test
```

### All tests (local)

```bash
make all-tests
```

### Run any provided file and print memory artifacts (local)

```bash
make run-file \
  RUN_SOURCE=programs/demo_program.py \
  RUN_FUNCTION=managed_entry
```

This command:

1. generates bytecode assets from the given file/function;
2. runs simulation;
3. dumps program/constant memory image contents;
4. reports expected-return artifact path and simulator result.

You can override artifact output paths:

```bash
make run-file \
  RUN_SOURCE=programs/demo_program.py \
  RUN_FUNCTION=managed_entry \
  RUN_PROGRAM_HEX=programs/my_prog.hex \
  RUN_CONST_HEX=programs/my_consts.hex \
  RUN_EXPECTED_TXT=programs/my_expected.txt
```

---

## Docker equivalents

### Individual targets

```bash
make docker-sim
make docker-test-programs
make docker-pycore-test
```

### All tests

```bash
make docker-all-tests
```

### Custom-file run (memory dump + return artifacts)

```bash
make docker-run-file \
  RUN_SOURCE=programs/demo_program.py \
  RUN_FUNCTION=managed_entry
```

If your environment needs host networking:

```bash
make docker-all-tests DOCKER_BUILD_FLAGS=--network=host DOCKER_RUN_FLAGS=--network=host
```

---

## GitHub merge gate for `main`

CI workflow `.github/workflows/all-tests.yml` publishes a required-friendly
status check named:

- `all-tests`

To enforce "tests must pass before merging to main", enable branch protection on
`main` and require that status check:

1. GitHub repository `Settings -> Branches -> Branch protection rules -> main`
2. Enable **Require status checks to pass before merging**
3. Select check: **all-tests**
4. (Recommended) Enable **Require a pull request before merging** to block
   direct commits to `main` unless policy allows them.

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
