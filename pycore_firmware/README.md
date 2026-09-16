# pycore_firmware

Pure-Python software that ships in the pycore boot image (ROM).

At tape-out, this tree is compiled to bytecode and placed at fixed memory
locations so the core can initialize itself (booter / BIOS) and resolve
LEGB **B**uildin calls by jumping the PC into precompiled ROM — or, for
tiny helpers, by inlining their bytecode.

## Builtin model

Hot builtins are seeded in the boot-record **builtins dict** as
`OBK_BUILTIN` handles (`BI_LEN`, `BI_RANGE`, …). `LOAD_GLOBAL` /
`LOAD_NAME` resolve globals then that dict; `CALL` runs hardware fast
paths for known tags (e.g. `len(list)` reads the list header).

Pure-Python modules under `builtins/` implement **miss / protocol**
paths (e.g. `len(obj)` → `obj.__len__()`), not slower rewrites of the
fast paths. Bytecode and CALL work needed to finish this split is in
`planning/old/implemented/builtins_bytecode_support_plan.md`.
On-device `compile()`: ROM shim in `builtins/compile.py` plus the package
under `compiler/` (`planning/compiler_design.md`). `vendor/pycpython` is
the host oracle only.

## Layout

| Path | Role |
| --- | --- |
| `builtins/` | Pure-Python miss-path / ROM builtins + `builtins.md` inventory |
| `compiler/` | On-device `compile()` package (T1–T3 landed). Helpers live in `_PYC_G` (code RAM); the public ROM shim is `builtins/compile.py`. `tables.py` is generated from `pycore/targets/pycore.json` (`pycore/tools/gen_compiler_tables.py`). Occupancy: `make pycore-size-report`. |

Image tests compile these modules via `ROM_FIRMWARE_BUILTINS` in
`pycore/tools/image_from_source.py` and seed them into the boot-record
builtins dict. Host goldens in `run_image_test.py` inject the same bodies
through `load_rom_firmware_callables()` so firmware semantics (e.g.
`reversed` → list) match hardware.

The compiler package is **not** listed in that builtins dict (except the
public `compile` shim and the §11.7 `bios` payload exec). The image builder serializes every top-level `def`
under `compiler/` (except generated `tables.py`) into code RAM, copies
`tables.py` constants (`TOK_*`, `OPMAP`, `KEYWORDS`, …) into the same dict,
builds one `MUT_DICT` bound as `_PYC_G`, and binds a 0-arg trampoline as
`_PYC_ENTRY`. `compile()` stores `_in_src` / `_in_file` / `_in_mode` and
runs `_pyc_codegen_main` with `_bi_exec_globals(_pyc_codegen_main, _PYC_G)`.
`_PYC_ENTRY` remains the step-D toy (`return _pyc_add(_pyc_inc(40), 1)` → 42).

