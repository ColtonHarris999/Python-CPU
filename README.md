# Python-CPU

SystemVerilog RTL scaffold for a managed-code processor that executes a small,
stack-based subset of CPython bytecode using a 5-stage pipeline:

1. **Fetch (IF)**: reads 16-bit instruction words from program memory.
2. **Decode (ID)**: extracts opcode/oparg and sources stack operands.
3. **Execute (EX)**: performs ALU operation or address/select work.
4. **Memory (MEM)**: stage register for load/constant values and ALU outputs.
5. **Writeback (WB)**: commits results to stack/locals and handles return/trap.

## Supported bytecode subset

- `RESUME (151)`
- `NOP (9)`
- `LOAD_CONST (100)`
- `LOAD_FAST (124)`
- `STORE_FAST (125)`
- `BINARY_OP (122)` with oparg:
  - `0` = add
  - `10` = subtract
  - `5` = multiply
- `RETURN_VALUE (83)`

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

## Run locally with Verilator

Requirements:

- Verilator (v5+ recommended)
- C++ compiler (g++)
- make

Build and run:

```bash
make sim
```

You should see:

```text
PASS: returned 44 ...
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

- Ubuntu base image
- Verilator
- build-essential (g++, make)

No local Verilator install is required when using Docker.
