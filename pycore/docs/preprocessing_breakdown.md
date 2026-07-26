# Preprocessing Breakdown and Design Budget

This document defines the active image-building flow for the current PyCore
implementation and clarifies what should remain host-side versus on-core.

## Fidelity boundary

"Identical to what a CPython compiler would create" means: the image contains
the same object graph as `compile()` output -- same bytecode units in the same
order (including `CACHE` and `EXTENDED_ARG`), same `co_consts`/`co_names`, and
nested code objects -- lowered mechanically into tagged 128-bit-slot encoding.
No opcode is added, removed, reordered, rewritten, or argument-remapped.

Byte-exact CPython C-struct layout is out of scope because PyCore requires
tagged slots for hardware access. Matching CPython's in-memory C object layout
is future work.

## 1) Active image flow (`pycore/tools/image_from_source.py`)

Input: Python source module.

Outputs:

- instruction memory image (`program.hex`) -- one 64-bit slot per raw CPython
  two-byte code unit
- data memory image (`dmem.hex`) -- tagged object graph, including code objects,
  tuples, globals dict, and the boot record
- string memory image (`string_mem.hex`) -- long string payload bytes
- metadata (`image.meta`) -- currently `HEAP_INIT_PTR` and optional expected
  result fields used by tests

Steps:

1. **Version gate**: hard-fails unless running Python 3.14.
2. **Compile**: calls CPython `compile(source, filename, "exec")`.
3. **Validate**: walks the module and nested code objects, rejecting unsupported
   opcodes and unsupported sub-op variants.
4. **1:1 transcode**: writes every raw `co_code` unit to one imem slot in the
   same order. `CACHE` and `EXTENDED_ARG` stay in the image.
5. **Serialize object graph**: lowers `co_consts`, `co_names`, nested code
   objects, scalar constants, tuple constants, the module globals dict, and
   interned long strings into tagged slots.
6. **Write boot record**: stores the module `CODE_OBJECT` handle and globals
   `DICT` handle at `0x3e0`.
7. **Export metadata**: reports `HEAP_INIT_PTR` so runtime heap allocation starts
   above the static image.

Branch remapping is removed: imem slot index equals CPython code-unit index, so
hardware branch arguments are the original compiler arguments. `LOAD_CONST` is
also no longer rewritten into an inline three-slot pseudo-instruction; hardware
indexes `co_consts` and reads the value/tag pair from dmem.

`pycore/tools/run_image_test.py` wraps this flow for positive differential
tests by executing `managed_entry()` on host CPython and writing
`EXPECTED_TAG`/`EXPECTED_VALUE` into metadata.

## 2) Deprecated flow (`pycore/tools/preprocess.py`)

`preprocess.py` remains only for a few older single-function / hand-authored
hex fixtures and `make run-file`. It performs semantic transformations the
image-boot flow does not permit (stripping cache/extended units, remapping
branch arguments, expanding `LOAD_CONST` into a three-slot inline literal).

Do not use `preprocess.py` for new tests — use `image_from_source.py`
(sets, dicts, lists, and the rest of the supported opcode matrix are
accepted there when listed in `bytecode_support.md`).

## 3) Preprocessing budget rule

Preprocessing should remain a thin translation/validation layer, not a hidden
runtime.

Allowed:

- version-safe opcode decoding aligned to CPython 3.14;
- rejecting unsupported constructs early;
- mechanical re-encoding of CPython bytecode and objects into PyCore memory
  images.

Disallowed direction:

- heavy semantic lowering that changes execution model (for example,
  software-emulated frame semantics, branch rewriting, object protocol rewrites,
  or opcode expansion/removal).

If a transform materially changes program semantics, it should move into
hardware/firmware instead.

## 4) On-core migration targets

To keep PyCore true to purpose, future work should continue moving these
behaviors on-core:

- bytecode decode and immediate extraction;
- frame/stack policy and spill strategy;
- runtime type checks/promotion;
- branch/call execution semantics;
- inline caches for hot image operations such as `LOAD_CONST` dmem reads.
