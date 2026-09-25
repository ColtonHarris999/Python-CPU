# Image build flow

This document describes how a Python source file becomes a PyCore boot
image, and what the host tooling is and is not allowed to do to it.

## Fidelity boundary

"Identical to what a CPython compiler would create" means: the image contains
the same object graph as `compile()` output -- same bytecode units in the same
order (including `CACHE` and `EXTENDED_ARG`), same `co_consts`/`co_names`, and
nested code objects -- lowered mechanically into tagged 128-bit-slot encoding.
Branch arguments are never remapped, because the imem slot index equals the
CPython code-unit index.

Three host rewrites are the documented exceptions. Each one rewrites **in
place with `NOP` padding**, so no instruction moves and no branch offset
changes:

| Rewrite | Function | Why |
| --- | --- | --- |
| All-literal unit-step slices (`s[1:]`, `s[:]`, `s[1:3]`): CPython folds these to a `slice` constant + `NB_SUBSCR`, which is rewritten to `BINARY_SLICE` | `fold_slice_constants` | There is no `slice` object on the hart |
| Literal `def` defaults (`SET_FUNCTION_ATTRIBUTE` 1 / 2) are moved onto the code object (fields 4 and 6) | `fold_function_defaults` | Function ≡ code object for plain `def` |
| Module-level `class` statements are built on the host and stored as `OBK_TYPE` objects | `fold_module_classes` | There is no runtime `LOAD_BUILD_CLASS` yet |

Test fixtures can also opt into bytecode injection pragmas (LFAC,
`SET_ADD` / `MAP_ADD` sequences). These synthesize opcodes CPython 3.14
will not emit from source, so that the hardware paths get coverage. They
are test-only and never apply to a normal program.

Byte-exact CPython C-struct layout is out of scope because PyCore requires
tagged slots for hardware access.

## Image flow (`pycore/tools/image_from_source.py`)

User-facing entry: `pycore/tools/pycore_cli.py` (`make lint-file` /
`make run-file`). It calls this builder, then (for `run`) the shared
two-core `tb_container` simulator with plusargs.

Input: a Python source module.

Outputs:

- `program.hex`: code ROM, one 64-bit slot per raw CPython two-byte code
  unit.
- `code_ram.hex`: the code-RAM bank preloaded at reset. It holds the
  on-device compiler package (`pycore_firmware/compiler/`), which sits below
  the code-RAM write floor. With `--code-ram`, it holds the whole user image
  instead.
- `dmem.hex`: the tagged object graph. That includes code objects, tuples,
  the globals dict, interned strings, the boot builtins dict, ROM firmware
  builtins, the native-method table, exception types, and the boot record.
- `image.meta`: `HEAP_INIT_PTR` and `CODE_RAM_INIT_SLOT`, plus
  `EXPECTED_TAG` / `EXPECTED_VALUE` when a host golden was computed.

Steps:

1. **Version gate.** Hard-fails unless running under Python 3.14.
2. **Compile.** Calls CPython `compile(source, filename, "exec")`. The
   on-device compiler (`pycore/docs/compiler.md`) is not used to build
   images. `vendor/pycpython` is a host oracle for tests only.
3. **Fold.** Applies the three rewrites in the table above.
4. **Validate.** Walks the module and every nested code object, and rejects
   unsupported opcodes and sub-op variants against `pycore/targets/pycore.json`.
   A construct the hardware cannot run should fail here, not trap at run
   time.
5. **1:1 transcode.** Writes every raw `co_code` unit to one imem slot in
   order. `CACHE` and `EXTENDED_ARG` stay in the image.
6. **Serialize and seed.** Lowers the object graph into tagged slots. Also
   seeds the ROM firmware builtins (`pycore_firmware/builtins/`), the
   native-method table, exception types, and the compiler package
   (`_PYC_G`).
7. **Boot record.** Stores the module `CODE_OBJECT`, globals dict, and
   builtins dict handles at `0x3E0` (96 bytes).
8. **Metadata.** Reports `HEAP_INIT_PTR`, so that the runtime bump heap
   starts above the static image.

`pycore/tools/run_image_test.py` wraps this flow for positive differential
tests: it runs `managed_entry()` on host CPython and writes
`EXPECTED_TAG` / `EXPECTED_VALUE` into the metadata.

## Deprecated: `pycore/tools/preprocess.py`

`preprocess.py` is the pre-image-boot, single-function flow. Only the
standalone `make pycore-preprocess` target and its own unit tests still use
it; no test suite does. It strips `CACHE` / `EXTENDED_ARG`, remaps branch
arguments, and expands `LOAD_CONST` into an inline three-slot literal,
which is everything the fidelity boundary forbids. Do not use it. It is
scheduled for removal in `planning/cleanup_report.md` item C1.

## Budget rule

The image builder should stay a thin translation and validation layer, not
a hidden runtime.

Allowed:

- version-safe opcode decoding aligned to CPython 3.14;
- rejecting unsupported constructs early;
- mechanical re-encoding of CPython bytecode and objects into PyCore memory
  images;
- the in-place `NOP`-padded rewrites listed above, each paired with the
  hardware feature that will make it unnecessary.

Not allowed:

- heavy semantic lowering that changes the execution model: software frame
  semantics, branch rewriting, object-protocol rewrites, or opcode
  insertion / removal that moves code.

A transform that materially changes program semantics belongs in hardware
or firmware instead.
