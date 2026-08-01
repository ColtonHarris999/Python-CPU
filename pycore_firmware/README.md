# pycore_firmware

Pure-Python software that ships in the pycore boot image (ROM).

At tape-out, this tree is compiled to bytecode and placed at fixed memory
locations so the core can initialize itself (booter / BIOS) and resolve
LEGB **B**uildin calls by jumping the PC into precompiled ROM — or, for
tiny helpers, by inlining their bytecode.

## Layout

| Path | Role |
| --- | --- |
| `builtins/` | Pure-Python equivalents of Python builtin functions |

Testing today uses hex images for specific memory locations (same flow as
other pycore precompiled fixtures). Implementations land one builtin at a
time on the `builtins` branch.
