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
On-device `compile()`: `planning/compile_plan.md` and `vendor/pycpython`
(host oracle only).

## Layout

| Path | Role |
| --- | --- |
| `builtins/` | Pure-Python miss-path / ROM builtins + `builtins.md` inventory |
| `compiler/` | On-device `compile()` package. Step D seeds a two-function toy into `_PYC_G`; later steps drop in lexer/parser/codegen. `tables.py` is generated from `pycore/targets/pycore.json` (`pycore/tools/gen_compiler_tables.py`). |

Image tests compile these modules via `ROM_FIRMWARE_BUILTINS` in
`pycore/tools/image_from_source.py` and seed them into the boot-record
builtins dict. Host goldens in `run_image_test.py` inject the same bodies
through `load_rom_firmware_callables()` so firmware semantics (e.g.
`reversed` → list) match hardware.

The compiler package is **not** listed in that builtins dict. The image
builder serializes every top-level `def` under `compiler/` (except generated
`tables.py`) into code RAM, builds one `MUT_DICT` bound as `_PYC_G`, and
binds a 0-arg trampoline as `_PYC_ENTRY`. User programs enter the package
with `_bi_exec_globals(_PYC_ENTRY, _PYC_G)`.

