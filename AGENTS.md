# AGENTS.md

## Cursor Cloud specific instructions

This repo is a SystemVerilog RTL CPU (`rtl/pycpu_core.sv`) verified end-to-end with
Verilator. There is no long-running service to start; "running the app" means building
and running the Verilator simulation, which executes compiled CPython 3.14 bytecode on
the simulated CPU and checks the result.

### Critical gotcha: Python version

- The asset generator (`tools/gen_bytecode_assets.py`) **requires CPython 3.14 strictly**
  and raises `RuntimeError` under any other interpreter. The system default `python3` is
  3.12, so you MUST override the Makefile's `PYTHON` variable to point at 3.14:
  - `make sim PYTHON=python3.14`
  - `make test-programs PYTHON=python3.14`
- The cloud update script installs `python3.14` (deadsnakes PPA) and `verilator` (apt).
  `python3.14` is intentionally NOT the default `python3`; always pass `PYTHON=python3.14`.

### Build / run / test

Standard commands live in the `Makefile` and `README.md`. The ones used here:

- Build + run demo program: `make sim PYTHON=python3.14` → expect `PASS: returned 44`.
- Full program suite (arithmetic, in-place ops, and an expected illegal-opcode trap):
  `make test-programs PYTHON=python3.14`.
- `make clean` removes the `build/` dir (Verilator output, gitignored).

There is no separate lint step; Verilator runs `-Wall` during `make sim` and prints
benign `WIDTHEXPAND`/`UNUSEDSIGNAL` warnings (not failures).

### Docker

`make docker-sim` / `docker compose run --rm sim` also work but are unnecessary in the
cloud VM since Verilator + Python 3.14 are installed directly.
