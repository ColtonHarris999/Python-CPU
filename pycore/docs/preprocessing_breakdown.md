# Preprocessing Breakdown and Design Budget

This document explains exactly what preprocessing currently happens before RTL
simulation, what is strictly required, and what should eventually move on-core.

## 1) Legacy core preprocessing (`tools/gen_bytecode_assets.py`)

Input: Python source file + function name.

Output:

- instruction memory image (`programs/*_prog.hex`)
- constant memory image (`programs/*_consts.hex`)
- expected return value file (`programs/*_expected.txt`)

Steps:

1. **Version gate**: hard-fails unless running on Python 3.14.
2. **Bytecode extraction**: disassembles the function and filters unsupported
   opcodes.
3. **Opcode validation**: checks `BINARY_OP` opargs against the supported
   integer subset.
4. **Lowering pass**: splits fused dual-load opcodes into two single-load words
   because the hardware writes back one value per cycle.
5. **Constant compaction**: builds a compact const table for `LOAD_CONST`.
6. **Artifact emission**: writes program/const hex files.
7. **Reference result**: executes the Python function and writes expected return.

## 2) PyCore preprocessing (`pycore/tools/preprocess.py`)

Input: Python source file + function name.

Output:

- instruction memory image (`pycore/programs/program.hex`)
- tagged constant image (`pycore/programs/consts.hex`)
- inferred type annotation (`pycore/programs/program.types`)
- inline cache map (`pycore/programs/cache_map.hex`)

Steps:

1. **Version gate**: hard-fails unless running on Python 3.14.
2. **Instruction filtering**: strips `CACHE`/`EXTENDED_ARG` and rejects unknown
   opcodes.
3. **Sub-op validation**: validates supported `BINARY_OP` opargs.
4. **Instruction folding**: emits one 64-bit slot per instruction word.
5. **Tagged constant encoding**: emits `{tag,value}` entries for constants.
6. **Type inference pass**: computes a lightweight variable/stack type sketch.
7. **Cache metadata dump**: emits CPython inline-cache counts for observability.

## 3) Which steps are essential vs optional

### Strictly essential (must exist somewhere)

- Version-safe opcode decoding (`3.14` mapping agreement).
- Unsupported-opcode rejection.
- Instruction formatting into hardware memory images.
- Constant formatting into hardware memory images.

### Optional / tooling convenience

- Running the function on host Python to compute expected return.
- Emitting `.types` for diagnostics.
- Emitting inline cache metadata.
- Compacting constants for smaller memory files (helps, but not fundamental).

## 4) Preprocessing budget rule for PyCore

Preprocessing should remain a **thin translation pass**, not a software runtime.

Use this budget rule:

- preprocessing may **re-encode** program representation;
- preprocessing may **validate** unsupported constructs early;
- preprocessing should **not** perform heavyweight semantic lowering that hides
  hardware complexity.

If a transform becomes large enough that it meaningfully changes execution model
(e.g., frame construction, object protocol emulation, or deep control-flow
rewrites), that work should be moved into hardware/firmware instead.

## 5) What should be runnable on-core later

To preserve the point of a dedicated Python core, these should be considered
on-core or near-core responsibilities over time:

- bytecode stream decoding and immediate extraction;
- frame/stack management policy;
- runtime type checks and promotion behavior;
- branch and call semantics.

Host preprocessing should ideally converge toward:

- packaging code/data into memory images;
- quick static validation;
- test harness convenience metadata.

## 6) Practical current recommendation

Short term, keep both preprocessors because they reduce bring-up friction.
Long term, prioritize shrinking preprocessing by moving semantic logic into RTL
and treating preprocessing as a loader-format conversion stage.
