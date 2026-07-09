# Test Programs

Each Python file in this folder defines a `managed_entry()` function that
exercises PyCore CPU features.  The CI test runner (`pycore/tests/test_programs.py`)
automatically discovers every `*.py` file, runs `managed_entry()` natively to
obtain the expected return value, compiles the program through `preprocess.py`,
runs it on the Verilator simulation, and asserts the CPU return value matches
native Python.

**Adding a new test:** drop a `*.py` file here — no other changes needed.

---

## Constraints

All programs must be compilable by `pycore/tools/preprocess.py`, which has two
key limitations:

1. **Single-function scope** — `preprocess.py` compiles only the named entry
   function (`managed_entry`).  Calling other Python functions defined in the
   same file would require `LOAD_GLOBAL` bytecode, which the hardware does not
   support.  Multi-function call/return is tested separately via the
   `pycore-multifn-*` Makefile targets that use pre-compiled hex images.

2. **Supported bytecodes** — only the opcodes listed in `SUPPORTED_OPS` in
   `preprocess.py` are accepted.  Avoid Python constructs that emit unsupported
   opcodes (e.g. `for` loops need `GET_ITER`/`FOR_ITER`; use `while` instead).

---

## Feature Coverage

| File | Feature |
|------|---------|
| `int_arithmetic.py` | Integer +, -, *, //, %, ** |
| `int_bitwise.py` | Integer &, \|, ^, <<, >> |
| `int_comparisons.py` | Integer <, <=, ==, !=, >, >= |
| `int_large_const.py` | LOAD_CONST with large integer |
| `float_arithmetic.py` | Float +, -, *, /, // |
| `float_comparisons.py` | Float comparison operators |
| `float_mod_pow.py` | Float %, ** |
| `float_dot_product.py` | Float multiply-accumulate, negative constants |
| `bool_arithmetic.py` | Bool → int/float promotion in arithmetic |
| `bool_comparisons.py` | Comparison results (Bool) used in branches |
| `mixed_int_float.py` | Int/bool → float promotion, mixed arithmetic |
| `while_fibonacci.py` | While loop with multiple variable updates |
| `while_counter.py` | While loop with accumulator |
| `if_elif_else.py` | If / elif / else branching chain |
| `bubble_sort_pass.py` | Many locals, compare-and-swap pattern |
| `collatz_sequence.py` | While + if/else inside loop, mod, floor-div |
| `iterative_factorial.py` | While loop accumulating a product |
| `multi_assign.py` | Many local variables, two-local binary ops |
| `inline_computation.py` | Multi-step arithmetic sequence |
| `string_concat_short.py` | Short-string (≤15 bytes) concatenation |
| `string_concat_chain.py` | Chained string concatenation |
