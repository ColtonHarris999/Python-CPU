# Python-CPU

SystemVerilog RTL scaffold for a managed-code processor that executes a small,
stack-based subset of CPython bytecode using a 5-stage pipeline:

1. **Fetch (IF)**: reads 16-bit instruction words from program memory.
2. **Decode (ID)**: extracts opcode/oparg and sources stack operands.
3. **Execute (EX)**: performs ALU operation or address/select work.
4. **Memory (MEM)**: stage register for load/constant values and ALU outputs.
5. **Writeback (WB)**: commits results to stack/locals and handles return/trap.

## Python version

**Requires Python 3.14 (strict).** The CPU's ISA, the asset generator, and the
container all pin to CPython 3.14's bytecode numbering. The generator raises if
invoked under any other interpreter (3.12, 3.13, future 3.15, etc.) rather than
silently miscompile.

## Supported bytecode subset

Opcode numbers below are CPython 3.14 values (verified against
`opcode.opmap`).

- `RESUME (128)`
- `NOP (27)`
- `LOAD_CONST (82)`
- `LOAD_SMALL_INT (94)` — oparg is the literal int (0..255)
- `LOAD_FAST (84)`
- `LOAD_FAST_BORROW (86)` — treated as `LOAD_FAST` by the CPU
- `LOAD_FAST_LOAD_FAST (89)` — lowered to two `LOAD_FAST` words by the generator
- `LOAD_FAST_BORROW_LOAD_FAST_BORROW (87)` — lowered to two `LOAD_FAST_BORROW` words by the generator
- `STORE_FAST (112)`
- `BINARY_OP (44)` with oparg:
  - arithmetic: `0`/`13` add (`+`, `+=`), `10`/`23` subtract (`-`, `-=`),
    `5`/`18` multiply (`*`, `*=`), `2`/`15` floor divide (`//`, `//=`)
    with Python floor semantics for signed ints, `6`/`19` modulo (`%`, `%=`)
    with Python remainder semantics, `8`/`21` power (`**`, `**=`, non-negative exponent)
  - bitwise: `1`/`14` and, `7`/`20` or, `12`/`25` xor
  - shifts: `3`/`16` left shift, `9`/`22` arithmetic right shift
  - non-integer variants (`@`, `/` and in-place forms) are trapped as illegal instructions
- `RETURN_VALUE (35)`

Instruction encoding in program memory uses one 16-bit word:

- bits `[7:0]` = opcode
- bits `[15:8]` = oparg

Hex files are loaded through `$readmemh`:

- `programs/demo_prog.hex`: instruction words (`oooo` format, low byte opcode)
- `programs/demo_consts.hex`: 32-bit signed constants (`hhhhhhhh`)

## Example program

`demo_prog.hex` computes:

```text
x = 6
y = 7
return x*y + 2
```

Expected return value is `44`.

## How the test works

Current verification is an end-to-end functional check:

1. `tools/gen_bytecode_assets.py` loads a real Python source file (`programs/demo_program.py`)
   and compiles/disassembles `managed_entry`.
2. The script validates opcodes are within the CPU's supported subset, then emits:
   - `programs/demo_prog.hex` (instruction words)
   - `programs/demo_consts.hex` (constant memory image)
   - `programs/demo_expected.txt` (expected return value from executing the Python function)
3. Verilator runs `tb/tb_pycpu.cpp`, which:
   - clocks and resets the CPU
   - waits for `halted`
   - fails on `trap_valid` unless the test explicitly expects a trap
   - checks `illegal_instr_valid` for expected illegal-instruction trap cases
   - compares `ret_value` with `demo_expected.txt`

That means the expected result is derived directly from the Python function, and the
testbench checks the CPU behavior against that reference result.

## Run locally with Verilator

Requirements:

- Python 3.14 (strict; see "Python version" above)
- Verilator (v5+ recommended)
- C++ compiler (g++)
- make

Build and run (this also regenerates bytecode assets from Python source):

```bash
make sim
```

You should see:

```text
PASS: returned 44 ...
```

Run the full test-program suite (normal arithmetic/bitwise ops, in-place ops, and
an explicit invalid-opcode trap case):

```bash
make test-programs
```

## Run in Docker (recommended for teams)

Docker keeps the toolchain consistent across contributors and CI.

### Option 1: Makefile wrappers

```bash
make docker-build
make docker-sim
```

`docker-sim` mounts the current repository into the container and runs `make sim`.

### Option 2: Docker Compose

```bash
docker compose run --rm sim
```

### What is inside the container

- `python:3.14-slim` base image (`python3` resolves to 3.14)
- Verilator
- build-essential (g++, make)

No local Verilator install is required when using Docker.

## PyCore tagged architecture prototype

This repository also contains `pycore/`, a new tagged-register-file CPU
architecture targeting a CPython 3.14 bytecode subset. PyCore carries a 3-bit
type tag with every 128-bit value (`{tag[2:0], value[127:0]}`), routes execution
through tag-conditioned integer/FPU/bool/string/trap paths, and isolates the
register file, multiplier, divider, and FPU for later ASIC macro replacement.

Key files:

- `pycore/rtl/pycore_regfile.sv`: 96-entry, 131-bit register file with locals
  and operand-stack regions.
- `pycore/rtl/pycore_tag_decode.sv`: combinational type-dispatch logic.
- `pycore/rtl/pycore_exec.sv`: tag-routed execute fabric.
- `pycore/tools/preprocess.py`: Python 3.14 bytecode-to-hex preprocessor.
- `pycore/docs/architecture.md`: design rationale and semantic deviations.

Run the PyCore smoke tests with:

```bash
make pycore-test
```

This suite now includes a dedicated frame-manager stress test
(`make pycore-frame`) that verifies linked-list frame tracking, RF ring-buffer
allocation, spill/reclaim behavior, and frame fault handling.
It also includes `make pycore-string-exec`, which stress-tests short/long
string concatenation and overflow trapping.

Or run the same suite in Docker:

```bash
make docker-pycore-test
```

If your Docker daemon requires host networking during builds, pass flags through
the Makefile:

```bash
make docker-pycore-test DOCKER_BUILD_FLAGS=--network=host DOCKER_RUN_FLAGS=--network=host
```

The preprocessor is intentionally strict about Python 3.14:

```bash
python3.14 pycore/tools/preprocess.py \
  --source pycore/programs/mixed_arith.py \
  --function managed_entry
```
