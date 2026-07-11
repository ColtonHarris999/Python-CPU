# Test Programs

Each Python file in this folder defines a `managed_entry()` function that
exercises PyCore CPU features.  The CI test runner (`pycore/tests/test_programs.py`)
automatically discovers every `*.py` file, runs `managed_entry()` natively to
obtain the expected return value, compiles the program through `preprocess.py`,
runs it on the Verilator simulation, and asserts the CPU return value matches
native Python.

**Adding a new test:** drop a `*.py` file here — no other changes needed.

---

## Multi-function support

`preprocess.py` supports files with multiple function definitions.  The
compiler uses a two-pass strategy:

1. **Pass 1** — dry-run each function to count its instruction-memory slots
   and assign each function a start slot address.
2. **Pass 2** — compile each function with resolved callee addresses; the
   `CALL` instruction arg is encoded as `(argc << 16) | callee_slot`.

The calling convention in hardware:

* `PUSH_NULL` — discarded (no hardware equivalent).
* `LOAD_GLOBAL name` — consumed silently; the function name is looked up in
  the module's function table.
* `CALL argc` — emitted as a hardware `CALL` with `(argc << 16) | callee_slot`.

---

## Constraints

All programs must be compilable by `pycore/tools/preprocess.py`:

* Only bytecodes listed in `SUPPORTED_OPS` (or handled explicitly: `PUSH_NULL`,
  `LOAD_GLOBAL`, `CALL`) are accepted.
* `LOAD_GLOBAL` may only refer to other Python functions defined in the same
  source file — not to builtins, imported modules, or module-level constants.
* Avoid `for` loops (need `GET_ITER`/`FOR_ITER`); use `while` instead.
* Type annotations (`: int`, `-> int`) are fine — they appear only in
  `co_annotations`, not in bytecode.

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
| `function_no_args.py` | Function call, zero arguments |
| `function_with_args.py` | Function call, multiple arguments |
| `nested_calls.py` | Functions calling functions (3 levels deep) |
| `recursive_factorial.py` | Recursive function (6 levels) |
