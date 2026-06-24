# Python-CPU / PyCore

SystemVerilog research CPU project with two execution paths:

- `rtl/pycpu_core.sv`: original managed-bytecode core.
- `pycore/`: tagged-value (`{tag[2:0], value[127:0]}`) PyCore prototype.

Both flows are pinned to **CPython 3.14 bytecode numbering**.

---

## Python version (strict)

Tooling is intentionally strict:

- `tools/gen_bytecode_assets.py` requires Python 3.14.
- `pycore/tools/preprocess.py` requires Python 3.14.

If you run those scripts under any other interpreter, they fail fast by design.

---

## Preprocessing: what happens and why

A detailed breakdown is here:

- `pycore/docs/preprocessing_breakdown.md`

That document also states the preprocessing budget rule: preprocessing should
primarily package/validate programs, not become a hidden software runtime that
defeats the purpose of PyCore hardware execution.

---

## Bytecode support lists (full / partial / unsupported)

The three requested lists are maintained here:

- `pycore/docs/bytecode_support.md`

Each listed bytecode has a short description and PyCore-relevant note.

---

## Quick setup after clone

### Option A: Local Linux (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y make g++ verilator python3.14 python3.14-venv
```

If your distro does not ship `python3.14` directly, install Python 3.14 by your
preferred method (for example, pyenv) and run make with `PYTHON=python3.14`.

### Option B: Local Windows (recommended via WSL2)

Use WSL2 Ubuntu and run the same Linux commands above inside WSL.

### Option C: Docker (no local Verilator/Python setup needed)

```bash
make docker-build
```

---

## Testing workflows

You can run **individual tests**, **all tests**, or **a custom Python file**.

### Run one individual test target (local)

Examples:

```bash
make sim
make test-programs
make pycore-tag-decode
make pycore-exec
make pycore-type-pairs
make pycore-mem
make pycore-frame
make pycore-top
make pycore-test
```

### Run all repository tests (local)

```bash
make all-tests
```

This runs:

- `make test-programs`
- `make pycore-test`

### Run any provided Python file and print memory + return artifacts (local)

```bash
make run-file \
  RUN_SOURCE=programs/demo_program.py \
  RUN_FUNCTION=managed_entry
```

What this does:

1. generates bytecode assets from the given Python file/function;
2. runs simulation;
3. prints memory contents for generated program/constant images;
4. shows the expected return artifact path (and simulator output includes final return/trap result).

You can override artifact paths:

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

### Custom file run (memory dump + return artifacts)

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

## Legacy core quick reference

`make sim` compiles/disassembles a Python function, emits:

- program image (`programs/*_prog.hex`)
- constant image (`programs/*_consts.hex`)
- expected return (`programs/*_expected.txt`)

and then runs Verilator (`tb/tb_pycpu.cpp`) to validate final behavior.

---

## PyCore quick reference

Primary documentation:

- architecture: `pycore/docs/architecture.md`
- preprocessing breakdown: `pycore/docs/preprocessing_breakdown.md`
- bytecode support matrix: `pycore/docs/bytecode_support.md`

Primary regression entrypoint:

```bash
make pycore-test
```
