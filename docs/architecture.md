# PyCore Minimum-Spec Report

## What the design does

This branch adds a new **PyCore** architecture path next to the existing `pycpu` flow.

- RTL modules were added for the minimum architecture split:
  - `pycore_top.sv`
  - `pycore_fetch.sv`
  - `pycore_decode.sv`
  - `pycore_regfile.sv`
  - `pycore_alu.sv`
  - `pycore_mul.sv`
  - `pycore_div.sv`
  - `pycore_branch.sv`
  - `pycore_trap.sv`
  - `pycore_frame.sv`
  - `pycore_const_table.sv`
  - `pycore_types_pkg.sv`
- A CPython 3.11-oriented preprocessing tool was added:
  - `tools/preprocess.py`
  - emits:
    - `pycore_prog.hex` (`{arg[31:0], opcode[7:0]}`)
    - `pycore_consts.hex` (`{tag[1:0], value[63:0]}`)
    - `pycore.types` (inferred local-variable types)
- Basic SV testbenches and benchmark-style input programs were added:
  - `tb/tb_pycore.sv`, `tb/tb_alu.sv`
  - `programs/fib_recursive.py`, `fib_iterative.py`, `bubble_sort.py`, `bool_kernel.py`

The execution model is an in-order int/bool hardware fast path around:
- tagged values (`INT`, `BOOL`, `REF`, `UNINITIALIZED`),
- stack/locals semantics,
- integer arithmetic/bitwise operations,
- compare and boolean operations,
- branch truthiness and trap handling.


## Why it works

### 1) Tag-carrying data path

The core invariant is preserved in the datapath encoding:

```text
entry = { tag[1:0], value[63:0] }
```

Every operand consumed by ALU/branch logic is read in this packed form. That guarantees type checks are **structural** (hardware combinational checks), not software branches.

### 2) Type-checked ALU semantics

`pycore_alu.sv` enforces:
- arithmetic domain: `INT` or `BOOL` (with BOOL->INT promotion),
- boolean domain:
  - `UNARY_NOT` requires `BOOL`,
  - `BINARY_OP(NB_AND/NB_OR)` on `BOOL x BOOL` produces `BOOL`,
- comparisons produce `BOOL`,
- invalid tag combinations produce `TYPE_TRAP`.

Division/modulo route through `pycore_div.sv` and can raise `DIV_ZERO_TRAP`.

### 3) Branch truthiness in hardware

`pycore_branch.sv` directly implements Python truthiness for fast-path types:
- `BOOL`: truth = `value[0]`
- `INT`: truth = `value != 0`
- `REF`: trap

This preserves Python branch semantics without requiring software-side `bool()` expansion.

### 4) Trap centralization

`pycore_trap.sv` latches trap state and code with defined priority:

`TYPE_TRAP > STACK_FAULT > DIV_ZERO > ILLEGAL_OPCODE`

This makes failures deterministic and externally visible.


## Why this accelerates Python ints and booleans

### A) Removes interpreter dispatch from the hot path

Instead of repeatedly dispatching C interpreter handlers per opcode, hot int/bool operations execute as fixed RTL dataflow in ALU/branch blocks. This eliminates:
- dynamic object-type dispatch,
- Python object boxing/unboxing overhead on every arithmetic operation,
- repeated truthiness helper calls for branch conditions.

### B) Replaces PyObject-level metadata checks with 2-bit tag checks

Fast path typing becomes a tiny local check (`tag` bits) rather than pointer chasing and reference-type introspection. That significantly reduces control overhead and memory traffic for arithmetic-heavy kernels.

### C) Keeps data in a compact machine format

Values remain in 64-bit machine integers across operations rather than repeatedly converting between PyObject wrappers and C integers. For int/bool kernels, this removes a major source of cycles.

### D) Hardware-native compare + branch truthiness

Common branch patterns (`if x`, `if a < b`) stay in the same datapath and can execute without leaving hardware fast path.


## Architectural notes and deviations

- **Pinned semantics target:** CPython 3.11 opcode model in `tools/preprocess.py`.
- **Integer overflow:** defined 64-bit wrap behavior (documented semantic deviation vs Python bigint behavior).
- **CALL support:** current minimum baseline traps unresolved calls; frame infrastructure module is provided for extension.
- **Scope boundaries:** non-int/bool rich-object features remain out of hardware fast path and trap by design.


## Why this is a good minimum base

This branch establishes the minimum end-to-end scaffold for the research direction:
1. bytecode preprocessing and filtering,
2. tagged constant/data representation,
3. type-aware execution units,
4. trap model,
5. benchmarking-ready top-level cycle counter.

It is intentionally modular so each block can be refined toward higher fidelity (deeper pipelining, full call support, richer forwarding/hazard machinery, and eventual silicon-oriented memory macro replacements) without replacing the whole codebase.
