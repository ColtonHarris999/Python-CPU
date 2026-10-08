# CPython baseline suite: bytecode the hart already has

Status: **evaluation, no hart opcode to add.** Snapshot of the suite in
`pycore/tools/cpython_baseline/benchmarks/`.

This is the list of bytecodes those programs need, and what each one
needs from pycore. The measured run is the one in
[`pycore/docs/cpython_benchmarks.md`](../pycore/docs/cpython_benchmarks.md):
`make cpython-baseline` (six microbenchmarks) and
`make cpython-baseline-research` (ten pyperformance / Benchmarks Game /
SciMark kernels). The programs under "Not in this set" in that doc were
not part of the run.

The way those files run on the hart is `make run-file` / `pycore_cli exec`:
on-device `compile()`, then `exec` in a namespace that already contains
`__name__ == "__main__"`, stdout compared with CPython 3.14. That path
is the one that matches the baseline's printed checksums. A host-built
image (`HOST_COMPILE=1`) is a different entry (`managed_entry` returning
an int) and is not what these files are shaped for.

## Verdict

Every opcode either producer emits for this suite is already `execute`
or an accepted partial form in `pycore/targets/pycore.json`. There is
no bytecode implementation plan to send. The one change that lets the
whole suite compile on device is the parser plan
[`implicit_string_concat_plan.md`](implicit_string_concat_plan.md):
`fasta.py` and `knucleotide.py` split a long literal across adjacent
string tokens, and the on-device parser rejects that. CPython folds it
to one constant. The hart already loads and indexes that constant.

Container growth (`list.append`, dict insert past the load factor) stays
on the excore traps the accelerator-split work is moving. This suite
needs those results to stay the same. It does not need a second
container design.

## How this was checked

Two producers, same sources.

**Host CPython 3.14 `compile()`**, which is what a host-built image
contains. `pycore_cli.collect_opcode_issues` (the image-boot allowlist,
including `BINARY_OP` / `COMPARE_OP` opargs) accepts all 16 files.
`compiler_subset.check_source` accepts all 16. The largest name table
in any code object is far under the 128-name truncation in
`container_idx_r`. The largest `BUILD_*` oparg in this bytecode is a
short list; nothing builds 128 elements in one instruction. `set()` in
`nqueens` is called on 7 ints.

**On-device compiler**, run on the host stand-in
(`load_rom_firmware_callables()["compile"]`). It emits the opcode set
in the table below. Every name is in the allowlist. `BINARY_OP` opargs
are 0, 2, 3, 5, 6, 8, 10, 11, 26 (`NB_ADD`, `NB_FLOOR_DIVIDE`,
`NB_LSHIFT`, `NB_MULTIPLY`, `NB_REMAINDER`, `NB_POWER`, `NB_SUBTRACT`,
`NB_TRUE_DIVIDE`, `NB_SUBSCR`). `COMPARE_OP` opargs are 2, 42, 72, 103,
132 (`<`, `<=`, `==`, `!=`, `>`), which `SUPPORTED_COMPARE_ARGS` already
lists.

Results against CPython, same source, stand-in execution:

| Program | What ran | Result |
| --- | --- | --- |
| `dispatch_loop.py`, `fib_iter.py`, `dict_int.py`, `list_sum.py`, `nbody_int.py`, `spectral_tiny.py` | full source | stdout matches |
| `binary_trees.py`, `mandelbrot.py`, `spectral_norm.py` | full published sizes in this tree (N=8, 32, 20/10) | checksum matches |
| `nqueens.py` N=5, `nbody.py` 5 steps, `monte_carlo.py` 50 samples, `sor.py` N=8 / 2 cycles, `binary_trees.py` N=4, `mandelbrot.py` size 8, `spectral_norm.py` N=6 / 3 iters | reduced so the stand-in's 65536-step cap holds | matches CPython on that source |
| `fannkuch.py` N=1..4 | `while`/`else` and the pancake swaps | matches the published flip counts 0, 1, 2, 4 |
| `fasta.py`, `knucleotide.py` | source as written | `SyntaxError` (`unmatched bracket`) |
| same two, adjacent strings joined by hand, N=30 and N=200 | dict `for`, `in`, `ord`, long-string index, float pick | matches CPython |

The stand-in uses CPython arithmetic, so a match means the compiler's
bytecode has CPython's result. It does not measure the FPU. `nbody`'s
`** -1.5` is the one place the hart's general power path can move the
scaled checksum by an ulp (`pycore/docs/limitations.md` L-ALU-4). The
benchmark doc already says to report that difference. `** 0.5` in
`spectral_norm` is the hart's exact square-root path. The other float
kernels are add, multiply, and true divide.

`print` of these checksums is inside signed 32-bit, which is the width
`bi_print_int` formats. The open 64-bit print bug does not change these
lines.

## Opcodes the on-device compiler emits

Counts are static instruction words across all 16 files, with
`fasta.py` and `knucleotide.py` pre-joined so they compile. Support is
the `pycore.json` row. "Needs" is what this suite actually does with
the opcode.

| Opcode | Words | Files | Needs |
| --- | ---: | ---: | --- |
| `BINARY_OP` | 594 | 16 | The opargs listed above, on int and float. `NB_SUBSCR` on lists and on `SHORT_STR` / `LONG_STR`. `NB_POWER` for `** 0.5` and `** -1.5` on a positive float. `NB_TRUE_DIVIDE` for float and for int/int below 2^53. |
| `LOAD_SMALL_INT` | 564 | 16 | Immediates 0..255. Larger ints are `LOAD_CONST`. |
| `LOAD_FAST` | 509 | 11 | Locals. No freevars, no cells. |
| `SWAP` | 408 | 12 | The subscript lowering (`index` / `_bi_code_kind` / `len`). Tag-agnostic exchange, already implemented. |
| `CALL` | 315 | 16 | Positional calls: user functions, `print` of an int, `len`, `int` of an int or a float (truncate toward zero, including the negative n-body energies), `ord` of a one-character string, `set` of a list of ints, and `list.append` after `LOAD_ATTR`. |
| `LOAD_GLOBAL` | 309 | 14 | Function bodies. Names include `len` and `_bi_code_kind` because a non-constant index is lowered to a tag check plus `len` for a negative index. Both names are already seeded. |
| `COPY` | 308 | 12 | Same subscript lowering. |
| `POP_JUMP_IF_FALSE` | 297 | 16 | `while` / `if`. |
| `COMPARE_OP` | 293 | 16 | Int and float ordering and equality, opargs above. |
| `LOAD_CONST` | 222 | 16 | Floats, `None`, strings. The fasta ALU literal is one ~287-character string once adjacent literals are joined. `LOAD_CONST` of a `LONG_STR` already indexes. |
| `STORE_FAST` | 216 | 11 | Locals. |
| `LOAD_NAME` | 201 | 16 | Module body, including `__name__`. The exec harness binds `__name__` before `exec`. |
| `STORE_NAME` | 113 | 16 | Module assigns. Two-core dict grow already handles a new global. |
| `TO_BOOL` | 96 | 16 | `while` tests, `if not`, `if at:` on a bool. Operands here are int, bool, or float. |
| `PUSH_NULL` | 93 | 16 | Non-method call shape. |
| `RETURN_VALUE` | 83 | 16 | Functions and the module. |
| `JUMP_BACKWARD` | 60 | 16 | Loops, including `fannkuch`'s `while`/`else`. |
| `RESUME` | 49 | 16 | Stripped marker. |
| `BUILD_LIST` | 47 | 12 | Counts in this suite are 0..7 on the firmware compiler (`BUILD_LIST n`, not `LIST_EXTEND`). Under the 7-bit oparg width. |
| `POP_TOP` | 40 | 16 | Expression statements and calls used for effect. |
| `STORE_SUBSCR` | 38 | 8 | List and dict stores. Indexes are non-negative. New dict keys grow through the existing `DICT_GROW` trap. |
| `MAKE_FUNCTION` | 33 | 11 | Identity: the function is the code object. No closures, no defaults, no annotations. |
| `STORE_FAST_LOAD_FAST` | 26 | 8 | Peephole. Indexes fit in the 4-bit pair. |
| `LOAD_FAST_LOAD_FAST` | 20 | 5 | Peephole. Locals are bound before the pair. |
| `LOAD_ATTR` | 18 | 10 | `list.append` only, method form (`oparg` low bit set). The native method table already resolves it to the ROM body, which extends the list. |
| `UNARY_NEGATIVE` | 12 | 2 | `nbody` float literals the folder leaves unfolded, and `monte_carlo`'s `-seed` on an int. Both tags are already on the unary path. |
| `JUMP_FORWARD` | 11 | 6 | `if`/`else`. |
| `BUILD_MAP` | 2 | 2 | `{}` in `dict_int` and `knucleotide`. |
| `BUILD_TUPLE` | 2 | 2 | `return chars, probs` and `return before, after`. |
| `UNPACK_SEQUENCE` | 2 | 2 | The two assignments of those pairs. Length 2, list or tuple. |
| `UNARY_NOT` | 2 | 1 | `if not attacks(...)`. |
| `STORE_FAST_STORE_FAST` | 1 | 1 | Peephole in `fasta`. |
| `CONTAINS_OP` | 1 | 1 | `key in counts` on a dict of 1- and 2-character strings. The dict stays far under 256 entries (the ALU alphabet is ACGT). |
| `GET_ITER` / `FOR_ITER` / `END_FOR` / `POP_ITER` | 1 each | 1 | `for key in counts`. Dict key order does not affect the weighted checksum. |
| `POP_JUMP_IF_TRUE` | 1 | 1 | `nqueens` `or`. |

## Opcodes only the host compiler emits

A host-built image of the same files also contains these. They are
already in the allowlist, and the on-device compiler simply does not
emit them for this suite.

| Opcode | Why it appears | Already on the hart |
| --- | --- | --- |
| `CACHE` | CPython inline caches | Fetch skips them |
| `EXTENDED_ARG` | Jump and name widths | Fetch folds them |
| `NOT_TAKEN` | Adaptive marker | No-op |
| `LOAD_FAST_BORROW`, `LOAD_FAST_BORROW_LOAD_FAST_BORROW` | Refcount hints | Same path as `LOAD_FAST` |
| `LOAD_FAST_CHECK` | One site in host `spectral_norm` | Same path as `LOAD_FAST`; unbound traps |
| `LIST_EXTEND` | Host `compile()` of a list literal of 3 or more items (`BUILD_LIST 0`, load a tuple, extend) | Non-empty extend is excore trap 10. The firmware compiler emits `BUILD_LIST n` instead, which stays on pycore for these sizes |
| `RESUME` | Entry marker | Strip |

Host `COMPARE_OP` uses the other packed forms (18, 58, 88, 103, 148).
Those are already in `SUPPORTED_COMPARE_ARGS`.

## What each program stresses, and the hart path

| Program | Hot work | Hart path that already exists |
| --- | --- | --- |
| `dispatch_loop`, `fib_iter` | int add, compare, call, `print` | ALU, `CALL`, ROM `print` |
| `dict_int` | int dict fill and lookup | `STORE_SUBSCR` / `NB_SUBSCR`, `DICT_GROW` when the table fills |
| `list_sum`, `spectral_tiny`, `fannkuch`, `sor`, `monte_carlo`, `fasta`, `knucleotide`, `spectral_norm`, `nbody` | `list.append` in a loop | `LOAD_ATTR` append → ROM body → `LIST_EXTEND` / grow on the excore |
| `nbody_int`, `nbody`, `binary_trees` | nested lists, subscript | `BUILD_LIST`, `NB_SUBSCR`, `STORE_SUBSCR`. Indexes in the source are non-negative; the compiler still emits the `len` rewrite for a variable index |
| `binary_trees` | recursion, `1 << k` | Frames and `NB_LSHIFT`. Depth is about 10 at N=8 |
| `nqueens` | `set(list)`, `not`, `%` | `PY_BI_SET` from one list, `UNARY_NOT`, `NB_REMAINDER`. Elements are small ints, some negative. The `None`-as-empty-slot bug in `set()` is not hit |
| `knucleotide` | dict of short strings, `in`, `for` | `BUILD_MAP`, string `NB_ADD` of two one-character strings (result fits in a `SHORT_STR`), `CONTAINS_OP`, dict `FOR_ITER` |
| `fasta`, `knucleotide` | index a long literal, `ord` | `LOAD_CONST` `LONG_STR`, `SA_CHAR_AT`, `PY_BI_ORD` |
| `mandelbrot`, `sor`, `monte_carlo`, `spectral_norm` | float arithmetic | FPU add / mul / div. `spectral_norm` also `** 0.5` |
| `nbody` | float `** -1.5`, `int(energy * 1e9)` | General power path (L-ALU-4) and `int` of a float |

## Left alone on purpose

- The accelerator split (`planning/accelerator_split_plan.md`) owns
  moving list grow, list extend, dict grow, and `print` off the excore.
  These benchmarks are a regression set for that work: append loops,
  `dict_int`, `knucleotide`'s dict, and one `print` of an int per
  program (two for `nbody`).
- L-ALU-4 (`float ** float` within 1 ulp of libm). Closing it is a
  different change from "the program runs".
- `print` of an int outside signed 32-bit. No checksum in this suite
  is outside that range (`spectral_norm` 1273839840 and `sor`
  1047090603 are the largest; both fit).
- Programs the baseline did not run (richards and the other `class`
  kernels, pidigits, `math.sin` / `math.sqrt`, anything that `import`s).
  Their missing pieces are already listed in
  `pycore/docs/cpython_benchmarks.md` and in master-plan tracks 2–4.
